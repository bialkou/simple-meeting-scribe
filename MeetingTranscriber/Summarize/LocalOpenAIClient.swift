import Foundation
import OSLog

/// Small OpenAI-compatible client for a loopback summarization server such as
/// LM Studio, Ollama, or llama.cpp. It only speaks to the endpoint configured
/// by the user; the app has no cloud provider or remote inference path.
struct LocalOpenAIClient: Sendable {
    let endpoint: LocalSummaryEndpoint
    let model: String
    private let apiKey: String

    enum LocalOpenAIError: LocalizedError {
        case invalidEndpoint
        case missingModel
        case unauthorized
        case server(status: Int, message: String?)
        case network(underlying: Error)
        case emptyResponse
        case incompleteResponse
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The summarization endpoint must be a local HTTP URL (localhost, 127.0.0.1, or ::1). Check it in Settings → Summary."
            case .missingModel:
                return "No summarization model is selected. Load models from the local endpoint first."
            case .unauthorized:
                return "The local summarization endpoint rejected its API key. Check it in Settings → Summary."
            case .server(let status, let message):
                let detail = message.map { ": \($0)" } ?? ""
                return "The local summarization server returned HTTP \(status)\(detail)"
            case .network(let underlying):
                return "Could not reach the local summarization endpoint: \(underlying.localizedDescription)"
            case .emptyResponse:
                return "The local model returned no text."
            case .incompleteResponse:
                return "The local model response ended before the model finished."
            case .badResponse:
                return "The local summarization server returned an unexpected response."
            }
        }
    }

    init(endpoint: LocalSummaryEndpoint, model: String, apiKey: String = "") throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LocalOpenAIError.missingModel }
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fetch model IDs from the standard OpenAI-compatible `/v1/models` route.
    static func fetchModels(endpoint: LocalSummaryEndpoint,
                            apiKey: String = "") async throws -> [String] {
        var request = URLRequest(url: endpoint.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalOpenAIError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw LocalOpenAIError.badResponse }
        guard http.statusCode == 200 else {
            throw failure(status: http.statusCode, body: data)
        }
        return try modelIDs(from: data)
    }

    static func modelIDs(from data: Data) throws -> [String] {
        let decoded: ModelList
        do {
            decoded = try JSONDecoder().decode(ModelList.self, from: data)
        } catch {
            throw LocalOpenAIError.badResponse
        }
        let ids = decoded.data.map(\.id)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw LocalOpenAIError.badResponse }
        return ids
    }

    /// Stream one chat-completions request. Local servers generally support
    /// the same SSE shape as OpenAI, including `data: [DONE]`.
    func stream(prompt: String,
                instructions: String,
                maxTokens: Int,
                temperature: Float) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(prompt: prompt, instructions: instructions,
                                      maxTokens: maxTokens, temperature: temperature)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let model = model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(request, model: model) { text in
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream = true
        let maxTokens: Int
        let temperature: Float
    }

    private func makeRequest(prompt: String,
                             instructions: String,
                             maxTokens: Int,
                             temperature: Float) throws -> URLRequest {
        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body = ChatRequest(
            model: model,
            messages: [.init(role: "system", content: instructions),
                       .init(role: "user", content: prompt)],
            maxTokens: maxTokens,
            temperature: temperature)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(body)
        return request
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private static func run(_ request: URLRequest,
                            model: String,
                            onText: (String) -> Void) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LocalOpenAIError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw LocalOpenAIError.badResponse }
        guard http.statusCode == 200 else {
            let body = try await collect(bytes)
            Log.summary.error("local endpoint: \(model, privacy: .public) HTTP \(http.statusCode, privacy: .public) — \(String(data: body, encoding: .utf8) ?? "<binary>", privacy: .public)")
            throw failure(status: http.statusCode, body: body)
        }

        var finishReason: String?
        var producedText = false
        do {
            for try await line in bytes.lines {
                for event in try parse(line: line) {
                    switch event {
                    case .text(let text):
                        producedText = true
                        onText(text)
                    case .finished(let reason):
                        finishReason = reason
                    }
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LocalOpenAIError.network(underlying: error)
        }
        try Task.checkCancellation()

        switch finishReason {
        case "length":         throw LocalOpenAIError.incompleteResponse
        case "content_filter": throw LocalOpenAIError.badResponse
        default:                break
        }
        if !producedText { throw LocalOpenAIError.emptyResponse }
    }

    private static func collect(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 64 * 1024 { break }
        }
        return data
    }

    private static func failure(status: Int, body: Data) -> LocalOpenAIError {
        struct Envelope: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        let detail = (try? JSONDecoder().decode(Envelope.self, from: body))?.error?.message
        switch status {
        case 401, 403: return .unauthorized
        default:       return .server(status: status, message: detail)
        }
    }

    enum StreamEvent: Equatable {
        case text(String)
        case finished(reason: String)
    }

    static func parse(line: String) throws -> [StreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", !payload.isEmpty else { return [] }

        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finishReason: String?
            }
            struct StreamError: Decodable { let message: String? }
            let choices: [Choice]?
            let error: StreamError?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8))
        else { throw LocalOpenAIError.badResponse }
        if chunk.error != nil { throw LocalOpenAIError.badResponse }

        var events: [StreamEvent] = []
        for choice in chunk.choices ?? [] {
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            if let reason = choice.finishReason {
                events.append(.finished(reason: reason))
            }
        }
        return events
    }
}

/// The endpoint is configured by the user; refusing redirects prevents an
/// accidental API-key hop to another host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

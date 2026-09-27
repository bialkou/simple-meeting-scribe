import Foundation

/// Base URL for a loopback-only OpenAI-compatible server. Users may paste
/// either a server root (`http://127.0.0.1:1234`) or its v1 root (`…/v1`).
struct LocalSummaryEndpoint: Hashable, Sendable {
    let baseURL: URL

    init?(baseURL rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              Self.isLoopbackHost(host)
        else { return nil }

        let trimmedPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = trimmedPath.isEmpty ? "" : "/" + trimmedPath
        if path == "/models" {
            path = ""
        } else if path.hasSuffix("/models") {
            path.removeLast("/models".count)
        }
        if path.isEmpty {
            path = "/v1"
        } else if path != "/v1" && !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        self.baseURL = url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    var modelsURL: URL { baseURL.appendingPathComponent("models") }
    var chatCompletionsURL: URL { baseURL.appendingPathComponent("chat/completions") }
    var stringValue: String { baseURL.absoluteString }
}

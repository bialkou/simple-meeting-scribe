import Foundation
import XCTest
@testable import MeetingTranscriber

final class LocalSummaryEndpointTests: XCTestCase {
    func testNormalizesServerRootToV1Routes() {
        let endpoint = LocalSummaryEndpoint(baseURL: " http://127.0.0.1:1234 ")
        XCTAssertEqual(endpoint?.baseURL.absoluteString, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(endpoint?.modelsURL.absoluteString, "http://127.0.0.1:1234/v1/models")
        XCTAssertEqual(endpoint?.chatCompletionsURL.absoluteString,
                       "http://127.0.0.1:1234/v1/chat/completions")
    }

    func testKeepsExistingV1PathAndDropsModelsSuffix() {
        XCTAssertEqual(
            LocalSummaryEndpoint(baseURL: "http://localhost:8080/api/v1/")?.stringValue,
            "http://localhost:8080/api/v1")
        XCTAssertEqual(
            LocalSummaryEndpoint(baseURL: "http://localhost:8080/v1/models")?.modelsURL.absoluteString,
            "http://localhost:8080/v1/models")
    }

    func testRejectsMissingOrNonHTTPEndpoint() {
        XCTAssertNil(LocalSummaryEndpoint(baseURL: ""))
        XCTAssertNil(LocalSummaryEndpoint(baseURL: "127.0.0.1:1234"))
        XCTAssertNil(LocalSummaryEndpoint(baseURL: "ftp://127.0.0.1:1234"))
        XCTAssertNil(LocalSummaryEndpoint(baseURL: "http://example.com:1234/v1"))
    }
}

final class LocalOpenAIClientTests: XCTestCase {
    func testBuiltInMultilingualModelSupportsRussian() {
        XCTAssertTrue(LanguageModel.gemma4_12b_it_mlx_4bit.supportedLanguages.contains(.russian))
    }

    func testReadsStandardModelsResponse() throws {
        let json = #"{"object":"list","data":[{"id":"qwen3"},{"id":" gemma"},{"id":""}]}"#
        XCTAssertEqual(try LocalOpenAIClient.modelIDs(from: Data(json.utf8)), ["qwen3", "gemma"])
    }

    func testParsesStreamingTextAndFinish() throws {
        let line = #"data: {"choices":[{"delta":{"content":"Привет"},"finish_reason":null}]}"#
        XCTAssertEqual(try LocalOpenAIClient.parse(line: line), [.text("Привет")])

        let finish = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        XCTAssertEqual(try LocalOpenAIClient.parse(line: finish), [.finished(reason: "stop")])
        XCTAssertEqual(try LocalOpenAIClient.parse(line: "data: [DONE]"), [])
    }

    func testTitlePassLeavesRoomForQwenReasoning() {
        XCTAssertEqual(SummaryPass.title.endpointMaxTokens, 4_096)
    }

    func testTranscriptPolishingPreservesStructureAndRejectsPartialOutput() throws {
        let original = [
            TranscriptSegment(start: 1, end: 2, speakerId: 7, text: "аккаунт айди"),
            TranscriptSegment(start: 3, end: 4, speakerId: 8, text: "пинченко")
        ]
        let raw = #"```json [{"index":0,"text":"Account ID"},{"index":1,"text":"Пинченко"}] ```"#

        let polished = try XCTUnwrap(TranscriptPolishing.apply(
            raw, to: original, expectedIndices: [0, 1]
        ))
        XCTAssertEqual(polished.map(\.text), ["Account ID", "Пинченко"])
        XCTAssertEqual(polished.map(\.id), original.map(\.id))
        XCTAssertEqual(polished.map(\.start), original.map(\.start))
        XCTAssertEqual(polished.map(\.speakerId), original.map(\.speakerId))

        XCTAssertNil(TranscriptPolishing.apply(
            #"[{"index":0,"text":"Account ID"}]"#,
            to: original,
            expectedIndices: [0, 1]
        ))
    }

    func testTranscriptPolishingUsesModelFriendlyContextBatches() {
        let segments = (0..<25).map {
            TranscriptSegment(start: Double($0), end: Double($0 + 1), speakerId: 1, text: "fragment \($0)")
        }

        XCTAssertEqual(TranscriptPolishing.batches(for: segments).map(\.count), [24, 1])
    }
}

final class SummaryModelTests: XCTestCase {
    func testCustomModelRoundTrips() {
        let model = SummaryModel.custom("qwen3.5:latest")
        XCTAssertEqual(model.rawValue, "custom:qwen3.5:latest")
        XCTAssertEqual(SummaryModel(rawValue: model.rawValue), model)
    }

    func testRemovedRemoteOverrideIsIgnored() {
        XCTAssertNil(SummaryModel(rawValue: "azure:old-deployment"))
    }
}

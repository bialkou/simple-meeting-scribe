import XCTest
@testable import MeetingTranscriber

final class TranscriptMergerTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, _ text: String) -> WhisperSegment {
        WhisperSegment(start: start, end: end, text: text)
    }

    func testMergesLocalVoiceAndDiarizedSystemStemsInTimeOrder() {
        let result = TranscriptMerger.mergeStems(
            voice: [segment(2, 3, "You later"), segment(0, 1, "You first")],
            system: [segment(1, 2, "Remote one"), segment(3, 4, "Remote two")],
            systemDiarization: [
                DiarizedSegment(start: 1, end: 2, speakerId: 8),
                DiarizedSegment(start: 3, end: 4, speakerId: 9)
            ])

        XCTAssertEqual(result.segments.map(\.text), ["You first", "Remote one", "You later", "Remote two"])
        XCTAssertEqual(result.speakers.map(\.name), ["You", "Remote 1", "Remote 2"])
        XCTAssertEqual(result.segments.map(\.speakerId), [1, 2, 1, 3])
    }

    func testVoiceOnlyTranscriptHasOnlyYou() {
        let result = TranscriptMerger.mergeStems(
            voice: [segment(0, 1, "Hello")], system: [], systemDiarization: [])
        XCTAssertEqual(result.speakers.map(\.name), ["You"])
        XCTAssertEqual(result.segments.map(\.speakerId), [1])
    }
}

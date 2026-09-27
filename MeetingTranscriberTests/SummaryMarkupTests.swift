import Foundation
import XCTest
@testable import MeetingTranscriber

final class SummaryMarkupTests: XCTestCase {
    func testParsesSectionsAndRemovesTimestampMarkers() {
        let raw = """
        # Overall Summary
        The team agreed on the rollout plan.

        # Key Points
        - The local endpoint is ready [[1:16]].
        - The data contract was reviewed [[00:03:16]]

        # Action Items
        - Vitali will update the dashboard [[8:00]]

        # Open Questions
        - Which channel owns the alerting? [[12:34]]
        """

        let document = SummaryMarkup.parse(raw, duration: 900)

        XCTAssertEqual(document?.sections.map(\.title), [
            "Overall Summary", "Key Points", "Action Items", "Open Questions"
        ])
        XCTAssertEqual(document?.sections[0].body, "The team agreed on the rollout plan.")
        XCTAssertEqual(document?.sections[1].bullets[0].text, "The local endpoint is ready")
        XCTAssertEqual(document?.sections[1].bullets[0].timestamp, 76)
        XCTAssertEqual(document?.sections[1].bullets[1].timestamp, 196)
        XCTAssertEqual(document?.sections[2].bullets[0].timestamp, 480)
    }

    func testPlainOldSummaryFallsBack() {
        XCTAssertNil(SummaryMarkup.parse("A short paragraph without sections.", duration: 120))
    }

    func testTimestampedLLMFeedKeepsSegmentStartTimes() {
        let document = TranscriptDocument(
            id: "summary-feed",
            title: "Test",
            date: Date(timeIntervalSince1970: 0),
            duration: 80,
            language: .russian,
            modelShortName: "test",
            sourceURL: nil,
            sourceKind: .live,
            speakers: [SpeakerLabel(id: 0, name: "Виталий")],
            segments: [
                TranscriptSegment(start: 0, end: 2, speakerId: 0, text: "Привет"),
                TranscriptSegment(start: 61, end: 63, speakerId: 0, text: "Готово")
            ],
            audioFileName: nil
        )

        XCTAssertEqual(
            TranscriptFormatter.renderPlainForLLM(document, includeTimestamps: true),
            "[0:00] Виталий: Привет\n[1:01] Виталий: Готово\n"
        )
    }
}

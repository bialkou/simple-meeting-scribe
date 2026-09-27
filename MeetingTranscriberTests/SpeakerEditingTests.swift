import Foundation
import XCTest
@testable import MeetingTranscriber

final class SpeakerEditingTests: XCTestCase {
    func testLanguageTagsUseISOUppercaseCodes() {
        XCTAssertEqual(TranscriptionLanguage.russian.tag, "RU")
        XCTAssertEqual(TranscriptionLanguage.english.tag, "EN")
        XCTAssertEqual(TranscriptionLanguage.polish.tag, "PL")
    }

    func testMergeReassignsSegmentsAndRemovesSourceLabel() {
        let document = makeDocument()
        let merged = SpeakerEditing.merge(document, sourceID: 1, into: 0)

        XCTAssertEqual(merged?.speakers.map(\.id), [0])
        XCTAssertEqual(merged?.segments.map(\.speakerId), [0, 0, 0])
    }

    func testSplitMovesOnlySelectedSegmentsToANewSpeaker() {
        let document = makeDocument()
        let selected = Set([document.segments[1].id])
        let split = SpeakerEditing.split(document,
                                         speakerID: 1,
                                         segmentIDs: selected,
                                         newName: "Павел")

        XCTAssertEqual(split?.speakers.map(\.name), ["Виталий", "Павел", "Павел"])
        XCTAssertEqual(split?.segments.map(\.speakerId), [0, 2, 1])
    }

    func testSplitRejectsMovingEverySourceSegment() {
        let document = makeDocument()
        let selected = Set(document.segments.filter { $0.speakerId == 1 }.map(\.id))

        XCTAssertNil(SpeakerEditing.split(document,
                                          speakerID: 1,
                                          segmentIDs: selected,
                                          newName: "Павел"))
    }

    private func makeDocument() -> TranscriptDocument {
        let first = TranscriptSegment(start: 0, end: 1, speakerId: 0, text: "Привет")
        let second = TranscriptSegment(start: 1, end: 2, speakerId: 1, text: "Здравствуйте")
        let third = TranscriptSegment(start: 2, end: 3, speakerId: 1, text: "До встречи")
        return TranscriptDocument(
            id: "speaker-editing",
            title: "Test",
            date: Date(timeIntervalSince1970: 0),
            duration: 3,
            language: .russian,
            modelShortName: "test",
            sourceURL: nil,
            sourceKind: .live,
            speakers: [SpeakerLabel(id: 0, name: "Виталий"),
                       SpeakerLabel(id: 1, name: "Павел")],
            segments: [first, second, third],
            audioFileName: nil
        )
    }
}

import XCTest
@testable import MeetingTranscriber

final class WhisperModelTests: XCTestCase {
    func testLocalTurboIsTheDefaultModel() {
        XCTAssertEqual(WhisperModel.defaultModel, .largeV3Turbo)
    }

    func testAllTranscriptionModelsAreLocal() {
        XCTAssertEqual(WhisperModel.allCases.count, 4)
        XCTAssertFalse(WhisperModel.allCases.contains { $0.rawValue.contains("azure") })
        XCTAssertFalse(WhisperModel.allCases.contains { $0.rawValue.contains("elevenlabs") })
    }

    func testShortNamesAreUnique() {
        let names = WhisperModel.allCases.map(\.shortName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertEqual(WhisperModel.largeV3Turbo.shortName, "large-v3-turbo")
    }
}

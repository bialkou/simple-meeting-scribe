import Foundation

/// The three LLM passes of a summary run and their generation settings.
enum SummaryPass: Sendable {
    case identifySpeakers
    case polishTranscript
    case summary
    case title

    var localMaxTokens: Int {
        switch self {
        case .identifySpeakers: 200
        case .polishTranscript: 2_048
        case .summary:          600
        case .title:            40
        }
    }

    var localTemperature: Float {
        switch self {
        case .identifySpeakers: 0.1
        case .polishTranscript: 0.1
        case .summary:          0.3
        case .title:            0.2
        }
    }

    /// Larger caps leave room for local endpoint models that expose reasoning
    /// tokens in the same stream as the answer.
    var endpointMaxTokens: Int {
        switch self {
        case .identifySpeakers: 4_000
        case .polishTranscript: 8_192
        case .summary:          16_000
        // Qwen3.6 can spend a substantial part of a short title request in
        // reasoning before it emits visible text. Keep enough headroom so
        // `finish_reason=length` does not abort an otherwise valid run.
        case .title:            4_096
        }
    }
}

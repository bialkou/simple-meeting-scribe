import Foundation

/// A model the user can summarize with: one of the bundled MLX models, or a
/// model exposed by the configured local OpenAI-compatible endpoint.
///
/// Persisted as a single string so existing settings and transcripts keep
/// decoding: a local model is its HuggingFace repo ID (the historic
/// `LanguageModel` raw value), an endpoint model is `custom:<model-id>`.
enum SummaryModel: RawRepresentable, Codable, Hashable, Sendable {
    case local(LanguageModel)
    case custom(String)

    private static let customPrefix = "custom:"

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.customPrefix) {
            let id = String(rawValue.dropFirst(Self.customPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            self = .custom(id)
        } else if let model = LanguageModel(rawValue: rawValue) {
            self = .local(model)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .local(let model): model.rawValue
        case .custom(let id):   Self.customPrefix + id
        }
    }
}

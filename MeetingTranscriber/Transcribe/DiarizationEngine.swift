import Foundation
import FluidAudio

/// Wraps FluidAudio's Core ML port of NVIDIA Nemotron 3 Diarization.
actor DiarizationEngine {
    private let config = Nemotron3Config.fast32
    private var diarizer: Nemotron3Diarizer?

    func diarize(wavURL: URL,
                 progress: @escaping (Double, String) -> Void) async throws -> [DiarizedSegment] {
        progress(0.05, "Preparing audio")
        let samples = try AudioConverter().resampleAudioFile(path: wavURL.path)
        guard !samples.isEmpty else { return [] }

        progress(0.15, "Loading Nemotron 3 Diarization")
        if diarizer == nil {
            let models = try await Nemotron3Models.loadFromHuggingFace(
                config: config,
                progressHandler: { status in
                    let fraction = min(max(status.fractionCompleted, 0), 1)
                    progress(0.15 + fraction * 0.20, "Loading Nemotron 3 Diarization")
                }
            )
            diarizer = Nemotron3Diarizer(config: config, models: models)
        }

        progress(0.35, "Analyzing speakers")
        guard let diarizer else { return [] }
        let (probabilities, frameCount) = try diarizer.processComplete(samples)
        let segments = Nemotron3Diarizer.segments(
            probabilities: probabilities,
            frameCount: frameCount,
            numSpeakers: config.numSpeakers
        )

        return segments.map {
            DiarizedSegment(
                start: Double($0.startSeconds),
                end: Double($0.endSeconds),
                speakerId: $0.speakerIndex
            )
        }
    }
}

struct DiarizedSegment: Hashable {
    let start: Double
    let end: Double
    let speakerId: Int
}

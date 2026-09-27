import AVFoundation
import Foundation
import GigaAMKit

actor GigaAMEngine {
    private var recognizer: GigaAMRecognizer?

    func transcribe(
        url: URL,
        progress: @escaping (Double, String) -> Void
    ) async throws -> [WhisperSegment] {
        let modelDirectory: URL
        if recognizer == nil {
            modelDirectory = try await GigaAMModelStore.ensureInstalled { fraction, stage in
                progress(fraction * 0.2, stage)
            }
            progress(0.25, "Loading GigaAM-v3 RNNT")
            recognizer = try GigaAMRecognizer(
                configuration: GigaAMConfiguration(modelDirectory: modelDirectory)
            )
            Log.gigaam.notice("GigaAM-v3 RNNT loaded from \(modelDirectory.path, privacy: .public)")
        } else {
            modelDirectory = SummaryStore.cacheDirectory(forRepoID: "kruatech/gigaam-v3-mlx")
        }

        guard let recognizer else { return [] }

        progress(0.35, "Loading audio for GigaAM…")
        let audio = try AudioLoader.loadMonoFloat32(
            url: url,
            targetSampleRate: recognizer.configuration.sampleRate
        )
        let sampleRate = audio.sampleRate
        let chunkSamples = max(sampleRate, Int(recognizer.configuration.chunkDuration * Double(sampleRate)))
        let overlapSamples = sampleRate
        let stepSamples = max(1, chunkSamples - overlapSamples)
        var chunkStarts: [Int] = []
        var nextStart = 0
        while nextStart < audio.samples.count {
            chunkStarts.append(nextStart)
            if nextStart + chunkSamples >= audio.samples.count { break }
            nextStart += stepSamples
        }
        let featureExtractor = try GigaAMFeatureExtractor(modelDirectory: modelDirectory)
        var tokens: [ParakeetToken] = []
        var fallbackTexts: [String] = []

        for (index, startSample) in chunkStarts.enumerated() {
            try Task.checkCancellation()
            let endSample = min(startSample + chunkSamples, audio.samples.count)
            let chunk = Array(audio.samples[startSample..<endSample])
            let features = try featureExtractor.compute(samples: chunk)

            let result = try recognizer.transcribe(
                features: features.values,
                shape: features.shape,
                length: features.length
            )
            fallbackTexts.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))

            let chunkDuration = Double(endSample - startSample) / Double(sampleRate)
            let ownedStart = index == 0 ? 0 : 0.5
            let ownedEnd = index == chunkStarts.count - 1 ? chunkDuration : chunkDuration - 0.5
            let offset = Double(startSample) / Double(sampleRate)

            for word in result.words {
                let midpoint = (word.start + word.end) / 2
                guard midpoint >= ownedStart, midpoint < ownedEnd else { continue }
                tokens.append(ParakeetToken(
                    text: tokens.isEmpty ? word.text : " \(word.text)",
                    start: offset + word.start,
                    end: offset + word.end
                ))
            }

            let completed = Double(index + 1) / Double(chunkStarts.count)
            progress(
                0.35 + completed * 0.45,
                "Transcribing with GigaAM · \(index + 1)/\(chunkStarts.count)"
            )
        }

        progress(0.85, "Preparing transcript")
        let segments = ParakeetSegmenter.segments(from: tokens)
        if !segments.isEmpty { return segments }

        let text = fallbackTexts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return [] }
        return [WhisperSegment(
            start: 0,
            end: Double(audio.samples.count) / Double(sampleRate),
            text: text
        )]
    }

    private static func fileDuration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

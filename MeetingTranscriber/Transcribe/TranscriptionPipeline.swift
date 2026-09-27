import Foundation
import OSLog

struct TranscriptionResult {
    let document: TranscriptDocument
    let warnings: [String]
}

/// Drives the local transcribe + diarize + merge pass across the voice stem
/// (mic) and the optional system-audio stem. Each stem is transcribed
/// independently so overlapping voices do not fight for Whisper's attention.
final class TranscriptionPipeline {
    private let whisper = WhisperEngine()
    private let diarizer = DiarizationEngine()
    private let parakeet = ParakeetEngine()
    private let gigaam = GigaAMEngine()

    func run(voiceURL: URL,
             systemURL: URL?,
             duration: TimeInterval,
             language: TranscriptionLanguage,
             model: WhisperModel,
             meeting: DetectedMeeting?,
             sourceKind: TranscriptDocument.SourceKind,
             importedFileName: String?,
             initialPrompt: String?,
             wordReplacements: [WordReplacement],
             progress: @escaping (Double, String) -> Void) async throws -> TranscriptionResult {

        Log.pipeline.notice("starting voice=\(voiceURL.lastPathComponent, privacy: .public) system=\(systemURL?.lastPathComponent ?? "-", privacy: .public) duration=\(Int(duration), privacy: .public)s")

        let cutoff = duration + 0.5
        var voiceSegments: [WhisperSegment] = []
        var systemSegments: [WhisperSegment] = []
        var voiceDiarization: [DiarizedSegment] = []
        var systemDiarization: [DiarizedSegment] = []
        var warnings: [String] = []

        if (model.isParakeet || model.isGigaAM),
           let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            Log.pipeline.notice("selected model has no prompt input; ignoring prime: \(prompt, privacy: .public)")
        }

        func transcribeLocal(_ url: URL,
                             progress report: @escaping (Double, String) -> Void) async throws -> [WhisperSegment] {
            if model.isParakeet {
                return try await parakeet.transcribe(url: url, progress: report)
            }
            if model.isGigaAM {
                return try await gigaam.transcribe(url: url, progress: report)
            }
            return try await whisper.transcribe(url: url,
                                                language: language,
                                                model: model,
                                                initialPrompt: initialPrompt,
                                                progress: report)
        }

        progress(0.05, "Transcribing your voice")
        voiceSegments = try await transcribeLocal(
            voiceURL,
            progress: { p, stage in progress(0.05 + p * 0.30, stage) }
        )
        Log.pipeline.notice("voice produced \(voiceSegments.count, privacy: .public) segments")

        if let systemURL {
            progress(0.40, "Transcribing system audio")
            do {
                systemSegments = try await transcribeLocal(
                    systemURL,
                    progress: { p, stage in progress(0.40 + p * 0.30, stage) }
                )
                Log.pipeline.notice("system produced \(systemSegments.count, privacy: .public) segments")
            } catch {
                Log.pipeline.error("system transcription failed — \(String(describing: error), privacy: .public) (continuing)")
            }

            do {
                systemDiarization = try await diarizer.diarize(
                    wavURL: systemURL,
                    progress: { p, stage in progress(0.70 + p * 0.15, stage) }
                )
                Log.pipeline.notice("system diarizer produced \(systemDiarization.count, privacy: .public) segments")
                if systemDiarization.isEmpty && !systemSegments.isEmpty {
                    warnings.append("Nemotron found no speaker regions in the transcribed system audio; it will use one speaker label.")
                }
            } catch {
                Log.pipeline.error("system diarizer failed — \(String(describing: error), privacy: .public)")
                warnings.append("Speaker diarization failed: \(error.localizedDescription)")
            }
        } else {
            progress(0.70, "Diarizing speakers")
            do {
                voiceDiarization = try await diarizer.diarize(
                    wavURL: voiceURL,
                    progress: { p, stage in progress(0.70 + p * 0.15, stage) }
                )
                Log.pipeline.notice("single-track diarizer produced \(voiceDiarization.count, privacy: .public) segments")
                if voiceDiarization.isEmpty && !voiceSegments.isEmpty {
                    warnings.append("Nemotron found no speaker regions in the transcribed audio; it will use one speaker label.")
                }
            } catch {
                Log.pipeline.error("single-track diarizer failed — \(String(describing: error), privacy: .public)")
                warnings.append("Speaker diarization failed: \(error.localizedDescription)")
            }
        }

        progress(0.92, "Merging")
        let trimmedVoice = voiceSegments.filter { $0.start < cutoff }
        let trimmedSystem = systemSegments.filter { $0.start < cutoff }
        if trimmedVoice.count != voiceSegments.count || trimmedSystem.count != systemSegments.count {
            Log.pipeline.notice("trimmed \((voiceSegments.count + systemSegments.count) - (trimmedVoice.count + trimmedSystem.count), privacy: .public) hallucination(s) past end-of-audio")
        }

        var merged: (segments: [TranscriptSegment], speakers: [SpeakerLabel])
        if systemURL == nil {
            merged = TranscriptMerger.mergeSingleTrack(
                trimmedVoice,
                diarization: voiceDiarization
            )
        } else {
            merged = TranscriptMerger.mergeStems(
                voice: trimmedVoice,
                system: trimmedSystem,
                systemDiarization: systemDiarization
            )
        }

        if !wordReplacements.isEmpty {
            merged.segments = merged.segments.map { segment in
                TranscriptSegment(
                    id: segment.id,
                    start: segment.start,
                    end: segment.end,
                    speakerId: segment.speakerId,
                    text: WordReplacementService.apply(wordReplacements, to: segment.text)
                )
            }
        }

        progress(0.98, "Saving")
        let id = Self.makeID()
        let title = meeting?.title ?? (importedFileName ?? Self.fallbackTitle(from: voiceURL))

        let document = TranscriptDocument(
            id: id,
            title: title,
            date: Date(),
            duration: duration,
            language: language,
            modelShortName: model.shortName,
            sourceURL: meeting?.url ?? importedFileName,
            sourceKind: sourceKind,
            speakers: merged.speakers,
            segments: merged.segments,
            audioFileName: voiceURL.lastPathComponent
        )
        return TranscriptionResult(document: document, warnings: warnings)
    }

    private static func makeID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func fallbackTitle(from url: URL) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording — \(formatter.string(from: Date()))"
    }
}

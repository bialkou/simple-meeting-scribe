import Accelerate
import Foundation
import GigaAMKit

/// Accelerate-backed replacement for GigaAMKit's scalar STFT loop.
/// Processes one short audio window at a time to keep feature memory bounded.
struct GigaAMFeatureExtractor {
    struct Features {
        let values: [Float]
        let shape: [Int]
        let length: Int
    }

    private static let config = MelSpectrogramConfig()
    private static let nFreqs = config.nFFT / 2 + 1
    private static let dftMatrices: (cosine: [Float], negativeSine: [Float]) = {
        var cosine = [Float](repeating: 0, count: config.nFFT * nFreqs)
        var negativeSine = [Float](repeating: 0, count: config.nFFT * nFreqs)
        let twoPi = 2.0 * Double.pi

        for sampleIndex in 0..<config.nFFT {
            for frequencyIndex in 0..<nFreqs {
                let angle = twoPi * Double(frequencyIndex * sampleIndex) / Double(config.nFFT)
                let offset = sampleIndex * nFreqs + frequencyIndex
                cosine[offset] = Float(cos(angle))
                negativeSine[offset] = -Float(sin(angle))
            }
        }

        return (cosine, negativeSine)
    }()

    private let window: [Float]
    private let transposedFilterbank: [Float]

    init(modelDirectory: URL) throws {
        let window = try Self.readFloat32(
            from: modelDirectory.appendingPathComponent("hann_window.f32.bin")
        )
        let filterbank = try Self.readFloat32(
            from: modelDirectory.appendingPathComponent("mel_filterbank_mel_freq.f32.bin")
        )
        guard window.count == Self.config.winLength,
              filterbank.count == Self.config.nMels * Self.nFreqs else {
            throw GigaAMFeatureError.invalidAssets
        }

        self.window = window
        var transposed = [Float](repeating: 0, count: filterbank.count)
        for mel in 0..<Self.config.nMels {
            for frequency in 0..<Self.nFreqs {
                transposed[frequency * Self.config.nMels + mel] =
                    filterbank[mel * Self.nFreqs + frequency]
            }
        }
        self.transposedFilterbank = transposed
    }

    func compute(samples: [Float]) throws -> Features {
        let config = Self.config
        guard samples.count >= config.winLength else {
            throw GigaAMFeatureError.audioTooShort
        }

        let frameCount = (samples.count - config.winLength) / config.hopLength + 1
        let frameValueCount = frameCount * config.nFFT
        var frames = [Float](repeating: 0, count: frameValueCount)
        for frame in 0..<frameCount {
            let sourceOffset = frame * config.hopLength
            let targetOffset = frame * config.nFFT
            for sample in 0..<config.nFFT {
                frames[targetOffset + sample] = samples[sourceOffset + sample] * window[sample]
            }
        }

        let spectrumValueCount = frameCount * Self.nFreqs
        var real = [Float](repeating: 0, count: spectrumValueCount)
        var imaginary = [Float](repeating: 0, count: spectrumValueCount)
        let (cosine, negativeSine) = Self.dftMatrices
        frames.withUnsafeBufferPointer { frameBuffer in
            cosine.withUnsafeBufferPointer { cosineBuffer in
                real.withUnsafeMutableBufferPointer { realBuffer in
                    vDSP_mmul(
                        frameBuffer.baseAddress!, 1,
                        cosineBuffer.baseAddress!, 1,
                        realBuffer.baseAddress!, 1,
                        vDSP_Length(frameCount), vDSP_Length(Self.nFreqs), vDSP_Length(config.nFFT)
                    )
                }
            }
            negativeSine.withUnsafeBufferPointer { sineBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    vDSP_mmul(
                        frameBuffer.baseAddress!, 1,
                        sineBuffer.baseAddress!, 1,
                        imaginaryBuffer.baseAddress!, 1,
                        vDSP_Length(frameCount), vDSP_Length(Self.nFreqs), vDSP_Length(config.nFFT)
                    )
                }
            }
        }

        var power = [Float](repeating: 0, count: spectrumValueCount)
        for index in 0..<spectrumValueCount {
            power[index] = real[index] * real[index] + imaginary[index] * imaginary[index]
        }

        let melValueCount = frameCount * config.nMels
        var melByFrame = [Float](repeating: 0, count: melValueCount)
        power.withUnsafeBufferPointer { powerBuffer in
            transposedFilterbank.withUnsafeBufferPointer { filterbankBuffer in
                melByFrame.withUnsafeMutableBufferPointer { melBuffer in
                    vDSP_mmul(
                        powerBuffer.baseAddress!, 1,
                        filterbankBuffer.baseAddress!, 1,
                        melBuffer.baseAddress!, 1,
                        vDSP_Length(frameCount), vDSP_Length(config.nMels), vDSP_Length(Self.nFreqs)
                    )
                }
            }
        }

        var melMajor = [Float](repeating: 0, count: melValueCount)
        for mel in 0..<config.nMels {
            for frame in 0..<frameCount {
                let value = min(max(melByFrame[frame * config.nMels + mel], 1e-9), 1e9)
                melMajor[mel * frameCount + frame] = logf(value)
            }
        }

        return Features(values: melMajor, shape: [1, config.nMels, frameCount], length: frameCount)
    }

    private static func readFloat32(from url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw GigaAMFeatureError.invalidAssets
        }

        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }
        return values
    }
}

private enum GigaAMFeatureError: LocalizedError {
    case audioTooShort
    case invalidAssets

    var errorDescription: String? {
        switch self {
        case .audioTooShort:
            "Audio chunk is shorter than GigaAM's analysis window."
        case .invalidAssets:
            "GigaAM feature extraction assets are missing or invalid."
        }
    }
}

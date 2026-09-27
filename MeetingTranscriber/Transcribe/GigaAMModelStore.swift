import CryptoKit
import Foundation

enum GigaAMModelStore {
    private struct Asset {
        let filename: String
        let sha256: String
    }

    private static let repoID = "kruatech/gigaam-v3-mlx"
    private static let revision = "2478743c1c449a468ee163bc3030170d1a2e81fb"
    private static let markerName = ".meetx-gigaam-\(revision).verified"
    private static let assets = [
        Asset(filename: "manifest.json", sha256: "993c538b6dceffb7b018c633a7cc8e4034e7ca975b5c27ecc8ecd679fa574d16"),
        Asset(filename: "weights.fp16.safetensors", sha256: "2ff6d955a61003e0d3cb2155be36c14aa3df69c879713f30880ddd07d71fde21"),
        Asset(filename: "tokenizer.model", sha256: "828c12c991019eef952a960661f25a92d6ad279591e2ea466b4aeddf1d20a18a"),
        Asset(filename: "tokenizer_vocab.json", sha256: "84e15355333a8eb460b2f899947e9976b8c036f4dd086002e43b987ddf4cc606"),
        Asset(filename: "hann_window.f32.bin", sha256: "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f"),
        Asset(filename: "mel_filterbank_mel_freq.f32.bin", sha256: "e9425a25940359fb85efeaf6651f81679971a1c46bec1af3aba943ec8a5fd793")
    ]

    static func ensureInstalled(
        progress: (Double, String) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let destination = SummaryStore.cacheDirectory(forRepoID: repoID)
        if try isValidModel(at: destination) { return destination }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".gigaam-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(assets.count), "Downloading GigaAM-v3 RNNT — \(asset.filename)")

            let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(asset.filename)")!
            let (downloadedFile, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse else {
                try? fileManager.removeItem(at: downloadedFile)
                throw ModelError.invalidResponse(asset.filename)
            }
            guard http.statusCode == 200 else {
                try? fileManager.removeItem(at: downloadedFile)
                throw ModelError.httpStatus(asset.filename, http.statusCode)
            }

            guard try sha256(of: downloadedFile) == asset.sha256 else {
                try? fileManager.removeItem(at: downloadedFile)
                throw ModelError.checksumMismatch(asset.filename)
            }
            try fileManager.moveItem(
                at: downloadedFile,
                to: staging.appendingPathComponent(asset.filename)
            )
            progress(Double(index + 1) / Double(assets.count), "Downloaded GigaAM-v3 RNNT — \(asset.filename)")
        }

        try Data("verified \(revision)\n".utf8)
            .write(to: staging.appendingPathComponent(markerName), options: .atomic)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        return destination
    }

    private static func isValidModel(at directory: URL) throws -> Bool {
        let fileManager = FileManager.default
        guard assets.allSatisfy({
            fileManager.fileExists(atPath: directory.appendingPathComponent($0.filename).path)
        }) else { return false }

        if fileManager.fileExists(atPath: directory.appendingPathComponent(markerName).path) {
            return true
        }

        for asset in assets {
            guard try sha256(of: directory.appendingPathComponent(asset.filename)) == asset.sha256 else {
                return false
            }
        }
        try Data("verified \(revision)\n".utf8)
            .write(to: directory.appendingPathComponent(markerName), options: .atomic)
        return true
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum ModelError: LocalizedError {
        case invalidResponse(String)
        case httpStatus(String, Int)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let file): "Invalid response while downloading GigaAM asset \(file)."
            case .httpStatus(let file, let status): "GigaAM asset \(file) download failed (HTTP \(status))."
            case .checksumMismatch(let file): "GigaAM asset \(file) failed its SHA-256 check."
            }
        }
    }
}

@preconcurrency import AVFoundation
import Photos

enum PhotoLibrary {
    static var canSave: Bool {
        PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }
    static func requestAccess() async -> Bool {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
    }
    static func savePhoto(_ data: Data) async throws {
        guard canSave else { throw APIError(status: 0, message: "Photos access off") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
    static func saveVideo(queue: UploadQueue, accountId: String, captureId: String) async throws {
        guard canSave else { throw APIError(status: 0, message: "Photos access off") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await exportVideo(parts: queue.videoParts(accountId: accountId, captureId: captureId), in: directory)
        try await saveVideoFile(movie)
    }
    static func saveVideoFile(_ movie: URL) async throws {
        guard canSave else { throw APIError(status: 0, message: "Photos access off") }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: movie, options: nil)
        }
    }
    // Reuse the encoded upload fragments. Disk assembly and passthrough export never run on the capture queue.
    static func exportVideo(parts: [URL], in directory: URL) async throws -> URL {
        let fragments = directory.appendingPathComponent("fragments.mp4")
        defer { try? FileManager.default.removeItem(at: fragments) }
        try Data().write(to: fragments, options: .completeFileProtectionUntilFirstUserAuthentication)
        let output = try FileHandle(forWritingTo: fragments)
        do {
            for part in parts { try output.write(contentsOf: Data(contentsOf: part)) }
            try output.close()
        } catch { try? output.close(); throw error }
        let asset = AVURLAsset(url: fragments)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let movie = directory.appendingPathComponent("video.mp4")
        if #available(iOS 18, macOS 15, *) {
            try await exporter.export(to: movie, as: .mp4)
        } else {
            exporter.outputURL = movie
            exporter.outputFileType = .mp4
            await exporter.export()
            guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
        }
        return movie
    }
}

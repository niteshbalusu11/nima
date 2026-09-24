@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// Previews use the retained originals, so viewing media never waits for an upload.
actor CaptureLibrary {
    private var deleted: Set<String> = []
    private var thumbnails: [String: Data] = [:]
    private var videos: [String: Task<URL, Error>] = [:]
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePreviews-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: directory) }

    func thumbnail(for capture: LocalCapture) async throws -> Data {
        let key = "\(capture.accountId)/\(capture.id)"
        guard !deleted.contains(key) else { throw CancellationError() }
        if let data = thumbnails[key] { return data }
        let image: CGImage
        if capture.kind == "photo" {
            guard let source = CGImageSourceCreateWithURL(capture.parts[0] as CFURL, nil),
                  let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = preview
        } else {
            let asset = AVURLAsset(url: try await video(for: capture))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            image = try await generator.image(at: .zero).image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let result = data as Data
        guard !deleted.contains(key) else { throw CancellationError() }
        thumbnails[key] = result
        return result
    }
    func remove(accountId: String, captureId: String) async throws {
        let key = "\(accountId)/\(captureId)"
        deleted.insert(key)
        thumbnails[key] = nil
        let pending = videos.filter { $0.key.hasPrefix(key + "/") }
        for (name, task) in pending { task.cancel(); videos[name] = nil }
        for task in pending.values { _ = await task.result }
        let folder = directory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
    func photo(for capture: LocalCapture) throws -> Data { try Data(contentsOf: capture.parts[0]) }
    func video(for capture: LocalCapture) async throws -> URL {
        guard !deleted.contains("\(capture.accountId)/\(capture.id)") else { throw CancellationError() }
        guard capture.playable else { throw APIError(status: 0, message: "Video incomplete") }
        let key = "\(capture.accountId)/\(capture.id)/\(capture.parts.count)"
        if let task = videos[key] { return try await task.value }
        let folder = directory.appendingPathComponent(key)
        let task = Task {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try await PhotoLibrary.exportVideo(parts: capture.parts, in: folder)
        }
        videos[key] = task
        do { return try await task.value }
        catch { videos[key] = nil; throw error }
    }
}

// macOS integration probe: the SAME encoder, persistent queue, and uploader used by the iPhone app.
@preconcurrency import AVFoundation
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct MediaProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("usage: media-probe API_URL SESSION_JSON OUTPUT_DIRECTORY") }
        let base = URL(string: CommandLine.arguments[1])!
        let session = try API.decoder.decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let root = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let queue = try UploadQueue(root: root)
        let worker = UploadWorker(api: API(baseURL: base, token: session.token), queue: queue, accountId: session.accountId)
        let videoID = UUID().uuidString.lowercased()
        let photoID = UUID().uuidString.lowercased()
        let failures = ProbeFailures()
        let writer = try SegmentWriter(startTime: CMTime(value: 100, timescale: 1), includeAudio: true) { data, sequence, kind, duration, start in
            do {
                try queue.enqueue(data, accountId: session.accountId, captureId: videoID, captureKind: "video",
                                  sequence: sequence, kind: kind, duration: duration, startTime: start)
            } catch { failures.record(error) }
        }
        let tasks = ["video", "photo"].map { kind in
            Task.detached {
                while !Task.isCancelled {
                    if let item = queue.next(accountId: session.accountId, captureKind: kind) {
                        do { try await worker.send(item) } catch { failures.record(error); return }
                    } else { try? await Task.sleep(for: .milliseconds(30)) }
                }
            }
        }
        var liveVerified = false
        for frame in 0..<105 {
            // A deliberate 200 ms gap verifies that dropped frames preserve audio/video time.
            if !(27...29).contains(frame) { try writer.append(videoSample(frame), isVideo: true) }
            try writer.append(audioSample(frame), isVideo: false)
            if frame == 30 {
                try queue.enqueue(jpeg(), accountId: session.accountId, captureId: photoID, captureKind: "photo", sequence: 0, kind: "photo")
            }
            if frame == 75 {
                struct Capture: Decodable, Sendable {
                    struct Object: Decodable, Sendable { let kind: String; let acknowledged: Bool; let url: String? }
                    let objects: [Object]
                }
                let api = API(baseURL: base, token: session.token)
                let remoteVideo: Capture = try await api.request("GET", "captures/\(videoID)")
                let remotePhoto: Capture = try await api.request("GET", "captures/\(photoID)")
                guard remoteVideo.objects.filter({ $0.kind == "media" && $0.acknowledged }).count >= 2,
                      remotePhoto.objects.first?.acknowledged == true else { fatalError("Media was not uploaded during recording") }
                var liveVideo = Data()
                for object in remoteVideo.objects where object.acknowledged {
                    let (data, _) = try await URLSession.shared.data(from: URL(string: object.url!)!)
                    liveVideo.append(data)
                }
                try liveVideo.write(to: root.appendingPathComponent("../live-before-stop.mp4"))
                print("LIVE VERIFIED: video fragments and photo retrieved before Stop")
                liveVerified = true
            }
            try await Task.sleep(for: .milliseconds(67))
        }
        let completed = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        guard completed, liveVerified else { fatalError("Encoder failed") }
        for _ in 0..<200 {
            if queue.pending(accountId: session.accountId) == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        tasks.forEach { $0.cancel() }
        try failures.check()
        guard queue.pending(accountId: session.accountId) == 0 else { fatalError("Queue did not drain") }
        // Reopening the queue must preserve saved state rather than uploading everything again.
        let reopened = try UploadQueue(root: root)
        guard reopened.pending(accountId: session.accountId) == 0 else { fatalError("Acknowledgments were not durable") }
        let gallery = reopened.captures(accountId: session.accountId)
        precondition(gallery.count == 2 && gallery.allSatisfy { $0.uploaded && $0.playable })
        let library = CaptureLibrary()
        for capture in gallery {
            let thumbnail = try await library.thumbnail(for: capture)
            precondition(CGImageSourceCreateWithData(thumbnail as CFData, nil) != nil)
        }
        let movie = try await PhotoLibrary.exportVideo(parts: reopened.videoParts(accountId: session.accountId, captureId: videoID),
                                                       in: root.deletingLastPathComponent())
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await videoTracks[0].load(.naturalSize)
        precondition(duration > 6.8 && duration < 7.2 && audioTracks.count == 1 && size == CGSize(width: 480, height: 640))
        let output = ["video_id": videoID, "photo_id": photoID]
        try JSONSerialization.data(withJSONObject: output).write(to: root.appendingPathComponent("../captures.json"))
        print("PASS: audio/video, frame gap, concurrent photo, queue reload, Photos MP4 export, gallery thumbnails and status")
    }
    static func videoSample(_ frame: Int) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 480, 640, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.coderInvalidValue) }
        CVPixelBufferLockBaseAddress(pixel, [])
        let address = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<640 { for x in 0..<480 {
            let offset = y * stride + x * 4
            address[offset] = UInt8((x + frame * 3) % 256)
            address[offset + 1] = UInt8((y + frame * 2) % 256)
            address[offset + 2] = UInt8(frame % 256); address[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(value: Int64(1500 + frame), timescale: 15), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.coderInvalidValue) }; return sample
    }
    static func audioSample(_ frame: Int) throws -> CMSampleBuffer {
        let samples = 2940
        var desc = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &desc, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: samples * 2,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: samples * 2, flags: 0, blockBufferOut: &block)
        let wave = (0..<samples).map { Int16(sin(Double(frame * samples + $0) * 440 * 2 * .pi / 44100) * 4000) }
        wave.withUnsafeBytes { bytes in _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: CMTime(value: Int64(1500 + frame), timescale: 15), decodeTimeStamp: .invalid)
        var size = 2; var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw CocoaError(.coderInvalidValue) }; return sample
    }
    static func jpeg() throws -> Data {
        let pixels = Data(repeating: 120, count: 64 * 64 * 3)
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(width: 64, height: 64, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: 64 * 3,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: [], provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
private final class ProbeFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; self.error = error }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
}

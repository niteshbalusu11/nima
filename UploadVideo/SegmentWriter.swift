@preconcurrency import AVFoundation
import UniformTypeIdentifiers

// Sample appends and finish are confined to the capture queue. Delegate callbacks use their own lock.
final class SegmentWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let sourceStartTime: CMTime
    private let lock = NSLock()
    private var sequence = 0
    private let onSegment: @Sendable (Data, Int, String, Double, Double) -> Void
    init(startTime: CMTime, includeAudio: Bool,
         onSegment: @escaping @Sendable (Data, Int, String, Double, Double) -> Void) throws {
        self.onSegment = onSegment
        sourceStartTime = startTime
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 720, AVVideoHeightKey: 1280,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000, AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if includeAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input); audio = input
        } else { audio = nil }
        super.init()
        writer.delegate = self
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }
    func append(_ sample: CMSampleBuffer, isVideo: Bool, waitUntilReady: Bool = false) throws {
        guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard let input = isVideo ? video : audio else { return }
        if waitUntilReady {
            let deadline = Date().addingTimeInterval(30)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // Use one origin for both tracks, preserving audio sync and gaps from dropped frames.
        // HLS fragments otherwise retain the device's uptime as their media timeline.
        guard input.isReadyForMoreMediaData, CMSampleBufferGetPresentationTimeStamp(sample) >= sourceStartTime else { return }
        var count = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        let readStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil)
        guard readStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(readStatus)) }
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - sourceStartTime
            if timing[index].decodeTimeStamp.isValid { timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - sourceStartTime }
        }
        var adjusted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &adjusted)
        guard status == noErr, let adjusted else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        if !input.append(adjusted) {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    func finish(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard writer.status == .writing else { completion(false); return }
        video.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting { [self] in completion(writer.status == .completed) }
    }
    func cancel() { writer.cancelWriting() }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        let track = segmentReport?.trackReports.first { $0.mediaType == .video }
        onSegment(segmentData, sequence, segmentType == .initialization ? "init" : "media",
                  track?.duration.seconds ?? 0, track?.earliestPresentationTimeStamp.seconds ?? 0)
        sequence += 1
    }
}

private final class ImportSegmentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    let queue: UploadQueue
    let accountId: String
    let captureId: String

    init(queue: UploadQueue, accountId: String, captureId: String) {
        self.queue = queue; self.accountId = accountId; self.captureId = captureId
    }

    func receive(_ data: Data, sequence: Int, kind: String, duration: Double, startTime: Double) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        do {
            try queue.enqueue(data, accountId: accountId, captureId: captureId, captureKind: "video",
                              sequence: sequence, kind: kind, duration: duration, startTime: startTime)
        } catch { failure = error }
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }
}

enum ImportedVideoEncoder {
    static func enqueue(_ url: URL, queue: UploadQueue, accountId: String) async throws {
        try queue.checkSpace()
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw APIError(status: 0, message: "Video has no picture")
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        guard duration.isNumeric, duration.seconds > 0, naturalSize.width > 0, naturalSize.height > 0 else {
            throw APIError(status: 0, message: "Could not read video")
        }

        let sourceBounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
        let scale = min(720 / sourceBounds.width, 1280 / sourceBounds.height)
        let fitted = CGSize(width: sourceBounds.width * scale, height: sourceBounds.height * scale)
        let transform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -sourceBounds.minX, y: -sourceBounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (720 - fitted.width) / 2, y: (1280 - fitted.height) / 2))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: 720, height: 1280)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        videoOutput.videoComposition = composition
        reader.add(videoOutput)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioOutput = audioTrack.map { track in
            AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
        }
        if let audioOutput { reader.add(audioOutput) }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        let captureId = UUID().uuidString.lowercased()
        let sink = ImportSegmentSink(queue: queue, accountId: accountId, captureId: captureId)
        let writer: SegmentWriter
        do {
            writer = try SegmentWriter(startTime: .zero, includeAudio: audioOutput != nil) { data, sequence, kind, duration, startTime in
                sink.receive(data, sequence: sequence, kind: kind, duration: duration, startTime: startTime)
            }
        } catch { reader.cancelReading(); throw error }
        do {
            var videoSample = videoOutput.copyNextSampleBuffer()
            var audioSample = audioOutput?.copyNextSampleBuffer()
            guard videoSample != nil else { throw APIError(status: 0, message: "Video has no frames") }
            while videoSample != nil || audioSample != nil {
                try Task.checkCancellation()
                try sink.check()
                let takeVideo = audioSample == nil || (videoSample != nil &&
                    CMSampleBufferGetPresentationTimeStamp(videoSample!) <= CMSampleBufferGetPresentationTimeStamp(audioSample!))
                if takeVideo, let sample = videoSample {
                    try writer.append(sample, isVideo: true, waitUntilReady: true)
                    videoSample = videoOutput.copyNextSampleBuffer()
                } else if let sample = audioSample {
                    try writer.append(sample, isVideo: false, waitUntilReady: true)
                    audioSample = audioOutput?.copyNextSampleBuffer()
                }
            }
            guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            let finished = await withCheckedContinuation { continuation in
                writer.finish { continuation.resume(returning: $0) }
            }
            guard finished else { throw APIError(status: 0, message: "Could not convert video") }
            try sink.check()
            guard (try? queue.videoParts(accountId: accountId, captureId: captureId)) != nil else {
                throw APIError(status: 0, message: "Could not convert video")
            }
        } catch {
            reader.cancelReading()
            writer.cancel()
            try? queue.remove(accountId: accountId, captureId: captureId)
            throw error
        }
    }
}

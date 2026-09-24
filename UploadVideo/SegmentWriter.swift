@preconcurrency import AVFoundation
import UniformTypeIdentifiers

// Sample appends and finish are confined to the capture queue. Delegate callbacks use their own lock.
final class SegmentWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let lock = NSLock()
    private var sequence = 0
    private let onSegment: @Sendable (Data, Int, String, Double, Double) -> Void
    init(startTime: CMTime, includeAudio: Bool,
         onSegment: @escaping @Sendable (Data, Int, String, Double, Double) -> Void) throws {
        self.onSegment = onSegment
        writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialSegmentStartTime = startTime
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 640,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000, AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 15, AVVideoMaxKeyFrameIntervalDurationKey: 1,
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
        writer.startSession(atSourceTime: startTime)
    }
    func append(_ sample: CMSampleBuffer, isVideo: Bool) throws {
        guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard let input = isVideo ? video : audio else { return }
        // Discard raw samples instead of building an unbounded backlog. Keep their original PTS.
        if input.isReadyForMoreMediaData, !input.append(sample) {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    func finish(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard writer.status == .writing else { completion(false); return }
        video.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting { [self] in completion(writer.status == .completed) }
    }
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        let track = segmentReport?.trackReports.first { $0.mediaType == .video }
        onSegment(segmentData, sequence, segmentType == .initialization ? "init" : "media",
                  track?.duration.seconds ?? 0, track?.earliestPresentationTimeStamp.seconds ?? 0)
        sequence += 1
    }
}

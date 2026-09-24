@preconcurrency import AVFoundation
import Foundation

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                    AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate,
                    AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let work = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let video = AVCaptureVideoDataOutput()
    private let audio = AVCaptureAudioDataOutput()
    private let photos = AVCapturePhotoOutput()
    private let codes = AVCaptureMetadataOutput()
    private let uploadQueue: UploadQueue
    private let onError: @Sendable (String) -> Void
    private let onCode: @Sendable (String) -> Void
    private let onRecordingEnded: @Sendable () -> Void
    private var configured = false
    private var audioEnabled = false
    private var accountId: String?
    private var recordingId: String?
    private var writer: SegmentWriter?
    private var photoAccounts: [Int64: String] = [:]
    private var observations: [NSObjectProtocol] = []
    init(queue: UploadQueue, onError: @escaping @Sendable (String) -> Void,
         onCode: @escaping @Sendable (String) -> Void,
         onRecordingEnded: @escaping @Sendable () -> Void) {
        uploadQueue = queue; self.onError = onError; self.onCode = onCode; self.onRecordingEnded = onRecordingEnded
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.stopRecording(); self?.onError("Camera interrupted")
            })
        }
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    func start(accountId: String?) {
        work.async { [self] in
            self.accountId = accountId
            do {
                if !configured { try configure(); configured = true }
                if !session.isRunning { session.startRunning() }
            } catch { onError("Camera unavailable") }
        }
    }
    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photos) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        video.setSampleBufferDelegate(self, queue: work)
        session.addOutput(video); session.addOutput(photos)
        if let connection = video.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if let connection = photos.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if session.canAddOutput(codes) {
            session.addOutput(codes)
            codes.setMetadataObjectsDelegate(self, queue: work)
            if codes.availableMetadataObjectTypes.contains(.qr) { codes.metadataObjectTypes = [.qr] }
        }
        try device.lockForConfiguration()
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        }
        device.unlockForConfiguration()
    }
    private func enableAudio() {
        guard !audioEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        if session.canAddInput(input), session.canAddOutput(audio) {
            session.addInput(input); session.addOutput(audio)
            audio.setSampleBufferDelegate(self, queue: work); audioEnabled = true
        }
    }
    func record() {
        work.async { [self] in
            guard accountId != nil, recordingId == nil, session.isRunning else { onRecordingEnded(); return }
            do { try uploadQueue.checkSpace() } catch { onError("Storage full"); onRecordingEnded(); return }
            enableAudio(); recordingId = UUID().uuidString.lowercased()
        }
    }
    func stopRecording() { work.async { [self] in finishRecording() } }
    private func finishRecording() {
        guard let captureId = recordingId, let owner = accountId else { return }
        let finishing = writer
        recordingId = nil; writer = nil
        if let finishing {
            finishing.finish { [self, finishing] success in
                _ = finishing
                if !success { onError("Recording interrupted") }
                onRecordingEnded()
                if success {
                    Task {
                        do { try await PhotoLibrary.saveVideo(queue: uploadQueue, accountId: owner, captureId: captureId) }
                        catch { onError(PhotoLibrary.canSave ? "Could not save video to Photos" : "Photos access off") }
                    }
                }
            }
        } else { onRecordingEnded() }
    }
    func suspend() {
        work.async { [self] in
            finishRecording()
            if session.isRunning { session.stopRunning() }
        }
    }
    func takePhoto() {
        work.async { [self] in
            guard let accountId, session.isRunning else { return }
            do { try uploadQueue.checkSpace() } catch { onError("Storage full"); return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .speed
            photoAccounts[settings.uniqueID] = accountId
            photos.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Copy data before leaving the callback; disk I/O and camera state run on the capture queue.
        let data = photo.fileDataRepresentation()
        let id = photo.resolvedSettings.uniqueID
        work.async { [self] in
            guard let owner = photoAccounts.removeValue(forKey: id) else { return }
            guard error == nil, let data else { onError("Photo failed"); return }
            do {
                try uploadQueue.enqueue(data, accountId: owner, captureId: UUID().uuidString.lowercased(),
                                        captureKind: "photo", sequence: 0, kind: "photo")
            } catch { onError("Could not save photo"); finishRecording() }
            Task {
                do { try await PhotoLibrary.savePhoto(data) }
                catch { onError(PhotoLibrary.canSave ? "Could not save photo to Photos" : "Photos access off") }
            }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let captureId = recordingId, let accountId else { return }
        let isVideo = output === video
        do {
            if writer == nil {
                guard isVideo else { return }
                writer = try SegmentWriter(startTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), includeAudio: audioEnabled) { [self] data, sequence, kind, duration, startTime in
                    do {
                        try uploadQueue.enqueue(data, accountId: accountId, captureId: captureId, captureKind: "video",
                                                sequence: sequence, kind: kind, duration: duration, startTime: startTime)
                        try uploadQueue.checkSpace()
                    } catch {
                        onError("Storage full"); stopRecording()
                    }
                }
            }
            try writer?.append(sampleBuffer, isVideo: isVideo)
        } catch { onError("Recording interrupted"); finishRecording() }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard accountId == nil else { return }
        if let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first { onCode(code) }
    }
}

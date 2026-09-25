@preconcurrency import AVFoundation
import CoreImage
import Foundation

enum CameraMode: String, CaseIterable, Identifiable, Sendable {
    case front, back, both
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                    AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate,
                    AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let multiSession: AVCaptureMultiCamSession
    let multiBackPreview: AVCaptureVideoPreviewLayer
    let multiFrontPreview: AVCaptureVideoPreviewLayer
    private let work = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let video = AVCaptureVideoDataOutput()
    private let audio = AVCaptureAudioDataOutput()
    private let multiBackVideo = AVCaptureVideoDataOutput()
    private let multiFrontVideo = AVCaptureVideoDataOutput()
    private let multiAudio = AVCaptureAudioDataOutput()
    private let photos = AVCapturePhotoOutput()
    private let codes = AVCaptureMetadataOutput()
    private let uploadQueue: UploadQueue
    private let onError: @Sendable (String) -> Void
    private let onReady: @Sendable () -> Void
    private let onCode: @Sendable (String) -> Void
    private let onRecordingEnded: @Sendable () -> Void
    private let onPhotoCaptured: @Sendable () -> Void
    private var configured = false
    private var multiConfigured = false
    private var audioEnabled = false
    private var multiAudioEnabled = false
    private var mode: CameraMode = .back
    private var singleMode: CameraMode = .back
    private var captureDevice: AVCaptureDevice?
    private var photoDimensions: CMVideoDimensions?
    private var accountId: String?
    private var recordingId: String?
    private var recordingLocation: CaptureLocation?
    private var writer: SegmentWriter?
    private var photoAccounts: [Int64: (String, CaptureLocation?)] = [:]
    private var latestFrontFrame: CMSampleBuffer?
    private var latestCombinedFrame: CVPixelBuffer?
    private var needsRecovery = false
    private let compositor = CameraCompositor()
    private var multiBackDevice: AVCaptureDevice?
    private var observations: [NSObjectProtocol] = []
    init(queue: UploadQueue, onError: @escaping @Sendable (String) -> Void,
         onReady: @escaping @Sendable () -> Void,
         onCode: @escaping @Sendable (String) -> Void,
         onRecordingEnded: @escaping @Sendable () -> Void, onPhotoCaptured: @escaping @Sendable () -> Void) {
        let multi = AVCaptureMultiCamSession()
        multiSession = multi
        multiBackPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multi)
        multiFrontPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multi)
        uploadQueue = queue; self.onError = onError; self.onReady = onReady; self.onCode = onCode; self.onRecordingEnded = onRecordingEnded
        self.onPhotoCaptured = onPhotoCaptured
        super.init()
        multiBackPreview.videoGravity = .resizeAspectFill
        multiFrontPreview.videoGravity = .resizeAspectFill
        for current in [session, multiSession] {
            let observingMulti = current === multiSession
            for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: current, queue: nil) { [weak self] _ in
                    self?.work.async { [weak self] in
                        guard let self, observingMulti == (self.mode == .both) else { return }
                        let activeSession = observingMulti ? self.multiSession : self.session
                        if name == AVCaptureSession.wasInterruptedNotification && !activeSession.isInterrupted { return }
                        self.needsRecovery = true
                        self.finishRecording(interrupted: true)
                        self.onError("Camera interrupted")
                    }
                })
            }
        }
    }
    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    func start(accountId: String?) {
        work.async { [self] in
            self.accountId = accountId
            do {
                if !configured { try configure(); configured = true }
                if accountId == nil && mode != .back {
                    if session.isRunning { session.stopRunning() }
                    if multiSession.isRunning { multiSession.stopRunning() }
                    if singleMode != .back { try switchSingleCamera(to: .back) }
                    mode = .back
                }
                if mode == .both {
                    if !multiConfigured { try configureMulti(); multiConfigured = true }
                    if !multiSession.isRunning { multiSession.startRunning() }
                } else if !session.isRunning { try configureCamera(); session.startRunning() }
            } catch { onError("Camera unavailable") }
        }
    }
    func setMode(_ requested: CameraMode, completion: @escaping @Sendable (Bool) -> Void) {
        work.async { [self] in
            guard recordingId == nil, photoAccounts.isEmpty else { completion(false); return }
            if requested == mode { completion(true); return }
            let previous = mode
            if session.isRunning { session.stopRunning() }
            if multiSession.isRunning { multiSession.stopRunning() }
            do {
                if requested == .both {
                    if !multiConfigured { try configureMulti(); multiConfigured = true }
                    multiSession.startRunning()
                    guard multiSession.isRunning else { throw CocoaError(.fileReadUnknown) }
                } else {
                    if singleMode != requested { try switchSingleCamera(to: requested) }
                    try configureCamera()
                    session.startRunning()
                    guard session.isRunning else { throw CocoaError(.fileReadUnknown) }
                }
                mode = requested
                latestFrontFrame = nil; latestCombinedFrame = nil
                completion(true)
            } catch {
                if previous == .both { multiSession.startRunning() }
                else {
                    if singleMode != previous { try? switchSingleCamera(to: previous) }
                    session.startRunning()
                }
                completion(false)
            }
        }
    }
    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canSetSessionPreset(.hd1280x720) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        session.sessionPreset = .hd1280x720
        guard session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photos) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        video.setSampleBufferDelegate(self, queue: work)
        session.addOutput(video); session.addOutput(photos)
        if let connection = video.connection(with: .video), connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if let connection = photos.connection(with: .video), connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if session.canAddOutput(codes) {
            session.addOutput(codes)
            codes.setMetadataObjectsDelegate(self, queue: work)
            if codes.availableMetadataObjectTypes.contains(.qr) { codes.metadataObjectTypes = [.qr] }
        }
        captureDevice = device
        observations.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                                   object: device, queue: nil) { [weak self] _ in
            self?.focus(at: CGPoint(x: 0.5, y: 0.5))
        })
    }
    private func switchSingleCamera(to target: CameraMode) throws {
        guard target != .both,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: target == .front ? .front : .back) else {
            throw CocoaError(.fileReadUnknown)
        }
        let input = try AVCaptureDeviceInput(device: device)
        let previous = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }
        session.beginConfiguration()
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(input) else {
            if let previous { session.addInput(previous) }
            session.commitConfiguration()
            throw CocoaError(.fileReadUnknown)
        }
        session.addInput(input)
        session.commitConfiguration()
        captureDevice = device; singleMode = target; photoDimensions = nil
        for connection in [video.connection(with: .video), photos.connection(with: .video)] {
            guard let connection else { continue }
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = target == .front
            }
        }
    }
    private func configureMulti() throws {
        guard AVCaptureMultiCamSession.isMultiCamSupported,
              let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CocoaError(.fileReadUnknown)
        }
        try configureMultiFormat(back, maxPixels: 1280 * 720)
        try configureMultiFormat(front, maxPixels: 1280 * 720)
        let backInput = try AVCaptureDeviceInput(device: back)
        let frontInput = try AVCaptureDeviceInput(device: front)
        multiSession.beginConfiguration()
        var configuring = true
        do {
            guard multiSession.canAddInput(backInput) else { throw CocoaError(.fileReadUnknown) }
            multiSession.addInputWithNoConnections(backInput)
            guard multiSession.canAddInput(frontInput) else { throw CocoaError(.fileReadUnknown) }
            multiSession.addInputWithNoConnections(frontInput)
            guard let backPort = backInput.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first,
                  let frontPort = frontInput.ports(for: .video, sourceDeviceType: front.deviceType, sourceDevicePosition: .front).first else {
                throw CocoaError(.fileReadUnknown)
            }
            for (output, port, preview, mirrored) in [
                (multiBackVideo, backPort, multiBackPreview, false),
                (multiFrontVideo, frontPort, multiFrontPreview, true)
            ] {
                guard multiSession.canAddOutput(output) else { throw CocoaError(.fileReadUnknown) }
                multiSession.addOutputWithNoConnections(output)
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: work)
                let dataConnection = AVCaptureConnection(inputPorts: [port], output: output)
                let previewConnection = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
                guard multiSession.canAddConnection(dataConnection), multiSession.canAddConnection(previewConnection) else {
                    throw CocoaError(.fileReadUnknown)
                }
                multiSession.addConnection(dataConnection)
                multiSession.addConnection(previewConnection)
                // Portrait orientation maps to each camera's native sensor angle.
                for connection in [dataConnection, previewConnection] {
                    if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                    if mirrored && connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = true
                    }
                }
            }
            multiSession.commitConfiguration()
            configuring = false
            if multiSession.hardwareCost > 1 || multiSession.systemPressureCost > 1 {
                try configureMultiFormat(back, maxPixels: 640 * 480)
                try configureMultiFormat(front, maxPixels: 640 * 480)
            }
            guard multiSession.hardwareCost <= 1, multiSession.systemPressureCost <= 1 else { throw CocoaError(.fileReadUnknown) }
            multiBackDevice = back
        } catch {
            if configuring { multiSession.commitConfiguration() }
            multiSession.beginConfiguration()
            for connection in multiSession.connections { multiSession.removeConnection(connection) }
            for output in multiSession.outputs { multiSession.removeOutput(output) }
            for input in multiSession.inputs { multiSession.removeInput(input) }
            multiSession.commitConfiguration()
            throw error
        }
    }
    private func configureMultiFormat(_ device: AVCaptureDevice, maxPixels: Int32) throws {
        let formats = device.formats.filter { format in
            format.isMultiCamSupported && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }
        let candidates = formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width * size.height <= maxPixels
        }
        guard let format = candidates.max(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }) ?? formats.min(by: {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return a.width * a.height < b.width * b.height
        }) else { throw CocoaError(.fileReadUnknown) }
        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }
    private func configureCamera() throws {
        guard let device = captureDevice else { throw APIError(status: 0, message: "Camera unavailable") }
        let pixels: (CMVideoDimensions) -> Int64 = { Int64($0.width) * Int64($0.height) }
        let withinTarget = device.activeFormat.supportedMaxPhotoDimensions.filter { pixels($0) <= 12_500_000 }
        guard let dimensions = withinTarget.max(by: { pixels($0) < pixels($1) }) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        photos.maxPhotoDimensions = dimensions
        photos.maxPhotoQualityPrioritization = .balanced
        photoDimensions = dimensions
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else {
            throw APIError(status: 0, message: "Camera unavailable")
        }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.isSubjectAreaChangeMonitoringEnabled = true
        applyAutomaticFocus(device, at: CGPoint(x: 0.5, y: 0.5))
    }
    func focus(at point: CGPoint) {
        work.async { [self] in
            guard (mode == .both ? multiSession.isRunning : session.isRunning),
                  let device = mode == .both ? multiBackDevice : captureDevice else { return }
            do {
                try device.lockForConfiguration()
                applyAutomaticFocus(device, at: point)
                device.unlockForConfiguration()
            } catch { onError("Could not focus") }
        }
    }
    func zoom(by scale: CGFloat) {
        work.async { [self] in
            guard (mode == .both ? multiSession.isRunning : session.isRunning),
                  let device = mode == .both ? multiBackDevice : captureDevice, scale.isFinite, scale > 0 else { return }
            do {
                try device.lockForConfiguration()
                let zoom = device.videoZoomFactor * scale
                device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
                device.unlockForConfiguration()
            } catch { onError("Could not zoom") }
        }
    }
    private func applyAutomaticFocus(_ device: AVCaptureDevice, at point: CGPoint) {
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
    }
    private func enableAudio() {
        if mode == .both { enableMultiAudio(); return }
        guard !audioEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        if session.canAddInput(input), session.canAddOutput(audio) {
            session.addInput(input); session.addOutput(audio)
            audio.setSampleBufferDelegate(self, queue: work); audioEnabled = true
        }
    }
    private func enableMultiAudio() {
        guard !multiAudioEnabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: device) else { return }
        multiSession.beginConfiguration(); defer { multiSession.commitConfiguration() }
        guard multiSession.canAddInput(input) else { return }
        multiSession.addInputWithNoConnections(input)
        let port = input.ports(for: .audio, sourceDeviceType: device.deviceType, sourceDevicePosition: .back).first
            ?? input.ports(for: .audio, sourceDeviceType: device.deviceType, sourceDevicePosition: .front).first
            ?? input.ports(for: .audio, sourceDeviceType: device.deviceType, sourceDevicePosition: .unspecified).first
        guard let port,
              multiSession.canAddOutput(multiAudio) else {
            multiSession.removeInput(input); return
        }
        multiSession.addOutputWithNoConnections(multiAudio)
        let connection = AVCaptureConnection(inputPorts: [port], output: multiAudio)
        guard multiSession.canAddConnection(connection) else {
            multiSession.removeOutput(multiAudio); multiSession.removeInput(input); return
        }
        multiSession.addConnection(connection)
        multiAudio.setSampleBufferDelegate(self, queue: work)
        multiAudioEnabled = true
    }
    func record(location: CaptureLocation?) {
        work.async { [self] in
            guard accountId != nil, recordingId == nil,
                  (mode == .both ? multiSession.isRunning : session.isRunning) else { onRecordingEnded(); return }
            do { try uploadQueue.checkSpace() } catch { onError("Storage full"); onRecordingEnded(); return }
            enableAudio(); recordingId = UUID().uuidString.lowercased(); recordingLocation = location
        }
    }
    func stopRecording(interrupted: Bool = false) { work.async { [self] in finishRecording(interrupted: interrupted) } }
    private func finishRecording(interrupted: Bool = false) {
        guard let captureId = recordingId, let owner = accountId else { return }
        let finishing = writer
        recordingId = nil; recordingLocation = nil; writer = nil
        if let finishing {
            finishing.finish { [self, finishing] success in
                _ = finishing
                // Failure to persist terminal intent leaves an unknown ending;
                // it must not stop ordinary uploads of the committed originals.
                try? uploadQueue.finishCapture(accountId: owner, captureId: captureId,
                    ending: success && !interrupted ? .stopped : .interrupted, expectedObjects: finishing.emittedObjectCount)
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
            finishRecording(interrupted: true)
            if session.isRunning { session.stopRunning() }
            if multiSession.isRunning { multiSession.stopRunning() }
            latestFrontFrame = nil; latestCombinedFrame = nil
        }
    }
    func takePhoto(location: CaptureLocation?) {
        work.async { [self] in
            guard let accountId, (mode == .both ? multiSession.isRunning : session.isRunning) else { return }
            do { try uploadQueue.checkSpace() } catch { onError("Storage full"); return }
            if mode == .both {
                guard let latestCombinedFrame,
                      let data = compositor.jpeg(from: latestCombinedFrame) else { onError("Camera not ready"); return }
                onPhotoCaptured()
                savePhoto(data, owner: accountId, location: location)
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .balanced
            if let photoDimensions { settings.maxPhotoDimensions = photoDimensions }
            photoAccounts[settings.uniqueID] = (accountId, location)
            photos.capturePhoto(with: settings, delegate: self)
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onPhotoCaptured()
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // Copy data before leaving the callback; disk I/O and camera state run on the capture queue.
        let data = photo.fileDataRepresentation()
        let id = photo.resolvedSettings.uniqueID
        work.async { [self] in
            guard let (owner, location) = photoAccounts.removeValue(forKey: id) else { return }
            guard error == nil, let data else { onError("Photo failed"); return }
            savePhoto(data, owner: owner, location: location)
        }
    }
    private func savePhoto(_ data: Data, owner: String, location: CaptureLocation?) {
        do {
            try uploadQueue.enqueue(data, accountId: owner, captureId: UUID().uuidString.lowercased(),
                                    captureKind: "photo", sequence: 0, kind: "photo", location: location)
        } catch { onError("Could not save photo"); finishRecording(interrupted: true) }
        Task {
            do { try await PhotoLibrary.savePhoto(data) }
            catch { onError(PhotoLibrary.canSave ? "Could not save photo to Photos" : "Photos access off") }
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === multiFrontVideo { latestFrontFrame = sampleBuffer; return }
        if output === multiBackVideo {
            guard let front = latestFrontFrame,
                  abs((CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - CMSampleBufferGetPresentationTimeStamp(front)).seconds) < 0.5,
                  let combined = compositor.compose(back: sampleBuffer, front: front) else { return }
            latestCombinedFrame = CMSampleBufferGetImageBuffer(combined)
            recoveredIfNeeded()
            appendForRecording(combined, isVideo: true)
            return
        }
        if output === video { recoveredIfNeeded() }
        appendForRecording(sampleBuffer, isVideo: output === video)
    }
    private func recoveredIfNeeded() {
        guard needsRecovery else { return }
        needsRecovery = false
        onReady()
    }
    private func appendForRecording(_ sampleBuffer: CMSampleBuffer, isVideo: Bool) {
        guard let captureId = recordingId, let accountId else { return }
        do {
            if writer == nil {
                guard isVideo else { return }
                let location = recordingLocation
                writer = try SegmentWriter(startTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                           includeAudio: mode == .both ? multiAudioEnabled : audioEnabled) { [self] data, sequence, kind, duration, startTime in
                    do {
                        try uploadQueue.enqueue(data, accountId: accountId, captureId: captureId, captureKind: "video",
                                                sequence: sequence, kind: kind, duration: duration, startTime: startTime,
                                                location: location)
                        try uploadQueue.checkSpace()
                    } catch {
                        onError("Storage full"); stopRecording(interrupted: true)
                    }
                }
            }
            try writer?.append(sampleBuffer, isVideo: isVideo)
        } catch { onError("Recording interrupted"); finishRecording(interrupted: true) }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard accountId == nil else { return }
        if let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first { onCode(code) }
    }
}

private final class CameraCompositor {
    private let width = 720
    private let height = 1280
    private let context = CIContext()
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var pool: CVPixelBufferPool?

    func compose(back: CMSampleBuffer, front: CMSampleBuffer) -> CMSampleBuffer? {
        guard let backBuffer = CMSampleBufferGetImageBuffer(back),
              let frontBuffer = CMSampleBufferGetImageBuffer(front) else { return nil }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &result) == kCVReturnSuccess,
              let result else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let pip = CGRect(x: 488, y: 666, width: 216, height: 384)
        let background = fill(CIImage(cvPixelBuffer: backBuffer), in: canvas)
        let border = CIImage(color: CIColor.black).cropped(to: pip.insetBy(dx: -5, dy: -5))
        let inset = fill(CIImage(cvPixelBuffer: frontBuffer), in: pip)
        let image = inset.composited(over: border).composited(over: background).cropped(to: canvas)
        context.render(image, to: result, bounds: canvas, colorSpace: colorSpace)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: result,
                                                         formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(back),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: result,
                                                dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                                formatDescription: description, sampleTiming: &timing,
                                                sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    func jpeg(from buffer: CVPixelBuffer) -> Data? {
        context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace)
    }

    private func fill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let source = image.extent
        let scale = max(rect.width / source.width, rect.height / source.height)
        let resized = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return resized.transformed(by: CGAffineTransform(translationX: rect.midX - resized.extent.midX,
                                                        y: rect.midY - resized.extent.midY)).cropped(to: rect)
    }
}

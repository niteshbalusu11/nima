import SwiftUI
import AVFoundation
@preconcurrency import CoreLocation

@MainActor
final class AppModel: ObservableObject {
    @Published var session: Session?
    @Published var recording = false
    @Published private(set) var cameraMode: CameraMode = .back
    @Published private(set) var switchingCamera = false
    @Published var stopping = false
    @Published var preparingCapture = false
    @Published var recordingStarted = Date()
    @Published var message: String?
    @Published var cloudSymbol = "icloud"
    @Published var enrolling = false
    @Published var scanning = false
    @Published var cameraDenied = false
    @Published var queueFailure = false
    @Published var captureBlocked = false
    @Published var photoPulse = 0
    @Published private(set) var locationEnabled = UserDefaults.standard.object(forKey: "locationEnabled") as? Bool ?? true
    @Published var captures: [LocalCapture] = []
    @Published var managingCapture = false
    private(set) var library = CaptureLibrary()
    private(set) var camera: Camera?
    private let location = CaptureLocationProvider()
    private var queue: UploadQueue?
    private var workers: [Task<Void, Never>] = []
    private var statusTask: Task<Void, Never>?
    private var uploadErrors: [String: String] = [:]
    private var active = false
    private var reviewing = false
    private var lastInviteAttempt = Date.distantPast
    var api: API { API(baseURL: API.configuredURL, token: session?.token) }
    init() {
        session = SessionKeychain.load()
        do {
            let queue = try UploadQueue(); self.queue = queue
            camera = Camera(queue: queue, onError: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.session != nil || self.scanning else { return }
                    self.message = message
                }
            }, onCode: { [weak self] code in
                Task { @MainActor in
                    guard let self, self.scanning else { return }
                    await self.enroll(code, scanned: true)
                }
            }, onRecordingEnded: { [weak self] in
                Task { @MainActor in self?.recording = false; self?.stopping = false }
            }, onPhotoCaptured: { [weak self] in
                Task { @MainActor in self?.photoPulse += 1 }
            })
            refreshCaptures()
        } catch { queueFailure = true; message = "Could not open saved media" }
    }
    func activate() async {
        active = true
        if session != nil || scanning { await startCamera() }
        startUploads()
        #if DEBUG && targetEnvironment(simulator)
        if session == nil, let path = ProcessInfo.processInfo.environment["INVITE_FILE"],
           let code = try? String(contentsOfFile: path, encoding: .utf8) {
            await enroll(code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #endif
        if let current = session {
            do {
                let profile: Profile = try await api.request("GET", "me")
                if session?.token == current.token, current.role != profile.role {
                    var updated = current; updated.role = profile.role
                    try SessionKeychain.save(updated); session = updated
                }
            }
            catch let error as APIError where error.status == 401 {
                if session?.token == current.token { invalidateSession() }
            }
            catch { /* Offline enrollment remains usable; pending media stays local. */ }
        }
    }
    func deactivate() {
        active = false
        location.stop()
        camera?.suspend()
        stopUploads()
    }
    func startScanning() async {
        scanning = true; message = nil
        await startCamera()
    }
    func stopScanning() {
        scanning = false
        if session == nil { camera?.suspend(); message = nil }
    }
    private func startCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard active, !managingCapture, !reviewing, session != nil || scanning else { return }
        cameraDenied = !granted
        if granted {
            if session != nil && locationEnabled { location.start() }
            camera?.start(accountId: session?.accountId)
        }
    }
    func selectCameraMode(_ mode: CameraMode) {
        guard active, session != nil, !recording, !stopping, !preparingCapture, !switchingCamera,
              !managingCapture, mode != cameraMode, let camera else { return }
        switchingCamera = true
        camera.setMode(mode) { [weak self] success in
            Task { @MainActor in
                guard let self else { return }
                if success { self.cameraMode = mode }
                else { self.message = mode == .both ? "Both cameras unavailable" : "Camera unavailable" }
                self.switchingCamera = false
            }
        }
    }
    func setLocationEnabled(_ enabled: Bool) {
        guard locationEnabled != enabled else { return }
        locationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "locationEnabled")
        if enabled && active && session != nil && !reviewing && !cameraDenied && !managingCapture {
            location.start()
        } else {
            location.stop()
        }
    }
    func enroll(_ code: String, scanned: Bool = false) async {
        guard session == nil, !enrolling, !managingCapture else { return }
        if scanned, Date().timeIntervalSince(lastInviteAttempt) < 3 { return }
        lastInviteAttempt = Date()
        guard let token = InviteToken.parse(code) else { message = "Invalid invite"; return }
        enrolling = true; defer { enrolling = false }
        do {
            struct Invite: Encodable { let token: String }
            let result: Session = try await api.request("POST", "enroll", body: API.encode(Invite(token: token)))
            try SessionKeychain.save(result); session = result; message = nil
            scanning = false; captureBlocked = false; uploadErrors.removeAll()
            startUploads(); await startCamera()
        } catch let error as APIError { message = error.message }
        catch { message = "Offline" }
    }
    func shutter(video: Bool) async {
        guard !managingCapture, !queueFailure, !captureBlocked, session != nil, !stopping, !preparingCapture, !switchingCamera else { return }
        message = nil
        if recording { stopping = true; camera?.stopRecording(); return }
        preparingCapture = true; defer { preparingCapture = false }
        if !(await PhotoLibrary.requestAccess()) { message = "Photos access off" }
        guard active, session != nil, !captureBlocked else { return }
        if video {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard active else { return }
            recordingStarted = Date(); recording = true; camera?.record(location: locationEnabled ? location.current : nil)
        } else { camera?.takePhoto(location: locationEnabled ? location.current : nil) }
    }
    func takePhoto() { if !managingCapture && !captureBlocked { camera?.takePhoto(location: locationEnabled ? location.current : nil) } }
    func reviewCaptures(_ value: Bool) async {
        reviewing = value
        if value { location.stop(); camera?.suspend() }
        else if active { await startCamera() }
    }
    func logout() async throws {
        guard !managingCapture, !recording, !stopping, !preparingCapture else {
            throw APIError(status: 0, message: "Finish recording first")
        }
        // If Keychain fails, keep the session visible so logout is never falsely reported.
        try SessionKeychain.clear()
        managingCapture = true
        let pending = stopUploads()
        session = nil; captures = []; scanning = false; reviewing = false
        cameraMode = .back
        message = nil; captureBlocked = false; uploadErrors.removeAll()
        location.stop()
        camera?.suspend()
        for task in pending { await task.value }
        library = CaptureLibrary()
        managingCapture = false
    }
    func deleteCapture(_ id: String) async throws {
        guard !managingCapture, !recording, !stopping, !preparingCapture,
              let current = session, let queue,
              captures.contains(where: { $0.id == id }) else {
            throw APIError(status: 0, message: "Try again")
        }
        managingCapture = true
        let pending = stopUploads()
        defer { managingCapture = false; refreshCaptures(); startUploads() }
        for task in pending { await task.value }
        do {
            let _: OK = try await api.request("DELETE", "captures/\(id)")
        } catch let error as APIError where error.status == 401 {
            invalidateSession()
            throw error
        }
        // After the server accepts deletion, no retries may send this capture again.
        try queue.remove(accountId: current.accountId, captureId: id)
        try await library.remove(accountId: current.accountId, captureId: id)
        uploadErrors.removeAll(); captureBlocked = false
        if ["Storage full", "Offline", "Upload paused"].contains(message ?? "") { message = nil }
    }
    private func refreshCaptures() {
        let updated = session.flatMap { queue?.captures(accountId: $0.accountId) } ?? []
        if captures != updated { captures = updated }
    }
    private func invalidateSession() {
        camera?.stopRecording(); session = nil; try? SessionKeychain.clear(); stopUploads()
        location.stop()
        scanning = false; cameraMode = .back; camera?.suspend(); message = "Enter invite"
        captures = []
    }
    @discardableResult
    private func stopUploads() -> [Task<Void, Never>] {
        let pending = workers
        workers.forEach { $0.cancel() }; workers.removeAll()
        statusTask?.cancel(); statusTask = nil
        return pending
    }
    private func startUploads() {
        guard active, !managingCapture, workers.isEmpty, let session, let queue else { return }
        let worker = UploadWorker(api: api, queue: queue, accountId: session.accountId)
        for kind in ["video", "photo"] {
            workers.append(Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    if let item = queue.next(accountId: session.accountId, captureKind: kind) {
                        do {
                            try await worker.send(item)
                            try Task.checkCancellation()
                            failures = 0; self.uploadErrors[kind] = nil
                            self.captureBlocked = self.uploadErrors.values.contains { $0 != "Offline" }
                        } catch is CancellationError { return }
                        catch let error as APIError where error.status == 401 {
                            if !Task.isCancelled && self.session?.token == session.token { self.invalidateSession() }
                            return
                        }
                        catch let error as APIError where error.status == 410 {
                            if Task.isCancelled { return }
                            do {
                                try queue.remove(accountId: session.accountId, captureId: item.captureId)
                                try await self.library.remove(accountId: session.accountId, captureId: item.captureId)
                                self.uploadErrors[kind] = nil
                                self.captureBlocked = self.uploadErrors.values.contains { $0 != "Offline" }
                                self.refreshCaptures()
                            } catch {
                                self.uploadErrors[kind] = "Upload paused"
                                self.captureBlocked = true
                                try? await Task.sleep(for: .seconds(5))
                            }
                        }
                        catch {
                            if Task.isCancelled { return }
                            failures += 1
                            if let apiError = error as? APIError, [400, 409, 413].contains(apiError.status) {
                                self.uploadErrors[kind] = apiError.status == 413 ? "Storage full" : "Upload paused"
                                self.captureBlocked = true; self.camera?.stopRecording()
                            } else { self.uploadErrors[kind] = "Offline" }
                            try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures, 5))))))
                        }
                    } else { try? await Task.sleep(for: .milliseconds(250)) }
                }
            })
        }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pending = queue.pending(accountId: session.accountId)
                self.refreshCaptures()
                if let error = self.uploadErrors.values.sorted().first {
                    self.cloudSymbol = "icloud.slash"
                    if self.message == nil || ["Offline", "Upload paused"].contains(self.message ?? "") {
                        self.message = error
                    }
                } else {
                    self.cloudSymbol = pending == 0 && !self.recording && !self.stopping ? "checkmark.icloud" : "icloud.and.arrow.up"
                    if ["Offline", "Upload paused"].contains(self.message ?? "") { self.message = nil }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

@MainActor
private final class CaptureLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var active = false
    private var latest: CaptureLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
    }

    var current: CaptureLocation? {
        guard active, let latest, abs(Date().timeIntervalSince1970 - Double(latest.timestamp)) <= 30 else { return nil }
        return latest
    }

    func start() {
        active = true
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateAuthorization() }
    }

    func stop() {
        active = false
        latest = nil
        manager.stopUpdatingLocation()
    }

    private func updateAuthorization() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if active { manager.startUpdatingLocation() }
        case .denied, .restricted:
            latest = nil
            manager.stopUpdatingLocation()
        case .notDetermined:
            break
        @unknown default:
            latest = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.updateAuthorization() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0 else { return }
        let location = CaptureLocation(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                                       horizontalAccuracyM: fix.horizontalAccuracy,
                                       timestamp: Int64(fix.timestamp.timeIntervalSince1970))
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.latest = location
        }
    }
}

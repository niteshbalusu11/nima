import SwiftUI
import AVFoundation

@MainActor
final class AppModel: ObservableObject {
    @Published var session: Session?
    @Published var recording = false
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
    private(set) var camera: Camera?
    private var queue: UploadQueue?
    private var workers: [Task<Void, Never>] = []
    private var statusTask: Task<Void, Never>?
    private var uploadErrors: [String: String] = [:]
    private var active = false
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
            })
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
        guard active, session != nil || scanning else { return }
        cameraDenied = !granted
        if granted { camera?.start(accountId: session?.accountId) }
    }
    func enroll(_ code: String, scanned: Bool = false) async {
        guard session == nil, !enrolling else { return }
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
        guard !queueFailure, !captureBlocked, session != nil, !stopping, !preparingCapture else { return }
        message = nil
        if recording { stopping = true; camera?.stopRecording(); return }
        preparingCapture = true; defer { preparingCapture = false }
        if !(await PhotoLibrary.requestAccess()) { message = "Photos access off" }
        guard active, session != nil, !captureBlocked else { return }
        if video {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard active else { return }
            recordingStarted = Date(); recording = true; camera?.record()
        } else { camera?.takePhoto() }
    }
    func takePhoto() { if !captureBlocked { camera?.takePhoto() } }
    private func invalidateSession() {
        camera?.stopRecording(); session = nil; SessionKeychain.clear(); stopUploads()
        scanning = false; camera?.suspend(); message = "Enter invite"
    }
    private func stopUploads() {
        workers.forEach { $0.cancel() }; workers.removeAll()
        statusTask?.cancel(); statusTask = nil
    }
    private func startUploads() {
        guard workers.isEmpty, let session, let queue else { return }
        let worker = UploadWorker(api: api, queue: queue, accountId: session.accountId)
        for kind in ["video", "photo"] {
            workers.append(Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    if let item = queue.next(accountId: session.accountId, captureKind: kind) {
                        do {
                            try await worker.send(item)
                            failures = 0; self.uploadErrors[kind] = nil
                            self.captureBlocked = self.uploadErrors.values.contains { $0 != "Offline" }
                        } catch is CancellationError { return }
                        catch let error as APIError where error.status == 401 {
                            if !Task.isCancelled && self.session?.token == session.token { self.invalidateSession() }
                            return
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

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoMode = true
    @State private var showingProfile = false
    @State private var showingGallery = false
    @State private var shutterClosed = false
    @State private var statusMessage: String?
    @State private var statusMessageForLocation = false
    @State private var statusMessageChangedAt: Date?
    var body: some View {
        Group {
            if model.session == nil { AuthView(model: model) }
            else { cameraContent }
        }
        .preferredColorScheme(.dark)
        .task { await model.activate() }
        .onChange(of: scenePhase) { _, phase in
            // Permission dialogs temporarily make the scene inactive; only backgrounding stops capture.
            if phase == .active { Task { await model.activate() } } else if phase == .background { model.deactivate() }
        }
        .onChange(of: model.session?.token) { _, token in
            if token == nil { showingProfile = false; showingGallery = false }
        }
        .sheet(isPresented: $showingProfile) { ProfileView(model: model) }
        .sheet(isPresented: $showingGallery) { GalleryView(model: model) }
        .onChange(of: showingGallery) { _, value in Task { await model.reviewCaptures(value) } }
        .onChange(of: uploadStatusText) { _, text in showStatusMessage(text) }
        .onChange(of: model.locationEnabled) { _, enabled in showStatusMessage(enabled ? "Location on" : "Location off", forLocation: true) }
    }
    private func showStatusMessage(_ message: String, forLocation: Bool = false) {
        withAnimation(.easeInOut(duration: 0.2)) {
            statusMessage = message
            statusMessageForLocation = forLocation
            statusMessageChangedAt = Date()
        }
    }
    private var cameraContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera = model.camera {
                if model.cameraMode == .both { MultiCameraPreview(camera: camera).ignoresSafeArea() }
                else { CameraPreview(session: camera.session, onFocus: camera.focus, onZoom: camera.zoom).ignoresSafeArea() }
            }
            Color.black.opacity(shutterClosed ? 0.8 : 0).ignoresSafeArea().allowsHitTesting(false)
                .task(id: model.photoPulse) {
                    guard model.photoPulse > 0 else { return }
                    shutterClosed = true
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.18)) { shutterClosed = false }
                }
                .sensoryFeedback(.impact, trigger: model.photoPulse)
            VStack {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        uploadStatus
                        locationToggle
                        Spacer()
                    }
                    Text(statusMessage ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .opacity(statusMessage == nil ? 0 : 1)
                        .padding(.leading, statusMessageForLocation ? 60 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 20)
                        .accessibilityHidden(true)
                        .task(id: statusMessageChangedAt) {
                            guard statusMessageChangedAt != nil else { return }
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { statusMessage = nil; statusMessageChangedAt = nil }
                        }
                    if model.recording {
                        Text(model.recordingStarted, style: .timer).monospacedDigit()
                            .padding(.horizontal, 12).padding(.vertical, 5).background(.red, in: Capsule())
                    }
                }
                .padding(.horizontal, 24).padding(.top, 12)
                Spacer()
                if let message = model.message, !["Offline", "Upload paused"].contains(message) {
                    Text(message).font(.subheadline.weight(.medium)).padding(10).background(.black.opacity(0.65), in: Capsule())
                }
                if model.cameraDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.liquidGlassButton(prominent: true)
                } else {
                    if !model.recording {
                        HStack(spacing: 4) {
                            ForEach(CameraMode.allCases) { mode in
                                Button { model.selectCameraMode(mode) } label: {
                                    Text(mode.title)
                                        .frame(minWidth: 72, minHeight: 44)
                                        .foregroundStyle(model.cameraMode == mode ? .black : .white)
                                        .liquidGlassCapsule(tint: model.cameraMode == mode ? .yellow : nil)
                                        .contentShape(Capsule())
                                }
                                .disabled(model.switchingCamera || (mode == .both && !AVCaptureMultiCamSession.isMultiCamSupported))
                                .accessibilityAddTraits(model.cameraMode == mode ? .isSelected : [])
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .padding(4)
                        .padding(.top, 12)
                        HStack(spacing: 4) {
                            Button { videoMode = false } label: {
                                Text("Photo")
                                    .frame(minWidth: 108, minHeight: 50)
                                    .foregroundStyle(videoMode ? .white : .black)
                                    .liquidGlassCapsule(tint: videoMode ? nil : .yellow)
                                    .contentShape(Capsule())
                            }
                            .accessibilityAddTraits(videoMode ? [] : .isSelected)
                            Button { videoMode = true } label: {
                                Text("Video")
                                    .frame(minWidth: 108, minHeight: 50)
                                    .foregroundStyle(videoMode ? .black : .white)
                                    .liquidGlassCapsule(tint: videoMode ? .yellow : nil)
                                    .contentShape(Capsule())
                            }
                            .accessibilityAddTraits(videoMode ? .isSelected : [])
                        }
                        .font(.headline)
                        .buttonStyle(.plain)
                        .padding(4)
                        .padding(.top, 8)
                    }
                    ZStack {
                        Button { Task { await model.shutter(video: videoMode) } } label: {
                            ZStack {
                                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 80, height: 80)
                                if model.recording {
                                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                                } else {
                                    Circle().fill(videoMode ? .red : .white).frame(width: 66, height: 66)
                                }
                            }
                            .liquidGlassCircle()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.recording ? "Stop recording" : videoMode ? "Record video" : "Take photo")
                        .disabled(model.managingCapture || model.stopping || model.preparingCapture || model.switchingCamera || model.queueFailure || model.captureBlocked)
                        HStack {
                            if model.recording {
                                galleryButton
                                Spacer()
                                Button { model.takePhoto() } label: {
                                    Circle().fill(.white).frame(width: 38, height: 38).padding(12).liquidGlassCircle()
                                }.buttonStyle(.plain).accessibilityLabel("Take photo")
                            } else {
                                galleryButton
                                Spacer()
                                profileButton
                            }
                        }.padding(.horizontal, 24)
                    }.padding(.top, 16).padding(.bottom, 22)
                }
                if model.cameraDenied {
                    HStack {
                        galleryButton
                        Spacer()
                        profileButton
                    }.padding(.horizontal, 24).padding(.bottom, 22)
                }
            }
            .foregroundStyle(.white)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }
    private var uploadStatusText: String {
        if model.cloudSymbol == "checkmark.icloud" { return "All uploaded" }
        if model.cloudSymbol == "icloud.slash" { return model.message == "Offline" ? "Offline" : "Upload paused" }
        return "Uploading"
    }
    private var uploadStatus: some View {
        let uploaded = model.cloudSymbol == "checkmark.icloud"
        let paused = model.cloudSymbol == "icloud.slash"
        let color: Color = uploaded ? .green : paused ? .red : .yellow
        return Image(systemName: uploaded ? "checkmark.icloud.fill" : paused ? "icloud.slash.fill" : "icloud.and.arrow.up.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(color)
        .frame(width: 48, height: 48)
        .liquidGlassCircle(interactive: false)
        .overlay(Circle().strokeBorder(color, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(uploaded ? "All uploads complete" : uploadStatusText)
    }
    private var locationToggle: some View {
        let enabled = model.locationEnabled
        let color: Color = enabled ? .yellow : .gray
        return Button { model.setLocationEnabled(!enabled) } label: {
            Image(systemName: enabled ? "location.fill" : "location.slash.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 48, height: 48)
                .liquidGlassCircle(tint: enabled ? .yellow.opacity(0.25) : nil)
                .overlay(Circle().strokeBorder(color, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Location")
        .accessibilityValue(enabled ? "On" : "Off")
        .accessibilityHint("Include location with new photos and videos")
    }
    private var profileButton: some View {
        Button { showingProfile = true } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .frame(width: 56, height: 56)
                .liquidGlassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile")
    }
    private var galleryButton: some View {
        Button { showingGallery = true } label: {
            CaptureThumbnail(capture: model.captures.first, library: model.library)
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.55), lineWidth: 1))
                .padding(4).liquidGlassRoundedRectangle(cornerRadius: 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photos and videos")
        .disabled(model.managingCapture || model.recording || model.stopping || model.preparingCapture)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocus: ((CGPoint) -> Void)? = nil
    var onZoom: ((CGFloat) -> Void)? = nil
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        view.onZoom = onZoom
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.onFocus = onFocus
        uiView.onZoom = onZoom
    }
    final class PreviewView: UIView {
        var onFocus: ((CGPoint) -> Void)?
        var onZoom: ((CGFloat) -> Void)?
        private let focusRing = UIView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
            focusRing.layer.borderColor = UIColor.yellow.cgColor
            focusRing.layer.borderWidth = 2
            focusRing.layer.cornerRadius = 36
            focusRing.isUserInteractionEnabled = false
            focusRing.alpha = 0
            addSubview(focusRing)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let onFocus else { return }
            let point = gesture.location(in: self)
            onFocus(layerView.captureDevicePointConverted(fromLayerPoint: point))
            focusRing.layer.removeAllAnimations()
            focusRing.center = point
            focusRing.alpha = 1
            UIView.animate(withDuration: 0.25, delay: 0.6, options: .beginFromCurrentState) {
                self.focusRing.alpha = 0
            }
        }
        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            onZoom?(gesture.scale)
            gesture.scale = 1
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = layerView.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
}

struct MultiCameraPreview: UIViewRepresentable {
    let camera: Camera
    func makeUIView(context: Context) -> PreviewView {
        PreviewView(back: camera.multiBackPreview, front: camera.multiFrontPreview,
                    onFocus: camera.focus, onZoom: camera.zoom)
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        private let back: AVCaptureVideoPreviewLayer
        private let front: AVCaptureVideoPreviewLayer
        private let onFocus: (CGPoint) -> Void
        private let onZoom: (CGFloat) -> Void
        init(back: AVCaptureVideoPreviewLayer, front: AVCaptureVideoPreviewLayer,
             onFocus: @escaping (CGPoint) -> Void, onZoom: @escaping (CGFloat) -> Void) {
            self.back = back; self.front = front; self.onFocus = onFocus; self.onZoom = onZoom
            super.init(frame: .zero)
            layer.addSublayer(back)
            layer.addSublayer(front)
            front.cornerRadius = 12
            front.masksToBounds = true
            front.borderColor = UIColor.white.cgColor
            front.borderWidth = 2
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
            addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layoutSubviews() {
            super.layoutSubviews()
            back.frame = bounds
            let width = bounds.width * 0.3
            front.frame = CGRect(x: bounds.maxX - width - 16, y: safeAreaInsets.top + 100,
                                 width: width, height: width * 16 / 9)
        }
        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            guard !front.frame.contains(point) else { return }
            onFocus(back.captureDevicePointConverted(fromLayerPoint: point))
        }
        @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .changed else { return }
            onZoom(gesture.scale)
            gesture.scale = 1
        }
    }
}

private struct ProfileView: View {
    @ObservedObject var model: AppModel
    private var api: API { model.api }
    @Environment(\.dismiss) private var dismiss
    @State private var profile = Profile()
    @State private var message: String?
    @State private var loaded = false
    @State private var saving = false
    @State private var confirmingLogout = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $profile.name).textContentType(.name)
                    TextField("Email", text: $profile.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("Signal username", text: $profile.signalUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if profile.role == .admin {
                        NavigationLink("Invite person") { InviteView(api: api) }
                    }
                }.disabled(!loaded || saving || model.managingCapture)
                #if DEBUG
                Section("Development") {
                    NavigationLink("Nearby transport probe") { NearbyProbeView(model: model) }
                        .disabled(model.recording || model.stopping || model.preparingCapture || model.managingCapture)
                }
                #endif
                Section {
                    Button("Log Out", role: .destructive) { confirmingLogout = true }
                        .liquidGlassButton()
                        .disabled(saving || model.managingCapture || model.recording || model.stopping || model.preparingCapture)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .interactiveDismissDisabled(model.managingCapture)
            .confirmationDialog("Log out?", isPresented: $confirmingLogout, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) {
                    Task {
                        do { try await model.logout() }
                        catch { message = "Could not log out. Try again." }
                    }
                }
            } message: {
                Text("Pending uploads pause. You'll need a new invite to sign in again.")
            }
            .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() }.disabled(model.managingCapture) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!loaded || saving || model.managingCapture)
                }
            }
            .task {
                do { profile = try await api.request("GET", "me"); loaded = true }
                catch { message = "Could not load profile" }
            }
        }
    }
    private func save() async {
        saving = true; defer { saving = false }
        struct Edit: Encodable { let name: String; let email: String; let signalUsername: String }
        do {
            let _: Profile = try await api.request("PATCH", "me", body: API.encode(Edit(name: profile.name, email: profile.email, signalUsername: profile.signalUsername)))
            dismiss()
        } catch { message = "Could not save" }
    }
}

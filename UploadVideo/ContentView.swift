import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoMode = true
    @State private var showingProfile = false
    @State private var showingGallery = false
    @State private var shutterClosed = false
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
    }
    private var cameraContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera = model.camera { CameraPreview(session: camera.session, onFocus: camera.focus, onZoom: camera.zoom).ignoresSafeArea() }
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
                HStack {
                    if model.session != nil {
                        Image(systemName: model.cloudSymbol)
                            .accessibilityLabel(model.cloudSymbol == "checkmark.icloud" ? "Uploads saved" : "Uploads pending")
                    }
                    Spacer()
                    if model.recording {
                        Text(model.recordingStarted, style: .timer).monospacedDigit()
                            .padding(.horizontal, 12).padding(.vertical, 5).background(.red, in: Capsule())
                        Spacer()
                    }
                    if model.session != nil && !model.recording {
                        Button { showingProfile = true } label: { Image(systemName: "person.crop.circle") }
                            .accessibilityLabel("Profile")
                    }
                }
                .font(.title2).padding(.horizontal, 24).padding(.top, 12)
                Spacer()
                if let message = model.message {
                    Text(message).font(.subheadline.weight(.medium)).padding(10).background(.black.opacity(0.65), in: Capsule())
                }
                if model.cameraDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.borderedProminent)
                } else {
                    if !model.recording {
                        HStack(spacing: 4) {
                            Button { videoMode = false } label: {
                                Text("Photo")
                                    .frame(minWidth: 108, minHeight: 50)
                                    .foregroundStyle(videoMode ? .white : .black)
                                    .background(videoMode ? .clear : .yellow, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .accessibilityAddTraits(videoMode ? [] : .isSelected)
                            Button { videoMode = true } label: {
                                Text("Video")
                                    .frame(minWidth: 108, minHeight: 50)
                                    .foregroundStyle(videoMode ? .black : .white)
                                    .background(videoMode ? .yellow : .clear, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .accessibilityAddTraits(videoMode ? .isSelected : [])
                        }
                        .font(.headline)
                        .buttonStyle(.plain)
                        .padding(4)
                        .background(.black.opacity(0.8), in: Capsule())
                        .padding(.top, 12)
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
                        }
                        .accessibilityLabel(model.recording ? "Stop recording" : videoMode ? "Record video" : "Take photo")
                        .disabled(model.managingCapture || model.stopping || model.preparingCapture || model.queueFailure || model.captureBlocked)
                        HStack {
                            galleryButton
                            Spacer()
                            if model.recording {
                                Button { model.takePhoto() } label: {
                                    Circle().fill(.white).frame(width: 38, height: 38).padding(12)
                                }.accessibilityLabel("Take photo")
                            }
                        }.padding(.horizontal, 24)
                    }.padding(.top, 16).padding(.bottom, 22)
                }
                if model.cameraDenied { galleryButton.padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 24) }
            }
            .foregroundStyle(.white)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }
    private var galleryButton: some View {
        Button { showingGallery = true } label: {
            CaptureThumbnail(capture: model.captures.first, library: model.library)
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.55), lineWidth: 1))
        }
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
                Section {
                    Button("Log Out", role: .destructive) { confirmingLogout = true }
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

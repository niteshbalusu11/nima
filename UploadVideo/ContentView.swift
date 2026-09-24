import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var videoMode = true
    @State private var showingProfile = false
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
        .onChange(of: model.session?.token) { _, token in if token == nil { showingProfile = false } }
        .sheet(isPresented: $showingProfile) { ProfileView(api: model.api) }
    }
    private var cameraContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera = model.camera { CameraPreview(session: camera.session).ignoresSafeArea() }
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
                        HStack(spacing: 30) {
                            Button("Photo") { videoMode = false }.foregroundStyle(videoMode ? .white : .yellow)
                            Button("Video") { videoMode = true }.foregroundStyle(videoMode ? .yellow : .white)
                        }.font(.subheadline.weight(.semibold)).padding(.top, 12)
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
                        .disabled(model.stopping || model.preparingCapture || model.queueFailure || model.captureBlocked)
                        if model.recording {
                            HStack {
                                Button { model.takePhoto() } label: {
                                    Circle().fill(.white).frame(width: 38, height: 38).padding(12)
                                }.accessibilityLabel("Take photo")
                                Spacer()
                            }.padding(.leading, 24)
                        }
                    }.padding(.top, 16).padding(.bottom, 22)
                }
            }
            .foregroundStyle(.white)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.layerView.session = session
        view.layerView.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = layerView.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
}

private struct ProfileView: View {
    let api: API
    @Environment(\.dismiss) private var dismiss
    @State private var profile = Profile()
    @State private var message: String?
    @State private var loaded = false
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $profile.name).textContentType(.name)
                TextField("Email", text: $profile.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Signal username", text: $profile.signalUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
                if profile.role == .admin {
                    NavigationLink("Invite person") { InviteView(api: api) }
                }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .disabled(!loaded || saving)
            .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!loaded || saving)
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

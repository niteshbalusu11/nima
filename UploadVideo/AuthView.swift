import SwiftUI

struct AuthView: View {
    @ObservedObject var model: AppModel
    @State private var token = ""
    @State private var showingScanner = false
    @FocusState private var editing: Bool
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "camera").font(.system(size: 44, weight: .light))
            Text("Enter invite").font(.title2.weight(.semibold))
            HStack {
                TextField("Invite token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.asciiCapable).submitLabel(.go).focused($editing)
                    .onSubmit { join() }
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { token = value; model.message = nil }
                }.labelStyle(.iconOnly).tint(.gray).accessibilityLabel("Paste invite")
            }
            .padding(14).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .disabled(model.enrolling)
            Button(action: join) {
                if model.enrolling { ProgressView().frame(maxWidth: .infinity) }
                else { Text("Continue").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).tint(.white).foregroundStyle(.black)
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.enrolling)
            Button { editing = false; showingScanner = true } label: {
                Label("Scan QR", systemImage: "qrcode.viewfinder")
            }.disabled(model.enrolling)
            if let message = model.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, 32).frame(maxWidth: 440).frame(maxWidth: .infinity)
        .background(.black).foregroundStyle(.white)
        .sheet(isPresented: $showingScanner, onDismiss: { model.stopScanning() }) {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let camera = model.camera { CameraPreview(session: camera.session).ignoresSafeArea() }
                    VStack(spacing: 24) {
                        if model.cameraDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }.buttonStyle(.borderedProminent)
                        } else {
                            Image(systemName: "viewfinder").font(.system(size: 180, weight: .ultraLight))
                        }
                        if model.enrolling { ProgressView().tint(.white) }
                        if let message = model.message { Text(message).padding(10).background(.black.opacity(0.7), in: Capsule()) }
                    }.foregroundStyle(.white)
                }
                .navigationTitle("Scan invite").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { showingScanner = false } } }
                .task { await model.startScanning() }
            }
        }
    }
    private func join() {
        guard !model.enrolling else { return }
        editing = false
        Task { await model.enroll(token) }
    }
}

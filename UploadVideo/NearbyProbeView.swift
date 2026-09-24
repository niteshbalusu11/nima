#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

struct NearbyProbeView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var probe = NearbyProbe()
    @State private var importing = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("Test identity") {
                Button("Import fixture") { importing = true }
                if let name = probe.identityLabel { Text(name) }
            }
            Section("Synthetic transfer") {
                Button("Listen") { perform { try probe.listen() } }
                Button("Find receiver and send") { perform { try probe.browse() } }
                Button("Stop") { probe.stop() }
            }.disabled(probe.identityLabel == nil)
            Section {
                Text(probe.status)
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Debug probe: 256 KiB of generated data with pinned mutual TLS. It does not record, save, or upload media.")
            }
        }
        .navigationTitle("Nearby probe")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            perform {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                try probe.load(file.read(upToCount: 64 * 1024 + 1) ?? Data())
            }
        }
        .task { await model.reviewCaptures(true) }
        .onDisappear { probe.stop(); Task { await model.reviewCaptures(false) } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { probe.stop() } }
    }
    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
#endif

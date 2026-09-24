#if DEBUG
import SwiftUI

struct DeviceSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var setupTask: Task<Void, Never>?
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Button(model.session?.deviceId == nil ? "Register this device" : "Verify registration") {
                    busy = true
                    setupTask = Task {
                        defer { busy = false; setupTask = nil }
                        do { try await model.registerSharingDevice(); message = "Device registered" }
                        catch is CancellationError { }
                        catch { message = error.localizedDescription }
                    }
                }.disabled(busy || model.session == nil)
                if busy { ProgressView() }
                if let message { Text(message) }
            } footer: {
                Text("Registers this phone's signing and transport keys. Nearby sharing and recipient approval are not enabled yet.")
            }
        }
        .navigationTitle("Sharing identity")
        .onDisappear { setupTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { setupTask?.cancel() } }
    }
}
#endif

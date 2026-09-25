#if DEBUG
import SwiftUI

struct NearbySettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var setupTask: Task<Void, Never>?
    @State private var message: String?
    @State private var store: PeerStore?
    @State private var snapshot: PeerStore.Snapshot?
    @State private var code = ""
    @State private var contactCode: String?
    @State private var invitationCode: String?
    @State private var invitationName = ""
    @State private var invitationExpiry: Date?
    @State private var preview: PeerInvitationPreview?
    @State private var previewCode = ""
    @State private var visible = false
    var body: some View {
        Form {
            if let contactCode, let store {
                Section("This phone") {
                    ShareLink(item: contactCode) { Label("Share my contact", systemImage: "person.crop.circle.badge.plus") }
                }
                Section("Add a person") {
                    TextField("Contact or invitation code", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Continue") {
                        run {
                            invitationCode = nil
                            let submitted = code
                            if PeerCode.isInvitation(submitted) {
                                let result = try await store.previewInvitation(submitted)
                                previewCode = submitted; preview = result
                            } else {
                                let result = try await store.createInvitation(for: submitted)
                                invitationCode = try PeerCode.invitation(server: store.baseURL, token: result.token)
                                invitationName = name(result.recipientName)
                                invitationExpiry = Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
                            }
                        }
                    }.disabled(busy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let invitationCode, let invitationExpiry {
                        Text("Invitation for \(invitationName)").font(.subheadline)
                        ShareLink(item: invitationCode) { Label("Send invitation", systemImage: "square.and.arrow.up") }
                        Text("Expires \(invitationExpiry, format: .dateTime.month().day().hour().minute())")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                approvedSection("Can receive from me", outgoing: true, store: store)
                approvedSection("Can send to me", outgoing: false, store: store)
                Section {
                    Button("Refresh approvals") { run { try await store.refresh() } }.disabled(busy)
                    if let snapshot, snapshot.pendingRevocations > 0 {
                        Text("Removed here. Waiting to sync.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Button("Set up nearby") {
                        run { try await model.registerSharingDevice(); try await loadStore() }
                    }.disabled(busy || model.session == nil)
                }
            }
            Section {
                if busy { ProgressView().accessibilityLabel("Updating nearby setup") }
                if let message { Text(message) }
            } footer: {
                Text("Development setup. Media sharing is not enabled yet.")
            }
        }
        .navigationTitle("Nearby setup")
        .task {
            visible = true
            if model.session?.deviceId != nil { run { try await loadStore() } }
        }
        .confirmationDialog("Allow \(name(preview?.senderName ?? "")) to share with you?", isPresented: Binding(
            get: { preview != nil }, set: { if !$0 { preview = nil } }), titleVisibility: .visible) {
                Button("Allow sharing") {
                    guard let store else { return }
                    let invitation = previewCode
                    preview = nil
                    run { try await store.acceptInvitation(invitation); code = "" }
                }
        } message: {
            Text("Allow their photos and videos to be saved on this phone and backed up to their account using your connection.")
        }
        .onDisappear { visible = false; setupTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { setupTask?.cancel() } }
        .onChange(of: model.session?.token) { _, _ in
            setupTask?.cancel(); store = nil; snapshot = nil; contactCode = nil; invitationCode = nil; preview = nil
        }
    }
    private func approvedSection(_ title: String, outgoing: Bool, store: PeerStore) -> some View {
        let approvals = snapshot?.approvals.filter { ($0.sender.id == store.device.id) == outgoing } ?? []
        return Section(title) {
            if approvals.isEmpty { Text("No one yet").foregroundStyle(.secondary) }
            ForEach(approvals) { approval in
                HStack {
                    NavigationLink(name(outgoing ? approval.recipientName : approval.senderName)) {
                        ApprovedProbeView(model: model, store: store, approval: approval)
                    }.lineLimit(1)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        // Local revocation must remain available during an in-flight refresh.
                        Task {
                            do { try await store.revoke(approval.id) }
                            catch { message = "Could not save removal. Sharing is disabled here." }
                            guard model.session?.token == store.sessionToken else { return }
                            snapshot = await store.snapshot()
                            if !busy { run { try await store.refresh() } }
                        }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
    private func loadStore() async throws {
        let next = try model.peerStore()
        store = next
        contactCode = try PeerCode.contact(server: next.baseURL, device: next.device)
        snapshot = await next.snapshot()
        try await next.refresh()
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard visible, scenePhase == .active, !busy else { return }
        busy = true; message = nil
        setupTask = Task {
            defer { busy = false; setupTask = nil }
            do { try await action() }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled, let store { snapshot = await store.snapshot() }
        }
    }
    private func name(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Unnamed member" : text
    }
}

private struct ApprovedProbeView: View {
    @ObservedObject var model: AppModel
    let store: PeerStore
    let approval: PeerApproval
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var probe = NearbyProbe()
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text(probe.identityLabel == nil ? "Ready" : probe.status)
                Button(approval.sender == store.device ? "Send test bytes" : "Receive test bytes") {
                    do {
                        guard let session = model.session, session.token == store.sessionToken else { return }
                        let identity = try DeviceIdentity.loadOrCreate(for: session, at: store.baseURL)
                        try probe.load(registeredIdentity: identity.tlsIdentity(), approval: approval, store: store)
                        if approval.sender == store.device { try probe.browse() }
                        else { try probe.listen() }
                        message = nil
                    } catch { message = error.localizedDescription }
                }.disabled(scenePhase != .active)
                Button("Stop") { probe.stop() }
                if let message { Text(message) }
            } footer: {
                Text("Transfers 256 KiB of generated bytes to test this approval. No photos or video.")
            }
        }
        .navigationTitle("Connection test")
        .onDisappear { probe.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { probe.stop() } }
        .onChange(of: model.session?.token) { _, _ in probe.stop() }
    }
}
#endif

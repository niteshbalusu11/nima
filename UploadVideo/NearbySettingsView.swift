import SwiftUI

struct NearbySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var snapshot: PeerStore.Snapshot?
    @State private var message: String?
    var body: some View {
        List {
            if let snapshot, let device = model.nearby?.peers.device {
                ForEach(snapshot.approvals) { approval in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(name(approval.sender == device ? approval.recipientName : approval.senderName))
                            Text(approval.sender == device ? "Can receive from you" : "Can share with you").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task {
                                do { try await model.nearby?.peers.revoke(approval.id) }
                                catch { message = error.localizedDescription }
                            }
                        }.buttonStyle(.borderless)
                    }
                }
                if snapshot.approvals.isEmpty { Text("No paired people yet").foregroundStyle(.secondary) }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("People")
        .task {
            guard let store = model.nearby?.peers else { return }
            for await value in await store.updates() {
                guard !Task.isCancelled else { return }
                snapshot = value
            }
        }
    }
    private func name(_ value: String) -> String { value.isEmpty ? "Nima member" : value }
}

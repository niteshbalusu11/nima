import Foundation
@preconcurrency import Network

// Localhost fixture for the production pairing and media protocol; no discovery.
@MainActor
final class LoopbackMediaReceiver {
    private var listener: NWListener?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var channels: [UUID: NearbyChannel] = [:]
    private var authenticated: UUID?
    private var approvalTask: Task<Void, Never>?
    private var generation = UUID()
    func start(identity: DeviceIdentity, approval: PeerApproval, store: ReceivedMediaStore,
               listening: @escaping @MainActor (UInt16) -> Void = { _ in },
               status: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard approval.recipient == store.peers.device else { throw MediaRecords.failure("Approval cannot receive") }
        let run = generation
        let parameters = try NearbyChannel.pairingParameters(identity: identity.tlsIdentity())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.generation == run else { return }
                switch state {
                case .ready: status("Waiting for sender"); if let port = listener?.port { listening(port.rawValue) }
                case .failed: status("Nearby receive unavailable"); self.stop()
                case .waiting: status("Check Local Network access")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == run, self.channels.count < 2, self.authenticated == nil else { connection.cancel(); return }
                let id = UUID(), channel = NearbyChannel(connection)
                self.channels[id] = channel
                self.tasks[id] = Task { [weak self] in
                    defer {
                        channel.close()
                        if let self, self.generation == run {
                            self.channels[id] = nil; self.tasks[id] = nil
                            if self.authenticated == id { self.authenticated = nil }
                        }
                    }
                    do {
                        try await channel.start()
                        guard let self, self.generation == run, self.authenticated == nil else { channel.close(); return }
                        let paired = try await NearbyPairing.receive(channel: channel, store: store.peers, identity: identity) { _ in false }
                        guard paired.samePermission(as: approval) else { throw MediaRecords.failure("Unexpected media peer") }
                        self.authenticated = id; status("Receiving")
                        try await NearbyTransfer.receive(channel: channel, store: store, approval: approval)
                    } catch {
                        if !Task.isCancelled, self?.generation == run, self?.authenticated == id {
                            status((error as? APIError)?.status == 413 ? "Storage full" : "Waiting to reconnect")
                        }
                    }
                }
            }
        }
        approvalTask = Task { [weak self] in
            for await snapshot in await store.peers.updates() {
                guard !Task.isCancelled else { return }
                if !snapshot.approvals.contains(where: { $0.samePermission(as: approval) }) { self?.stop(); status("Permission removed"); return }
            }
        }
        listener.start(queue: .main)
    }
    @discardableResult
    func stop() -> [Task<Void, Never>] {
        generation = UUID(); listener?.cancel(); listener = nil
        approvalTask?.cancel(); approvalTask = nil
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }; tasks.removeAll()
        channels.values.forEach { $0.close() }; channels.removeAll(); authenticated = nil
        return pending
    }
}

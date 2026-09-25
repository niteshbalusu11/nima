#if !os(iOS)
import Foundation
import Security
@preconcurrency import Network

// One transport per approved recipient: independent sockets, flow control and
// retry loops prevent a slow phone from blocking the other two recipients.
@MainActor
final class NearbySender {
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var task: Task<Void, Never>?
    private var channel: NearbyChannel?
    private var approvalTask: Task<Void, Never>?
    func start(identity: SecIdentity, approval: PeerApproval, store: PeerStore,
               source: @escaping @MainActor () -> [NearbyTransfer.Delivery],
               status: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard approval.sender == store.device else { throw MediaRecords.failure("Approval cannot send") }
        let parameters = try NearbyChannel.parameters(identity: identity, approval: approval, store: store)
        let browser = NWBrowser(for: .bonjour(type: NearbyChannel.service, domain: nil), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.endpoints = results.map(\.endpoint).sorted { String(describing: $0) < String(describing: $1) } }
        }
        browser.stateUpdateHandler = { state in
            Task { @MainActor in
                if case .failed = state { status("Nearby discovery unavailable") }
                if case .waiting = state { status("Check Local Network access") }
            }
        }
        browser.start(queue: .main)
        approvalTask = Task { [weak self] in
            for await snapshot in await store.updates() {
                guard !Task.isCancelled else { return }
                if !snapshot.approvals.contains(where: { $0.samePermission(as: approval) }) { self?.stop(); status("Permission removed"); return }
            }
        }
        task = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.endpoints.isEmpty {
                    let endpoint = self.endpoints[attempt % self.endpoints.count]; attempt += 1
                    do {
                        let parameters = try NearbyChannel.parameters(identity: identity, approval: approval, store: store)
                        let channel = NearbyChannel(NWConnection(to: endpoint, using: parameters)); self.channel = channel
                        status("Connecting")
                        try await channel.start()
                        try Task.checkCancellation()
                        try await NearbyTransfer.send(channel: channel, approval: approval, source: source) { saved, total in
                            status(total == 0 ? "Ready for new captures" : "Saved \(saved) of \(total) fragments")
                        }
                    } catch {
                        if !Task.isCancelled { status((error as? APIError)?.status == 413 ? "Receiver storage full" : "Waiting to reconnect") }
                    }
                    self.channel?.close(); self.channel = nil
                } else { status("Looking for receiver") }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    @discardableResult
    func stop() -> [Task<Void, Never>] {
        let pending = task.map { [$0] } ?? []
        browser?.cancel(); browser = nil; endpoints = []
        task?.cancel(); task = nil; approvalTask?.cancel(); approvalTask = nil
        channel?.close(); channel = nil
        return pending
    }
}

@MainActor
final class NearbyReceiver {
    private var listener: NWListener?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var channels: [UUID: NearbyChannel] = [:]
    private var authenticated: UUID?
    private var approvalTask: Task<Void, Never>?
    private var generation = UUID()
    func start(identity: SecIdentity, approval: PeerApproval, store: ReceivedMediaStore,
               localOnly: Bool = false, listening: @escaping @MainActor (UInt16) -> Void = { _ in },
               status: @escaping @MainActor (String) -> Void) throws {
        stop()
        guard approval.recipient == store.peers.device else { throw MediaRecords.failure("Approval cannot receive") }
        let run = generation
        let parameters = try NearbyChannel.parameters(identity: identity, approval: approval, store: store.peers)
        if localOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        if !localOnly { listener.service = NWListener.Service(name: UUID().uuidString, type: NearbyChannel.service) }
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

#endif

#if os(iOS)
import Foundation
import WiFiAware
@preconcurrency import Network

// Owns the Wi-Fi Aware listener and a single selected incoming sender. The byte
// channel and media protocol remain identical to the exercised loopback path.
@available(iOS 26.0, *)
@MainActor
final class WiFiAwareRadio {
    static let service = "_nima-media._tcp"
    static var supported: Bool { WACapabilities.supportedFeatures.contains(.wifiAware) }
    static var publisher: WAPublisherListener { .wifiAware(.connecting(to: WAPublishableService.allServices[service]!, from: .allPairedDevices)) }
    static var subscriber: WASubscriberBrowser { .wifiAware(.connecting(to: .allPairedDevices, from: WASubscribableService.allServices[service]!)) }
    private var listener: NWListener?
    private var pairing: Task<Void, Never>?
    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    private var receiving: Task<Void, Never>?
    private var receivingChannel: NearbyChannel?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var channels: [UUID: NearbyChannel] = [:]
    private var permissions: [UUID: String] = [:]
    private var generation = UUID()
    private var receiveGeneration = UUID()

    func share(peers: PeerStore, identity: DeviceIdentity, source: @escaping @MainActor () -> [NearbyTransfer.Delivery],
               failed: @escaping @MainActor (String) -> Void,
               accepted: @escaping @MainActor (PeerApproval) throws -> Void,
               status: @escaping @MainActor (String?, String) -> Void) throws {
        guard Self.supported else { throw PeerStore.failure("Nearby is unavailable on this iPhone") }
        guard listener == nil else { return }
        let parameters = try NearbyChannel.pairingParameters(identity: identity.tlsIdentity())
        parameters.serviceClass = .interactiveVideo; parameters.wifiAware = .realtime
        let provider = Self.publisher
        provider.configureParameters(parameters)
        let listener = try NWListener(using: parameters)
        listener.service = provider.service
        self.listener = listener
        let run = generation
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.generation == run, self.listener === listener else { return }
                switch state {
                case .ready: status(nil, "Ready for nearby people")
                case .failed(let error):
                    self.listener = nil; listener.cancel()
                    failed(error.wifiAware?.localizedDescription ?? "Nearby could not start. Try again.")
                case .waiting: status(nil, "Turn on Wi-Fi to share nearby")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == run, self.channels.count < 3 else { connection.cancel(); return }
                let id = UUID(), channel = NearbyChannel(connection)
                self.channels[id] = channel
                self.tasks[id] = Task { [weak self] in
                    defer { channel.close(); self?.channels[id] = nil; self?.tasks[id] = nil; self?.permissions[id] = nil }
                    do {
                        try await channel.start()
                        guard try await connection.currentPath?.wifiAware != nil else { throw PeerStore.failure("A Wi-Fi Aware connection is required") }
                        let approval = try await NearbyPairing.send(channel: channel, store: peers, identity: identity)
                        guard let self, self.generation == run, !self.permissions.values.contains(approval.id) else { throw CancellationError() }
                        try accepted(approval)
                        self.permissions[id] = approval.id
                        try await NearbyTransfer.send(channel: channel, approval: approval, source: { source().filter { $0.prepared.grants[approval.id] != nil } }) { saved, total in
                            status(approval.id, total == 0 ? "Ready for new captures" : "Saved \(saved) of \(total) fragments")
                        }
                    } catch {
                        if !Task.isCancelled, self?.generation == run {
                            if let approval = self?.permissions[id] { status(approval, "Waiting to reconnect") }
                            else { status(nil, (error as? LocalizedError)?.errorDescription ?? "Could not connect this phone") }
                        }
                    }
                }
            }
        }
        // Publishing to allPairedDevices fails with WAError.noPairedDevices on
        // a fresh installation. Pairing UI must be able to run before this starts.
        status(nil, "Pair a nearby phone")
        pairing = Task { [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    try Task.checkCancellation()
                    guard self?.generation == run else { return }
                    guard !devices.isEmpty else { continue }
                    listener.start(queue: .main)
                    return
                }
            } catch {
                guard !Task.isCancelled, self?.generation == run else { return }
                self?.listener = nil; listener.cancel()
                failed(error.localizedDescription)
            }
        }
    }

    func join(endpoint: NWEndpoint, peers: PeerStore, identity: DeviceIdentity, store: ReceivedMediaStore,
              consent: @escaping @MainActor (PeerApproval) async -> Bool,
              accepted: @escaping @MainActor (PeerApproval) -> Void,
              status: @escaping @MainActor (String) -> Void) throws {
        stopReceiving()
        endpoints = [endpoint]
        let run = receiveGeneration
        var paired: WAPairedDevice?
        receiving = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.receiveGeneration == run else { return }
                if let endpoint = self.endpoints.first {
                    let parameters = try? NearbyChannel.pairingParameters(identity: identity.tlsIdentity())
                    guard let parameters else { status("Could not open nearby identity"); return }
                    parameters.serviceClass = .interactiveVideo; parameters.wifiAware = .realtime
                    let connection = NWConnection(to: endpoint, using: Self.subscriber.configureParameters(parameters))
                    let channel = NearbyChannel(connection); self.receivingChannel = channel
                    do {
                        status("Connecting")
                        try await channel.start()
                        guard let path = try await connection.currentPath?.wifiAware,
                              paired == nil || paired?.id == path.endpoint.device.id else { throw PeerStore.failure("The paired phone changed") }
                        try Task.checkCancellation()
                        if paired == nil {
                            paired = path.endpoint.device
                            self.browse(for: path.endpoint.device)
                        }
                        let approval = try await NearbyPairing.receive(channel: channel, store: peers, identity: identity, consent: consent)
                        try Task.checkCancellation(); accepted(approval); status("Receiving")
                        try await NearbyTransfer.receive(channel: channel, store: store, approval: approval)
                    } catch {
                        if !Task.isCancelled { status((error as? LocalizedError)?.errorDescription ?? "Waiting to reconnect") }
                    }
                    channel.close(); if self.receivingChannel === channel { self.receivingChannel = nil }
                } else { status("Waiting for sender") }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private func browse(for paired: WAPairedDevice) {
        let provider: WASubscriberBrowser = .wifiAware(.connecting(to: .selected([paired]), from: WASubscribableService.allServices[Self.service]!))
        let browser = NWBrowser(for: provider.makeDescriptor(), using: provider.configureParameters(.tcp))
        self.browser = browser
        let run = receiveGeneration
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard self?.receiveGeneration == run else { return }
                self?.endpoints = results.filter { (try? provider.makeEndpoint(from: $0))?.device.id == paired.id }.map(\.endpoint)
            }
        }
        browser.start(queue: .main)
    }
    func disconnect(_ approval: String) {
        for (id, value) in permissions where value == approval { channels[id]?.close(); tasks[id]?.cancel() }
    }
    func retainPermissions(_ approvals: Set<String>) {
        for (id, value) in permissions where !approvals.contains(value) { channels[id]?.close(); tasks[id]?.cancel() }
    }
    func stopSharing() -> [Task<Void, Never>] {
        generation = UUID(); listener?.cancel(); listener = nil
        let pending = Array(tasks.values) + (pairing.map { [$0] } ?? [])
        pairing = nil; pending.forEach { $0.cancel() }
        channels.values.forEach { $0.close() }; tasks.removeAll(); channels.removeAll(); permissions.removeAll()
        return pending
    }
    @discardableResult func stopReceiving() -> [Task<Void, Never>] {
        receiveGeneration = UUID()
        browser?.cancel(); browser = nil; endpoints = []
        let pending = receiving.map { [$0] } ?? []; receiving?.cancel(); receiving = nil
        receivingChannel?.close(); receivingChannel = nil
        return pending
    }
    func stop() -> [Task<Void, Never>] { stopSharing() + stopReceiving() }
}
#endif

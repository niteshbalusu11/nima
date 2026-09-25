import Foundation
import Combine
@preconcurrency import Network
#if os(iOS)
import WiFiAware
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class NearbySharing: ObservableObject {
    @Published private(set) var approvals: [PeerApproval] = []
    @Published private(set) var selected: Set<String> = []
    @Published private(set) var receiving: String?
    @Published private(set) var receiveStatus = "Stopped"
    @Published private(set) var senderStatus: [String: String] = [:]
    @Published private(set) var received: [ReceivedMediaStore.CaptureInfo] = []
    @Published private(set) var relayStatus: [String: String] = [:]
    @Published var message: String?
    let store: ReceivedMediaStore
    let peers: PeerStore
    private let api: API
    private let queue: UploadQueue
    private let source: OwnerMediaRecords
    private let slots: UploadSlots
    private let selectionKey: String
    private var since: [String: Date]
    private var active = false
    @Published private(set) var sharing = false
    @Published private(set) var sharingStatus = ""
    @Published private(set) var sharingError: String?
    @Published private(set) var consent: PeerApproval?
    private let signingIdentity: DeviceIdentity
    private var radio: AnyObject?
    private var excluded = Set<String>()
    private var sharingStarted = Date()
    private var consentRequest = UUID()
    private var consentReply: CheckedContinuation<Bool, Never>?
    private var consentDeadline: Task<Void, Never>?
    #if os(iOS)
    @available(iOS 26.0, *) private var aware: WiFiAwareRadio {
        if let radio = radio as? WiFiAwareRadio { return radio }
        let next = WiFiAwareRadio(); radio = next; return next
    }
    #endif
    private var deliveries: [NearbyTransfer.Delivery] = []
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var cloudDescriptors: Set<Data> = []
    private var cloudEndings: Set<Data> = []

    init(api: API, queue: UploadQueue, peers: PeerStore, identity: DeviceIdentity,
         budget: MediaStorageBudget, slots: UploadSlots) throws {
        self.api = api; self.queue = queue; self.peers = peers; self.slots = slots
        self.signingIdentity = identity
        source = try OwnerMediaRecords(identity: identity, peers: peers, budget: budget)
        store = try ReceivedMediaStore(peers: peers, budget: budget)
        selectionKey = "nearby.selection." + api.baseURL.absoluteString + "." + peers.device.accountId + "." + peers.device.id
        since = UserDefaults.standard.data(forKey: selectionKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        selected = Set(since.keys)
    }
    func select(_ approval: PeerApproval, enabled: Bool, start: Date) throws {
        guard approvals.contains(approval), approval.sender == peers.device else { throw MediaRecords.failure("Recipient is not approved") }
        if enabled {
            guard selected.count < 3 || selected.contains(approval.id) else { throw MediaRecords.failure("Choose up to three recipients") }
            if since[approval.id] == nil { since[approval.id] = start }
        } else {
            since[approval.id] = nil; excluded.insert(approval.id); senderStatus[approval.id] = nil
            #if os(iOS)
            if #available(iOS 26.0, *) { aware.disconnect(approval.id) }
            #endif
        }
        UserDefaults.standard.set(try JSONEncoder().encode(since), forKey: selectionKey)
        selected = Set(since.keys)
        synchronizeSenders()
    }
    func receive(from approval: PeerApproval?) throws {
        resolveConsent(false)
        #if os(iOS)
        if #available(iOS 26.0, *) { aware.stopReceiving() }
        #endif
        receiving = nil; receiveStatus = "Stopped"; idleTimer()
    }
    func startSharing(start: Date = Date()) throws {
        guard active else { throw PeerStore.failure("Open the app to share nearby") }
        #if os(iOS)
        if #available(iOS 26.0, *), WiFiAwareRadio.supported {
            if !sharing { excluded = [] }
            sharingStarted = start; sharing = true; sharingError = nil
            do {
                try aware.share(peers: peers, identity: signingIdentity, source: { [weak self] in self?.deliveries ?? [] }, failed: { [weak self] in self?.sharingError = $0 }, accepted: { [weak self] approval in
                    guard let self, self.sharing, !self.excluded.contains(approval.id) else { throw CancellationError() }
                    if !self.approvals.contains(where: { $0.samePermission(as: approval) }) { self.approvals.append(approval) }
                    if !self.selected.contains(approval.id) { try self.select(approval, enabled: true, start: self.sharingStarted) }
                }, status: { [weak self] id, text in
                    if let id { self?.senderStatus[id] = text } else { self?.sharingStatus = text }
                })
            } catch { sharing = false; throw error }
            idleTimer(); return
        }
        #endif
        throw PeerStore.failure("Nearby needs iOS 26 and a supported iPhone")
    }
    func stopSharing() {
        #if os(iOS)
        if #available(iOS 26.0, *) { _ = aware.stopSharing() }
        #endif
        sharing = false; sharingError = nil; selected = []; since = [:]; senderStatus = [:]
        UserDefaults.standard.removeObject(forKey: selectionKey); idleTimer()
    }
    #if os(iOS)
    @available(iOS 26.0, *)
    func join(_ endpoint: NWEndpoint) throws {
        guard active else { throw CancellationError() }
        try receive(from: nil)
        receiving = "joining"; receiveStatus = "Connecting"; idleTimer()
        do {
            try aware.join(endpoint: endpoint, peers: peers, identity: signingIdentity, store: store,
                consent: { [weak self] approval in await self?.requestConsent(approval) ?? false },
                accepted: { [weak self] approval in self?.receiving = approval.id },
                status: { [weak self] text in self?.receiveStatus = text })
        } catch { receiving = nil; idleTimer(); throw error }
    }
    #endif
    private func requestConsent(_ approval: PeerApproval) async -> Bool {
        guard consentReply == nil, receiving != nil, !Task.isCancelled else { return false }
        consent = approval
        let request = UUID(); consentRequest = request
        return await withTaskCancellationHandler {
            await withCheckedContinuation { reply in
                consentReply = reply
                consentDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    self?.resolveConsent(false)
                }
            }
        } onCancel: { Task { @MainActor in if self.consentRequest == request { self.resolveConsent(false) } } }
    }
    func resolveConsent(_ allowed: Bool) {
        consentDeadline?.cancel(); consentDeadline = nil; consent = nil
        let reply = consentReply; consentReply = nil; reply?.resume(returning: allowed)
        if !allowed, reply != nil {
            #if os(iOS)
            if #available(iOS 26.0, *) { aware.stopReceiving() }
            #endif
            receiving = nil; receiveStatus = "Stopped"; idleTimer()
        }
    }
    func activate() {
        guard !active else { return }
        active = true
        let run = generation
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await snapshot in await peers.updates() {
                guard !Task.isCancelled, generation == run else { return }
                approvals = snapshot.approvals
                let valid = Set(approvals.filter { $0.sender == peers.device }.map(\.id))
                if !selected.isSubset(of: valid) {
                    since = since.filter { valid.contains($0.key) }; selected = Set(since.keys)
                    if let data = try? JSONEncoder().encode(since) { UserDefaults.standard.set(data, forKey: selectionKey) }
                }
                synchronizeSenders()
                #if os(iOS)
                if #available(iOS 26.0, *) { aware.retainPermissions(Set(approvals.map(\.id))) }
                #endif
                if let receiving, receiving != "joining", !approvals.contains(where: { $0.id == receiving }) { try? receive(from: nil) }
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await peers.refresh() } catch { /* Cached consent remains usable offline. */ }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var next: [NearbyTransfer.Delivery] = []
                for capture in queue.captures(accountId: peers.device.accountId) {
                    let recipients = Set(since.filter { capture.createdAt >= $0.value }.map(\.key))
                    if recipients.isEmpty { continue }
                    do {
                        if let prepared = try await source.prepare(captureId: capture.id, queue: queue, approvalIDs: recipients) {
                            let signed = try MediaRecords.Capture(prepared.descriptor, recorder: peers.device)
                            next.append(.init(prepared: prepared, capture: signed))
                        }
                    } catch { if !Task.isCancelled { message = error.localizedDescription } }
                    if Task.isCancelled || generation != run { return }
                }
                deliveries = next
                do { received = try await store.captures() }
                catch { if !Task.isCancelled { message = "Could not open received copies" } }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let worker: RelayUploadWorker
            do { worker = try RelayUploadWorker(api: api, store: store, slots: slots) } catch { message = error.localizedDescription; return }
            var retry: [String: Date] = [:]
            while !Task.isCancelled {
                for capture in received where (retry[capture.id] ?? .distantPast) <= Date() {
                    do {
                        let more = try await worker.sendNext(captureHash: capture.hash)
                        guard !Task.isCancelled, generation == run else { return }
                        relayStatus[capture.id] = nil
                        retry[capture.id] = more ? .distantPast : Date().addingTimeInterval(15)
                    } catch {
                        guard !Task.isCancelled, generation == run else { return }
                        let status = (error as? APIError)?.status
                        relayStatus[capture.id] = (error as? APIError)?.code == "relay_disabled" ? "Saved here · cloud backup unavailable" :
                            (status == 410 ? "Removed from recorder’s cloud" :
                            ([401, 403].contains(status ?? 0) ? "Saved here · permission needed" :
                            (status == 413 ? "Saved here · cloud storage full" : "Saved here · waiting for cloud")))
                        retry[capture.id] = Date().addingTimeInterval(30)
                    }
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                for delivery in deliveries {
                    do { try await publishOwner(delivery) } catch { /* Normal owner uploads continue independently. */ }
                    if Task.isCancelled || generation != run { return }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        })
        synchronizeSenders(); idleTimer()
    }
    private func publishOwner(_ delivery: NearbyTransfer.Delivery) async throws {
        let hash = delivery.capture.digest
        guard !cloudDescriptors.contains(hash) || (delivery.prepared.completion != nil && !cloudEndings.contains(hash)) else { return }
        let id = delivery.capture.descriptor.captureId
        guard let original = queue.retainedObjects(accountId: peers.device.accountId, captureId: id).first else { return }
        let api = api
        try await slots.run(owner: true) {
            struct Capture: Encodable { let kind: String; let location: CaptureLocation?; let descriptor: MediaRecords.Envelope }
            let _: OK = try await api.request("PUT", "captures/\(id)", body: API.encode(Capture(kind: original.captureKind, location: original.location, descriptor: delivery.prepared.descriptor)))
            if let completion = delivery.prepared.completion {
                let _: OK = try await api.request("POST", "captures/\(id)/completion", body: API.encode(["completion": completion]))
            }
        }
        try Task.checkCancellation()
        cloudDescriptors.insert(hash)
        if delivery.prepared.completion != nil { cloudEndings.insert(hash) }
    }
    private func synchronizeSenders() {
        guard active, !sharing, !selected.isEmpty else { return }
        do { try startSharing() } catch { message = error.localizedDescription }
    }
    @discardableResult
    func suspend() -> [Task<Void, Never>] {
        active = false; generation = UUID()
        var connections: [Task<Void, Never>] = []
        #if os(iOS)
        if #available(iOS 26.0, *), let radio = radio as? WiFiAwareRadio { connections = radio.stop() }
        #endif
        resolveConsent(false); sharing = false; sharingError = nil
        let pending = tasks + connections; tasks.removeAll()
        pending.forEach { $0.cancel() }
        // Receive is an explicit foreground mode; reopening returns to the camera.
        receiving = nil; receiveStatus = "Stopped"; deliveries = []
        idleTimer()
        return pending
    }
    func remove(_ capture: ReceivedMediaStore.CaptureInfo) async throws {
        let restart = active
        let pending = suspend()
        for task in pending { await task.value }
        defer { if restart { activate() } }
        try await store.remove(captureHash: capture.hash)
        received = try await store.captures()
        relayStatus[capture.id] = nil
    }
    func forgetOwnedCapture(_ id: String) async throws { try await source.remove(captureId: id) }
    private func idleTimer() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = active && (receiving != nil || sharing)
        #endif
    }
}

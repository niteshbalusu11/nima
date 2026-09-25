import Foundation
import Combine
import Security
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
    private let identity: SecIdentity
    private let slots: UploadSlots
    private let selectionKey: String
    private var since: [String: Date]
    private var active = false
    private var senders: [String: NearbySender] = [:]
    private let receiver = NearbyReceiver()
    private var deliveries: [NearbyTransfer.Delivery] = []
    private var tasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var cloudDescriptors: Set<Data> = []
    private var cloudEndings: Set<Data> = []

    init(api: API, queue: UploadQueue, peers: PeerStore, identity: DeviceIdentity,
         budget: MediaStorageBudget, slots: UploadSlots) throws {
        self.api = api; self.queue = queue; self.peers = peers; self.slots = slots
        self.identity = try identity.tlsIdentity()
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
        } else { since[approval.id] = nil; senders.removeValue(forKey: approval.id)?.stop(); senderStatus[approval.id] = nil }
        UserDefaults.standard.set(try JSONEncoder().encode(since), forKey: selectionKey)
        selected = Set(since.keys)
        synchronizeSenders()
    }
    func receive(from approval: PeerApproval?) throws {
        receiver.stop(); receiving = nil; receiveStatus = "Stopped"
        if let approval {
            guard active, approvals.contains(approval), approval.recipient == peers.device else { throw MediaRecords.failure("Sender is not approved") }
            try receiver.start(identity: identity, approval: approval, store: store) { [weak self] text in self?.receiveStatus = text }
            receiving = approval.id
        }
        idleTimer()
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
                if let receiving, !approvals.contains(where: { $0.id == receiving }) { try? receive(from: nil) }
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
        for id in senders.keys where !selected.contains(id) || !active { senders.removeValue(forKey: id)?.stop() }
        guard active else { return }
        for approval in approvals where selected.contains(approval.id) && senders[approval.id] == nil {
            let sender = NearbySender()
            do {
                try sender.start(identity: identity, approval: approval, store: peers, source: { [weak self] in
                    self?.deliveries.filter { $0.prepared.grants[approval.id] != nil } ?? []
                }, status: { [weak self] text in self?.senderStatus[approval.id] = text })
                senders[approval.id] = sender
            } catch { senderStatus[approval.id] = "Nearby unavailable" }
        }
    }
    @discardableResult
    func suspend() -> [Task<Void, Never>] {
        active = false; generation = UUID()
        let sending = senders.values.flatMap { $0.stop() }; senders.removeAll()
        let pending = tasks + sending + receiver.stop(); tasks.removeAll()
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
        UIApplication.shared.isIdleTimerDisabled = active && receiving != nil
        #endif
    }
}

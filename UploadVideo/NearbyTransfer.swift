import Foundation
import Security
@preconcurrency import Network

@MainActor
enum NearbyTransfer {
    static func receive(channel: NearbyChannel, store: ReceivedMediaStore, approval: PeerApproval) async throws {
        var slots: [Int: UUID] = [:]
        do {
            while !Task.isCancelled {
                let (kind, data) = try await channel.read()
                if kind == 2 {
                    guard let slot = data.first, let id = slots[Int(slot)], data.count > 1 else { throw MediaRecords.failure("Unexpected media chunk") }
                    try await store.append(Data(data.dropFirst()), to: id)
                    continue
                }
                let control = try JSONDecoder().decode(NearbyControl.self, from: data)
                do {
                    switch control.type {
                    case "ping": try await channel.send(NearbyControl(type: "pong"))
                    case "offer":
                        guard let descriptor = control.descriptor, let grant = control.grant, let cursor = control.cursor,
                              (-1...MediaRecords.maxSequence).contains(cursor) else { throw MediaRecords.failure("Invalid inventory request") }
                        let hash = try await store.authorize(descriptor: descriptor, grant: grant, sender: approval.sender)
                        let receipts = try await store.inventory(captureHash: hash).filter { $0.sequence > cursor }.prefix(32)
                        try await channel.send(NearbyControl(type: "inventory", receipts: Array(receipts)))
                    case "begin":
                        guard let slot = control.slot, (0...1).contains(slot), slots[slot] == nil,
                              let descriptor = control.descriptor, let grant = control.grant, let manifest = control.manifest else {
                            throw MediaRecords.failure("Invalid media offer")
                        }
                        switch try await store.begin(descriptor: descriptor, grant: grant, manifest: manifest, sender: approval.sender) {
                        case .saved(let receipt): try await channel.send(NearbyControl(type: "saved", slot: slot, receipt: receipt))
                        case .writing(let id):
                            slots[slot] = id
                            try await channel.send(NearbyControl(type: "ready", slot: slot))
                        }
                    case "end":
                        guard let slot = control.slot, let id = slots.removeValue(forKey: slot) else { throw MediaRecords.failure("No incoming object") }
                        let receipt = try await store.commit(id)
                        try await channel.send(NearbyControl(type: "saved", slot: slot, receipt: receipt))
                    case "completion":
                        guard let descriptor = control.descriptor, let grant = control.grant, let completion = control.completion else {
                            throw MediaRecords.failure("Invalid recording ending")
                        }
                        try await store.receiveCompletion(completion, descriptor: descriptor, grant: grant, sender: approval.sender)
                        try await channel.send(NearbyControl(type: "ok"))
                    default: throw MediaRecords.failure("Unsupported nearby control")
                    }
                } catch {
                    try await channel.send(NearbyControl(type: "error", message: String(error.localizedDescription.prefix(160)), status: (error as? APIError)?.status))
                    if control.type == "offer", (error as? APIError)?.status == 410 { continue }
                    // A malformed or rejected object cannot poison another slot's storage.
                    // Close and resume from the durable inventory on the next connection.
                    throw error
                }
            }
        } catch {
            for id in slots.values { await store.abort(id) }
            throw error
        }
        for id in slots.values { await store.abort(id) }
    }

    struct Delivery: Sendable { let prepared: OwnerMediaRecords.Prepared; let capture: MediaRecords.Capture }
    private struct Window {
        let delivery: Delivery
        let manifest: MediaRecords.Manifest
        let file: FileHandle
        var sent = 0
    }
    static func send(channel: NearbyChannel, approval: PeerApproval,
                     source: @escaping @MainActor () -> [Delivery],
                     progress: @escaping @MainActor (Int, Int) -> Void) async throws {
        var saved: [Data: Set<Int>] = [:]
        var offered: [Data: MediaRecords.Envelope] = [:]
        var ended: Set<Data> = []
        var removed: Set<Data> = []
        var windows: [Int: Window] = [:]
        var turn = 0
        defer { for window in windows.values { try? window.file.close() } }
        while !Task.isCancelled {
            let deliveries = source()
            // Init is always sent first. Video and photo each own one slot; even
            // a maximum-size JPEG yields after every 64 KiB to live video.
            for slot in 0...1 where windows[slot] == nil {
                let choices = deliveries.filter { ($0.capture.descriptor.kind == .photo) == (slot == 1) }
                for delivery in choices {
                    let hash = delivery.capture.digest, prepared = delivery.prepared
                    if removed.contains(hash) { continue }
                    guard let grant = prepared.grants[approval.id] else { continue }
                    if offered[hash] != grant {
                        var cursor = -1, inventory: Set<Int> = []
                        do { repeat {
                            let result = try await channel.request(NearbyControl(type: "offer", descriptor: prepared.descriptor, grant: grant, cursor: cursor))
                            guard result.type == "inventory", let receipts = result.receipts, receipts.count <= 32 else { throw MediaRecords.failure("Invalid saved inventory") }
                            for receipt in receipts {
                                guard receipt.sequence > cursor, receipt.sequence < prepared.objects.count else { throw MediaRecords.failure("Invalid saved sequence") }
                                let manifest = try delivery.capture.manifest(prepared.objects[receipt.sequence].manifest)
                                try validate(receipt, manifest: manifest, capture: delivery.capture)
                                inventory.insert(receipt.sequence); cursor = receipt.sequence
                            }
                            if receipts.count < 32 { break }
                        } while true } catch let error as APIError where error.status == 410 {
                            removed.insert(hash); continue
                        }
                        saved[hash] = inventory; offered[hash] = grant
                    }
                    // Terminal evidence travels as soon as available, including to
                    // recipients holding complementary, incomplete fragment sets.
                    if let completion = prepared.completion, !ended.contains(hash) {
                        let response = try await channel.request(NearbyControl(type: "completion", descriptor: prepared.descriptor, grant: grant, completion: completion))
                        guard response.type == "ok" else { throw MediaRecords.failure("Recording ending was not accepted") }
                        ended.insert(hash)
                    }
                    let inventory = saved[hash] ?? []
                    let missing = prepared.objects.indices.filter { !inventory.contains($0) }
                    if let sequence = missing.first {
                        // Every fifth selection services the oldest hole. Recent
                        // fragments otherwise lead so a late join has current bytes.
                        let selected = sequence == 0 || turn % 5 == 0 ? sequence : missing.last!
                        turn += 1
                        let object = prepared.objects[selected], manifest = try delivery.capture.manifest(object.manifest)
                        let result = try await channel.request(NearbyControl(type: "begin", descriptor: prepared.descriptor, grant: grant, manifest: object.manifest, slot: slot))
                        if result.type == "saved", let receipt = result.receipt {
                            try validate(receipt, manifest: manifest, capture: delivery.capture)
                            saved[hash, default: []].insert(selected)
                        } else {
                            guard result.type == "ready", result.slot == slot else { throw MediaRecords.failure("Receiver did not accept media") }
                            windows[slot] = Window(delivery: delivery, manifest: manifest, file: try FileHandle(forReadingFrom: object.file))
                        }
                        break
                    }
                }
            }
            for slot in windows.keys.sorted() {
                guard var window = windows[slot] else { continue }
                try Task.checkCancellation()
                let data = try window.file.read(upToCount: min(65_536, window.manifest.size - window.sent)) ?? Data()
                guard !data.isEmpty else { throw MediaRecords.failure("Saved fragment is missing") }
                try await channel.chunk(data, slot: slot); window.sent += data.count
                windows[slot] = window
                if window.sent == window.manifest.size {
                    let response = try await channel.request(NearbyControl(type: "end", slot: slot))
                    guard response.type == "saved", response.slot == slot, let receipt = response.receipt else { throw MediaRecords.failure("Missing durable receipt") }
                    try validate(receipt, manifest: window.manifest, capture: window.delivery.capture)
                    saved[window.delivery.capture.digest, default: []].insert(window.manifest.sequence)
                    try window.file.close(); windows[slot] = nil
                }
            }
            progress(saved.values.reduce(0) { $0 + $1.count }, deliveries.reduce(0) { $0 + $1.prepared.objects.count })
            if windows.isEmpty {
                let response = try await channel.request(NearbyControl(type: "ping"))
                guard response.type == "pong" else { throw MediaRecords.failure("Unexpected nearby response") }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private static func validate(_ receipt: ReceivedMediaStore.Receipt, manifest: MediaRecords.Manifest, capture: MediaRecords.Capture) throws {
        guard receipt.recorderAccountId == capture.descriptor.recorderAccountId, receipt.captureId == capture.descriptor.captureId,
              receipt.sequence == manifest.sequence, receipt.size == manifest.size, receipt.sha256 == manifest.sha256 else {
            throw MediaRecords.failure("Receiver receipt does not match original")
        }
    }
}

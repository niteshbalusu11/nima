import Foundation
import CryptoKit
@preconcurrency import AVFoundation
@preconcurrency import Network

@main @MainActor
struct NearbyMediaCheck {
    struct Config: Decodable { let baseUrl: URL; var sessions: [Session]; let root: URL }
    static func expect(_ value: Bool, _ reason: String) throws { if !value { throw MediaRecords.failure(reason) } }
    static func until(_ reason: String, timeout: TimeInterval = 20, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MediaRecords.failure("Timed out: " + reason)
    }
    @MainActor private final class PairState {
        var port: UInt16 = 0
        var sent: PeerApproval?
        var failure: Error?
        var senderTask: Task<Void, Never>?
    }
    static func pair(_ sender: PeerStore, _ recipient: PeerStore, _ a: DeviceIdentity, _ b: DeviceIdentity, expectConsent: Bool, allow: Bool = true) async throws {
        let parameters = try NearbyChannel.pairingParameters(identity: a.tlsIdentity())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let state = PairState()
        listener.stateUpdateHandler = { listenerState in
            Task { @MainActor in if case .ready = listenerState { state.port = listener.port?.rawValue ?? 0 } }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                state.senderTask = Task {
                    let channel = NearbyChannel(connection)
                    defer { channel.close() }
                    do { try await channel.start(); state.sent = try await NearbyPairing.send(channel: channel, store: sender, identity: a) }
                    catch { state.failure = error }
                }
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel(); state.senderTask?.cancel() }
        try await until("pairing listener") { state.port > 0 }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: state.port)!, using: try NearbyChannel.pairingParameters(identity: b.tlsIdentity()))
        let channel = NearbyChannel(connection); defer { channel.close() }
        try await channel.start()
        var consentCount = 0
        let received = try await NearbyPairing.receive(channel: channel, store: recipient, identity: b) { _ in consentCount += 1; return allow }
        try await until("both phones saved permission") { if let failure = state.failure { throw failure }; return state.sent != nil }
        try expect(state.sent == received, "Directional permission differs")
        try expect(consentCount == (expectConsent ? 1 : 0), "Consent was repeated or skipped")
    }
    static func credentialChecks(_ credentials: NearbyCredentials, identity: DeviceIdentity, recipient: RegisteredDevice) throws {
        func reject(_ action: () throws -> Void) throws {
            do { try action() } catch { return }
            throw MediaRecords.failure("Invalid nearby credential or proof accepted")
        }
        _ = try credentials.certificate.verify(authority: credentials.authority)
        let other = Curve25519.Signing.PrivateKey()
        try reject { _ = try credentials.certificate.verify(authority: DeviceIdentity.encodeURL(other.publicKey.rawRepresentation)) }
        let claims = try credentials.certificate.verify(authority: credentials.authority)
        try reject { _ = try credentials.certificate.verify(authority: credentials.authority, now: claims.expiresAt) }
        try reject { _ = try credentials.certificate.verify(authority: credentials.authority, now: claims.issuedAt - 301) }
        let altered = NearbyCertificate(payload: credentials.certificate.payload, signature: DeviceIdentity.encodeURL(Data(repeating: 0, count: 64)))
        try reject { _ = try altered.verify(authority: credentials.authority) }
        let a = DeviceIdentity.encodeURL(Data(repeating: 1, count: 32)), b = DeviceIdentity.encodeURL(Data(repeating: 2, count: 32))
        let proof = try NearbyPairing.proof(sender: claims.device, recipient: recipient, senderNonce: a, recipientNonce: b, authority: credentials.authority)
        let signature = DeviceIdentity.encodeURL(try identity.signNearby(proof))
        let replay = try NearbyPairing.proof(sender: claims.device, recipient: recipient, senderNonce: b, recipientNonce: a, authority: credentials.authority)
        try reject { try NearbyPermission.verify(signature, key: claims.device.signingPublicKey, data: replay) }
        print("PASS: wrong authority, expired/future credentials, signature tampering and TLS identity substitution rejected")
    }
    static func main() async throws {
        var config = try API.decoder.decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try storageChecks(root: config.root.appendingPathComponent("budget"))
        try await slotChecks()
        var identities: [DeviceIdentity] = [], peers: [PeerStore] = [], budgets: [MediaStorageBudget] = []
        var stores: [ReceivedMediaStore] = []
        for index in 0..<4 {
            let identity = DeviceIdentity.ephemeralForCheck(), api = API(baseURL: config.baseUrl, token: config.sessions[index].token)
            let device = try await identity.register(using: api, session: config.sessions[index])
            config.sessions[index].deviceId = device.id
            let peer = try PeerStore(api: api, session: config.sessions[index], device: device, root: config.root.appendingPathComponent("peers"))
            let root = config.root.appendingPathComponent("phone-\(index)"), budget = try MediaStorageBudget(root: root)
            identities.append(identity); peers.append(peer); budgets.append(budget)
            stores.append(try ReceivedMediaStore(peers: peer, root: root.appendingPathComponent("ReceivedMedia"), budget: budget))
            try await peer.refresh()
        }
        do {
            try await pair(peers[0], peers[1], identities[2], identities[1], expectConsent: true)
            throw MediaRecords.failure("Credential forwarded by a different TLS phone was accepted")
        } catch let error as APIError {
            try expect(error.message == "Nearby credential does not match the connected phone", "TLS credential rejection failed for another reason")
        }
        try credentialChecks(try await peers[0].pairingCredentials(), identity: identities[0], recipient: peers[1].device)
        do {
            try await pair(peers[0], peers[1], identities[0], identities[1], expectConsent: true, allow: false)
            throw MediaRecords.failure("Declined sharing was accepted")
        } catch is CancellationError { }
        try expect(await peers[0].snapshot().approvals.isEmpty, "Sender saved declined consent")
        try expect(await peers[1].snapshot().approvals.isEmpty, "Recipient saved declined consent")
        for index in 1...3 { try await pair(peers[0], peers[index], identities[0], identities[index], expectConsent: true) }
        // No HTTP approval call was needed for the native handshake. The server
        // must still have zero approvals until a participant reconnects to sync.
        struct Approvals: Decodable, Sendable { let approvals: [PeerApproval] }
        let unsynced: Approvals = try await API(baseURL: config.baseUrl, token: config.sessions[0].token).request("GET", "peer-approvals")
        try expect(unsynced.approvals.isEmpty, "Offline handshake secretly required server approval")
        try await pair(peers[0], peers[1], identities[0], identities[1], expectConsent: false)
        let reopenedPeers = try PeerStore(api: API(baseURL: config.baseUrl, token: config.sessions[1].token), session: config.sessions[1], device: peers[1].device, root: config.root.appendingPathComponent("peers"))
        try expect(await reopenedPeers.snapshot().approvals.count == 1, "Offline permission was not durable")
        try await reopenedPeers.refresh()
        print("PASS: certified mutual TLS pairing without online approval, fresh consent once, reconnect, durable permission and deferred server sync")
        try await peers[0].refresh()
        for peer in peers.dropFirst() { try await peer.refresh() }
        let approvals = await peers[0].snapshot().approvals
        func approval(_ index: Int) -> PeerApproval { approvals.first { $0.recipient == peers[index].device }! }
        let apiA = API(baseURL: config.baseUrl, token: config.sessions[0].token)
        let queue = try UploadQueue(root: config.root.appendingPathComponent("phone-0/PendingMedia"), budget: budgets[0])
        let source = try OwnerMediaRecords(identity: identities[0], peers: peers[0], root: config.root.appendingPathComponent("phone-0/SharedMediaRecords"), budget: budgets[0])
        let importedId = UUID().uuidString.lowercased()
        try queue.enqueue(MediaProbe.jpeg(), accountId: peers[0].device.accountId, captureId: importedId, captureKind: "photo", sequence: 0, kind: "photo", imported: true)
        let reopenedQueue = try UploadQueue(root: config.root.appendingPathComponent("phone-0/PendingMedia"), budget: budgets[0])
        let imported = try await source.prepare(captureId: importedId, queue: reopenedQueue, approvalIDs: Set(approvals.map(\.id)))
        try expect(imported == nil, "Library import was broadcast without nearby consent")
        let receiverB = LoopbackMediaReceiver(), receiverC = LoopbackMediaReceiver(), receiverD = LoopbackMediaReceiver()
        let receivers = [receiverB, receiverC, receiverD]
        var ports = [UInt16](repeating: 0, count: 3)
        for index in 1...3 {
            try receivers[index - 1].start(identity: identities[index], approval: approval(index), store: stores[index],
                listening: { ports[index - 1] = $0 }, status: { _ in })
        }
        defer { receivers.forEach { $0.stop() } }
        try await until("receivers listening") { ports.allSatisfy { $0 > 0 } }
        let tlsA = try identities[0].tlsIdentity()
        var deliveries: [NearbyTransfer.Delivery] = []
        var channels: [NearbyChannel] = []
        var sendTasks: [Task<Void, Error>] = []
        func connect(_ index: Int) async throws {
            let parameters = try NearbyChannel.pairingParameters(identity: tlsA)
            let channel = NearbyChannel(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ports[index - 1])!, using: parameters))
            try await channel.start(); channels.append(channel)
            let paired = try await NearbyPairing.send(channel: channel, store: peers[0], identity: identities[0])
            try expect(paired.samePermission(as: approval(index)), "Reconnection changed permission")
            sendTasks.append(Task { try await NearbyTransfer.send(channel: channel, approval: approval(index), source: { deliveries }, progress: { _, _ in }) })
        }
        try await connect(1); try await connect(2); try await connect(3)
        defer { sendTasks.forEach { $0.cancel() }; channels.forEach { $0.close() } }
        let videoId = UUID().uuidString.lowercased(), photoId = UUID().uuidString.lowercased()
        let errors = RecordingErrors()
        let recorderAccount = peers[0].device.accountId
        let writer = try SegmentWriter(startTime: CMTime(value: 100, timescale: 1), includeAudio: true) { data, sequence, kind, duration, start in
            do { try queue.enqueue(data, accountId: recorderAccount, captureId: videoId, captureKind: "video", sequence: sequence, kind: kind, duration: duration, startTime: start) }
            catch { errors.record(error) }
        }
        let prepare = Task {
            while !Task.isCancelled {
                var next: [NearbyTransfer.Delivery] = []
                for id in [videoId, photoId] {
                    if let prepared = try await source.prepare(captureId: id, queue: queue, approvalIDs: Set(approvals.map(\.id))) {
                        next.append(.init(prepared: prepared, capture: try MediaRecords.Capture(prepared.descriptor, recorder: peers[0].device)))
                    }
                }
                deliveries = next
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { prepare.cancel() }
        let slots = UploadSlots(), owner = UploadWorker(api: apiA, queue: queue, accountId: peers[0].device.accountId)
        let uploadA = Task {
            while !Task.isCancelled {
                if let item = queue.next(accountId: peers[0].device.accountId, captureKind: "video") {
                    try await slots.run(owner: true) { try await owner.send(item) }
                } else { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        defer { uploadA.cancel() }
        let playback = LivePlayback()
        var player: AVPlayer?
        defer { player?.pause(); playback.stop() }
        var liveSaved = false, livePlayed = false
        for frame in 0..<360 {
            try writer.append(MediaProbe.videoSample(frame), isVideo: true)
            try writer.append(MediaProbe.audioSample(frame), isVideo: false)
            if frame == 60 {
                var jpeg = try MediaProbe.jpeg(); jpeg.append(Data(repeating: 0, count: 2 * 1024 * 1024))
                try queue.enqueue(jpeg, accountId: peers[0].device.accountId, captureId: photoId, captureKind: "photo", sequence: 0, kind: "photo")
            }
            if frame == 100 {
                uploadA.cancel(); _ = await uploadA.result
                try expect(queue.captures(accountId: peers[0].device.accountId).contains { $0.id == videoId }, "Owner recording missing")
                // Disconnect one recipient while the other two continue recording.
                sendTasks[1].cancel(); channels[1].close()
                _ = await sendTasks[1].result
            }
            if frame == 160 {
                let copies = try await stores[1].captures()
                guard let video = copies.first(where: { $0.local.id == videoId }) else { throw MediaRecords.failure("No video before Stop") }
                try expect(video.savedObjects >= 3 && !video.complete, "Live video not durably received")
                try expect(copies.contains { $0.local.id == photoId && $0.complete }, "Photo not received during recording")
                let url = try await playback.start(store: stores[1], hash: video.hash)
                player = AVPlayer(url: url); player?.play(); liveSaved = true
                try await connect(2)
            }
            if frame == 340 { livePlayed = (player?.currentTime().seconds ?? 0) > 0.5 }
            try await Task.sleep(for: .milliseconds(33))
        }
        let finished = await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
        try expect(finished && liveSaved, "Live capture failed")
        try errors.check()
        try queue.finishCapture(accountId: peers[0].device.accountId, captureId: videoId, ending: .stopped, expectedObjects: writer.emittedObjectCount)
        try await until("all recipients caught up") {
            for index in 1...3 {
                let copies = try await stores[index].captures()
                if copies.count != 2 || !copies.allSatisfy(\.complete) { return false }
            }
            return true
        }
        try expect(livePlayed, "HLS did not play before recording stopped: \(String(describing: player?.currentItem?.error))")
        print("PASS: three TLS recipients, real live H.264/AAC and photo, concurrent owner upload, disconnect/resume, HLS playback before Stop")
        prepare.cancel(); _ = await prepare.result
        sendTasks.forEach { $0.cancel() }; channels.forEach { $0.close() }
        for task in sendTasks { _ = await task.result }
        for receiver in receivers { for task in receiver.stop() { await task.value } }
        // Reopen B's received store. Its own authenticated session uploads A's data.
        stores[1] = try ReceivedMediaStore(peers: peers[1], root: config.root.appendingPathComponent("phone-1/ReceivedMedia"), budget: budgets[1])
        var relayTasks: [Task<Void, Error>] = []
        for index in 1...3 {
            let worker = try RelayUploadWorker(api: API(baseURL: config.baseUrl, token: config.sessions[index].token), store: stores[index], slots: UploadSlots())
            let copies = try await stores[index].captures()
            relayTasks.append(Task {
                for capture in copies {
                    var attempts = 0
                    while true {
                        do { if try await !worker.sendNext(captureHash: capture.hash) { break } }
                        catch {
                            attempts += 1; if attempts > 4 { throw error }
                            try await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
            })
        }
        for task in relayTasks { try await task.value }
        struct Detail: Decodable, Sendable { let cloudComplete: Bool; let recordingEnding: String; let kind: String }
        for id in [videoId, photoId] {
            let detail: Detail = try await apiA.request("GET", "captures/\(id)")
            try expect(detail.cloudComplete && detail.recordingEnding == "stopped", "Recipient recovery incomplete")
        }
        let photo = try await stores[1].captures().first { $0.local.id == photoId }!
        try await stores[1].remove(captureHash: photo.hash)
        let reopened = try ReceivedMediaStore(peers: peers[1], root: config.root.appendingPathComponent("phone-1/ReceivedMedia"), budget: budgets[1])
        try expect(try await reopened.captures().count == 1, "Removed received copy returned on reopen")
        let ownerPhoto: Detail = try await apiA.request("GET", "captures/\(photoId)")
        try expect(ownerPhoto.cloudComplete, "Local deletion touched recorder cloud")
        // Each phone holds a different portion. None can truthfully report a
        // complete local video; together they recover the one canonical capture.
        let sparseId = UUID().uuidString.lowercased()
        let blobs = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 1000 + $0) }
        for sequence in 0..<4 {
            try queue.enqueue(blobs[sequence], accountId: recorderAccount, captureId: sparseId, captureKind: "video", sequence: sequence,
                kind: sequence == 0 ? "init" : "media", duration: sequence == 0 ? 0 : 1, startTime: Double(max(0, sequence - 1)))
        }
        try queue.finishCapture(accountId: recorderAccount, captureId: sparseId, ending: .interrupted, expectedObjects: 4)
        let sparse = try await source.prepare(captureId: sparseId, queue: queue, approvalIDs: Set(approvals.map(\.id)))!
        let sparseHash = try sparse.descriptor.digest
        for index in 1...3 {
            for sequence in [0, index] {
                guard case .writing(let id) = try await stores[index].begin(descriptor: sparse.descriptor, grant: sparse.grants[approval(index).id]!,
                    manifest: sparse.objects[sequence].manifest, sender: peers[0].device) else { throw MediaRecords.failure("Unexpected sparse duplicate") }
                try await stores[index].append(blobs[sequence], to: id); _ = try await stores[index].commit(id)
            }
            try await stores[index].receiveCompletion(sparse.completion!, descriptor: sparse.descriptor, grant: sparse.grants[approval(index).id]!, sender: peers[0].device)
            try expect(try await stores[index].completed(captureHash: sparseHash) == nil, "Partial copy reported complete")
        }
        try expect(try await stores[2].playback(captureHash: sparseHash).manifests.count == 1, "Playback crossed a missing fragment")
        relayTasks.removeAll()
        for index in 1...3 {
            let worker = try RelayUploadWorker(api: API(baseURL: config.baseUrl, token: config.sessions[index].token), store: stores[index], slots: UploadSlots())
            relayTasks.append(Task { while try await worker.sendNext(captureHash: sparseHash) {} })
        }
        for task in relayTasks { try await task.value }
        let sparseDetail: Detail = try await apiA.request("GET", "captures/\(sparseId)")
        try expect(sparseDetail.cloudComplete && sparseDetail.recordingEnding == "interrupted", "Complementary copies did not recover interrupted recording")
        try await peers[2].revoke(approval(2).id)
        let revokedWorker = try RelayUploadWorker(api: API(baseURL: config.baseUrl, token: config.sessions[2].token), store: stores[2], slots: UploadSlots())
        do { _ = try await revokedWorker.sendNext(captureHash: sparseHash); throw MediaRecords.failure("Revoked permission uploaded") }
        catch let error as APIError where error.status == 403 { }
        try expect(try await stores[2].inventory(captureHash: sparseHash).count == 2, "Revocation removed saved originals")
        print("PASS: complementary recipient fragments, interrupted ending, gap-safe playback, revoked grant retains local copies")
        print("PASS: native nearby recovery · A stays offline, B/C/D converge in RustFS, durable recipient retry and local-only deletion")
    }
    static func storageChecks(root: URL) throws {
        let budget = try MediaStorageBudget(root: root, limit: 10_000, receivedLimit: 6000)
        let a = try budget.reserve(6000, area: .received)
        do { _ = try budget.reserve(1, area: .received); throw MediaRecords.failure("Received budget exceeded") }
        catch let error as APIError where error.status == 413 { }
        let b = try budget.reserve(4000, area: .owner)
        do { _ = try budget.reserve(1, area: .owner); throw MediaRecords.failure("Combined budget exceeded") }
        catch let error as APIError where error.status == 413 { }
        try budget.finish(a, paths: []); try budget.finish(b, paths: [])
        let directory = root.appendingPathComponent("ReceivedMedia/another-account")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 6000).write(to: directory.appendingPathComponent("media"))
        let restored = try MediaStorageBudget(root: root, limit: 10_000, receivedLimit: 6000)
        do { _ = try restored.reserve(1, area: .received); throw MediaRecords.failure("Other account bypassed budget") }
        catch let error as APIError where error.status == 413 { }
        try expect(try LivePlayback.byteRange("bytes=2-5", size: 10) == 2..<6, "Bad playback range")
        try expect(try LivePlayback.byteRange("bytes=-3", size: 10) == 7..<10, "Bad playback suffix")
        print("PASS: combined and cross-account storage reservations, playback ranges")
    }
    static func slotChecks() async throws {
        let slots = UploadSlots(), gate = SlotGate()
        let running = (0..<2).map { _ in Task { try await slots.run(owner: false) { await gate.enter() } } }
        try await until("upload slots acquired") { await gate.count == 2 }
        let cancelled = Task { try await slots.run(owner: false) { throw MediaRecords.failure("Cancelled waiter acquired slot") } }
        cancelled.cancel()
        do { try await cancelled.value; throw MediaRecords.failure("Cancellation lost") } catch is CancellationError { }
        await gate.release()
        for task in running { try await task.value }
        let value = try await slots.run(owner: true) { 7 }
        try expect(value == 7, "Upload slot leaked")
    }
}

private actor SlotGate {
    var count = 0
    var callbacks: [CheckedContinuation<Void, Never>] = []
    func enter() async { count += 1; await withCheckedContinuation { callbacks.append($0) } }
    func release() { callbacks.forEach { $0.resume() }; callbacks.removeAll() }
}
private final class RecordingErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; self.error = error }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let error { throw error } }
}

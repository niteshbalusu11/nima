import Foundation
import CryptoKit

@main
struct SignedMediaCheck {
    struct Config: Codable { let baseUrl: URL; var sessionA: Session; var sessionB: Session; let root: URL }
    struct Vector: Codable { let name: String; let kind: String; let capture: MediaRecords.Envelope; let record: MediaRecords.Envelope; let valid: Bool }
    struct Fixtures: Codable {
        let recorder: RegisteredDevice; let approval: PeerApproval; let vectors: [Vector]
        let descriptor: MediaRecords.Envelope; let grant: MediaRecords.Envelope
        let manifests: [MediaRecords.Envelope]; let completion: MediaRecords.Envelope
    }
    struct Restart: Codable { let config: Config; let recipient: RegisteredDevice; let fixtures: Fixtures; let complete: Bool }
    static func expect(_ value: Bool, _ message: String) throws { if !value { throw MediaRecords.failure(message) } }
    @MainActor
    static func rejects(_ operation: @MainActor () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw MediaRecords.failure("Invalid operation succeeded")
    }
    static func main() async throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.count > 2 { try await restart(file, stageOnly: CommandLine.arguments[2] == "stage"); return }
        var config = try API.decoder.decode(Config.self, from: Data(contentsOf: file))
        let identity = DeviceIdentity.ephemeralForCheck(), recipientIdentity = DeviceIdentity.ephemeralForCheck()
        let apiA = API(baseURL: config.baseUrl, token: config.sessionA.token), apiB = API(baseURL: config.baseUrl, token: config.sessionB.token)
        let recorder = try await identity.register(using: apiA, session: config.sessionA)
        let recipient = try await recipientIdentity.register(using: apiB, session: config.sessionB)
        config.sessionA.deviceId = recorder.id; config.sessionB.deviceId = recipient.id
        let a = try PeerStore(api: apiA, session: config.sessionA, device: recorder, root: config.root.appendingPathComponent("peers"))
        let b = try PeerStore(api: apiB, session: config.sessionB, device: recipient, root: config.root.appendingPathComponent("peers"))
        let approval = try await PairingFixture.approve(a, b, identity, recipientIdentity).approval
        try await checkOwner(config: config, identity: identity, peers: a, recipient: b, approval: approval)
        let now = Int64(Date().timeIntervalSince1970)
        let descriptor = try MediaRecords.sign(.descriptor(.init(captureId: "00112233-4455-6677-8899-aabbccddeeff",
            recorderAccountId: recorder.accountId, recorderDeviceId: recorder.id,
            signingKeyHash: Data(SHA256.hash(data: DeviceIdentity.decodeURL(recorder.signingPublicKey)!)), kind: .video, createdAt: now)), with: identity)
        let capture = try MediaRecords.Capture(descriptor, recorder: recorder)
        let grant = try MediaRecords.sign(.grant(.init(id: String(repeating: "a", count: 32), descriptorHash: capture.digest,
            senderDeviceId: recorder.id, recipientAccountId: recipient.accountId, recipientDeviceId: recipient.id,
            approvalId: approval.id, issuedAt: now, expiresAt: now + MediaRecords.grantLifetime, byteLimit: MediaRecords.maxCapture)), with: identity)
        let blobs = [Data("initialization".utf8), Data(repeating: 7, count: 131_075), Data("fragment-two".utf8)]
        let manifests = try blobs.enumerated().map { sequence, data in
            try MediaRecords.sign(.manifest(.init(descriptorHash: capture.digest, sequence: sequence,
                kind: sequence == 0 ? .initialization : .media, size: data.count, sha256: Data(SHA256.hash(data: data)),
                md5: Data(Insecure.MD5.hash(data: data)), duration: sequence == 0 ? 0 : 1.25, startTime: sequence == 0 ? 0 : Double(sequence - 1) * 1.25)), with: identity)
        }
        let completion = try MediaRecords.sign(.completion(.init(descriptorHash: capture.digest, ending: .stopped,
            lastSequence: 2, objectCount: 3, totalBytes: Int64(blobs.reduce(0) { $0 + $1.count }))), with: identity)
        let photoBytes = Data("photo bytes".utf8)
        let photoDescriptor = try MediaRecords.sign(.descriptor(.init(captureId: "11223344-5566-7788-99aa-bbccddeeff00",
            recorderAccountId: recorder.accountId, recorderDeviceId: recorder.id,
            signingKeyHash: capture.descriptor.signingKeyHash, kind: .photo, createdAt: now)), with: identity)
        let photo = try MediaRecords.Capture(photoDescriptor, recorder: recorder)
        let photoGrant = try MediaRecords.sign(.grant(.init(id: String(repeating: "b", count: 32), descriptorHash: photo.digest,
            senderDeviceId: recorder.id, recipientAccountId: recipient.accountId, recipientDeviceId: recipient.id,
            approvalId: approval.id, issuedAt: now, expiresAt: now + 60, byteLimit: Int64(photoBytes.count))), with: identity)
        let photoManifest = try MediaRecords.sign(.manifest(.init(descriptorHash: photo.digest, sequence: 0, kind: .photo,
            size: photoBytes.count, sha256: Data(SHA256.hash(data: photoBytes)), md5: Data(Insecure.MD5.hash(data: photoBytes)), duration: 0, startTime: 0)), with: identity)
        let photoCompletion = try MediaRecords.sign(.completion(.init(descriptorHash: photo.digest, ending: .stopped,
            lastSequence: 0, objectCount: 1, totalBytes: Int64(photoBytes.count))), with: identity)
        var vectors = [Vector(name: "video capture", kind: "capture", capture: descriptor, record: descriptor, valid: true),
                       Vector(name: "recipient grant", kind: "grant", capture: descriptor, record: grant, valid: true),
                       Vector(name: "stopped completion", kind: "completion", capture: descriptor, record: completion, valid: true)]
        vectors += manifests.enumerated().map { Vector(name: "object \($0.offset)", kind: "object", capture: descriptor, record: $0.element, valid: true) }
        for (kind, record) in [("capture", photoDescriptor), ("grant", photoGrant), ("object", photoManifest), ("completion", photoCompletion)] {
            vectors.append(Vector(name: "photo \(kind)", kind: kind, capture: photoDescriptor, record: record, valid: true))
        }
        func altered(_ envelope: MediaRecords.Envelope, _ edit: (inout Data) -> Void) throws -> MediaRecords.Envelope {
            var bytes = try envelope.bytes; edit(&bytes)
            return MediaRecords.Envelope(payload: DeviceIdentity.encodeURL(bytes), signature: DeviceIdentity.encodeURL(try identity.signMedia(bytes)))
        }
        func add(_ name: String, _ kind: String, _ record: MediaRecords.Envelope) { vectors.append(Vector(name: name, kind: kind, capture: descriptor, record: record, valid: false)) }
        for (kind, envelope) in [("capture", descriptor), ("grant", grant), ("object", manifests[1]), ("completion", completion)] {
            add("\(kind) trailing bytes", kind, try altered(envelope) { $0.append(0) })
            add("\(kind) truncated", kind, try altered(envelope) { $0.removeLast() })
            add("\(kind) wrong version", kind, try altered(envelope) { $0[$0.firstIndex(of: 0)! - 1] = 50 })
            var corrupted = try envelope.bytes; corrupted[corrupted.count - 1] ^= 1
            add("\(kind) bad signature", kind, .init(payload: DeviceIdentity.encodeURL(corrupted), signature: envelope.signature))
            add("\(kind) noncanonical base64", kind, .init(payload: envelope.payload + "=", signature: envelope.signature))
        }
        let objectPrefix = Data("uploadvideo.media.object.v1\0".utf8).count
        add("wrong descriptor", "object", try altered(manifests[1]) { $0[objectPrefix] ^= 1 })
        for bits in [Double.nan.bitPattern, Double.infinity.bitPattern, (-0.0).bitPattern, (-1.0).bitPattern, 61.0.bitPattern] {
            add("invalid duration \(bits)", "object", try altered(manifests[1]) { data in
                var value = bits.bigEndian; withUnsafeBytes(of: &value) { data.replaceSubrange(data.count - 16..<data.count - 8, with: $0) }
            })
        }
        let grantPrefix = Data("uploadvideo.media.grant.v1\0".utf8).count
        add("wrong recipient", "grant", try altered(grant) { $0[grantPrefix + 16 + 32 + 16 + 16] ^= 1 })
        add("wrong approval", "grant", try altered(grant) { $0[grantPrefix + 16 + 32 + 16 + 16 + 16] ^= 1 })
        add("wrong destination", "grant", try altered(grant) { $0[$0.count - 26] = 2 })
        add("wrong scope", "grant", try altered(grant) { $0[$0.count - 25] = 2 })
        add("long grant", "grant", try altered(grant) { $0[$0.count - 9] &+= 1 })
        add("completion count", "completion", try altered(completion) { $0[$0.count - 9] &+= 1 })
        add("wrong recorder account", "capture", try altered(descriptor) { $0[Data("uploadvideo.media.capture.v1\0".utf8).count + 16] ^= 1 })
        let interrupted = try altered(completion) { $0[$0.count - 17] = 2 }
        vectors.append(Vector(name: "interrupted ending", kind: "completion", capture: descriptor, record: interrupted, valid: true))
        let permission = try capture.grant(grant, approval: approval)
        try permission.checkTime(now)
        try await rejects { try permission.checkTime(now + MediaRecords.grantLifetime) }
        try await rejects { try permission.checkTime(now - 301) }
        let fixtures = Fixtures(recorder: recorder, approval: approval, vectors: vectors, descriptor: descriptor, grant: grant, manifests: manifests, completion: completion)
        try checkVectors(fixtures)
        if let path = ProcessInfo.processInfo.environment["SIGNED_MEDIA_GOLDEN"], FileManager.default.fileExists(atPath: path) {
            try checkVectors(API.decoder.decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: path))))
        }
        try API.encode(fixtures).write(to: config.root.appendingPathComponent("vectors.json"))
        let store = try ReceivedMediaStore(peers: b, root: config.root.appendingPathComponent("received"))
        let otherAccount = try ReceivedMediaStore(peers: a, root: config.root.appendingPathComponent("received"))
        guard case .writing(let photoWrite) = try await store.begin(descriptor: photoDescriptor, grant: photoGrant, manifest: photoManifest, sender: recorder) else { fatalError() }
        try await store.append(photoBytes, to: photoWrite)
        let photoReceipt = try await store.commit(photoWrite)
        try expect(photoReceipt.recorderAccountId == recorder.accountId && photoReceipt.captureId == photo.descriptor.captureId, "Photo ownership changed")
        try await store.receiveCompletion(photoCompletion, descriptor: photoDescriptor, grant: photoGrant, sender: recorder)
        try expect(try await store.completed(captureHash: photo.digest) == .stopped, "Photo not complete")
        func begin(_ sequence: Int, manifest: MediaRecords.Envelope? = nil) async throws -> ReceivedMediaStore.Admission {
            try await store.begin(descriptor: descriptor, grant: grant, manifest: manifest ?? manifests[sequence], sender: recorder)
        }
        func save(_ sequence: Int) async throws -> ReceivedMediaStore.Receipt {
            guard case .writing(let id) = try await begin(sequence) else { throw MediaRecords.failure("Expected fresh object") }
            for start in stride(from: 0, to: blobs[sequence].count, by: 65_536) {
                try await store.append(blobs[sequence].subdata(in: start..<min(start + 65_536, blobs[sequence].count)), to: id)
            }
            return try await store.commit(id)
        }
        // A bad or incomplete body must not occupy the immutable sequence.
        guard case .writing(let bad) = try await begin(0) else { fatalError() }
        try await store.append(Data(repeating: 0, count: blobs[0].count), to: bad)
        try await rejects { _ = try await store.commit(bad) }
        try expect(try await store.inventory(captureHash: capture.digest).isEmpty, "Corrupt bytes got a receipt")
        let receipt0 = try await save(0)
        let changedDescriptor = try altered(descriptor) { $0[$0.count - 1] &+= 1 }
        let changedHash = try changedDescriptor.digest
        let changedGrant = try altered(grant) { $0[grantPrefix] ^= 4; $0.replaceSubrange(grantPrefix + 16..<grantPrefix + 48, with: changedHash) }
        let changedManifest = try altered(manifests[0]) { $0.replaceSubrange(objectPrefix..<objectPrefix + 32, with: changedHash) }
        try await rejects { _ = try await store.begin(descriptor: changedDescriptor, grant: changedGrant, manifest: changedManifest, sender: recorder) }
        guard case .saved(let duplicate) = try await begin(0) else { fatalError() }
        try expect(duplicate == receipt0, "Duplicate changed receipt")
        let resign = try MediaRecords.sign(.grant(permission), with: identity)
        guard case .saved = try await store.begin(descriptor: descriptor, grant: resign, manifest: manifests[0], sender: recorder) else { fatalError() }
        try expect(try await store.relayGrants(captureHash: capture.digest) == [grant], "Retry replaced original signed permission")
        _ = try await save(2)
        try await store.receiveCompletion(completion, descriptor: descriptor, grant: grant, sender: recorder)
        try await rejects { try await store.receiveCompletion(interrupted, descriptor: descriptor, grant: grant, sender: recorder) }
        try expect(try await store.completed(captureHash: capture.digest) == nil, "Sparse media reported complete")
        guard case .writing(let short) = try await begin(1) else { fatalError() }
        try await store.append(blobs[1].prefix(3), to: short)
        try await rejects { _ = try await store.commit(short) }
        guard case .writing(let large) = try await begin(1) else { fatalError() }
        try await rejects { try await store.append(Data(repeating: 0, count: 65_537), to: large) }
        let restartFile = config.root.appendingPathComponent("restart.json")
        func runChild(_ mode: String) throws {
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [restartFile.path, mode]
            try child.run(); child.waitUntilExit(); try expect(child.terminationStatus == 0, "Restart check failed")
        }
        try JSONEncoder().encode(Restart(config: config, recipient: recipient, fixtures: fixtures, complete: false)).write(to: restartFile)
        for mode in ["stage", "verify"] { try runChild(mode) }
        _ = try await save(1)
        try expect(try await store.completed(captureHash: capture.digest) == .stopped, "Complete media not recognized")
        try expect(try await otherAccount.inventory(captureHash: capture.digest).isEmpty, "Another account reused received media")
        let conflicting = try altered(manifests[1]) { $0[objectPrefix + 32 + 4 + 1 + 8] ^= 1 }
        try await rejects { _ = try await begin(1, manifest: conflicting) }
        try await rejects { _ = try await store.begin(descriptor: descriptor, grant: grant, manifest: manifests[0], sender: recipient) }
        try await rejects { _ = try await store.begin(descriptor: descriptor, grant: grant, manifest: manifests[0], sender: recorder, now: now + MediaRecords.grantLifetime) }
        try expect(try await store.relayGrants(captureHash: capture.digest, now: now + MediaRecords.grantLifetime).isEmpty, "Expired grant scheduled for upload")
        try JSONEncoder().encode(Restart(config: config, recipient: recipient, fixtures: fixtures, complete: true)).write(to: restartFile)
        try runChild("verify")
        // Removing approval during a receive must prevent committing its bytes.
        let freshDescriptor = try altered(descriptor) { $0[Data("uploadvideo.media.capture.v1\0".utf8).count] ^= 1 }
        let freshHash = try freshDescriptor.digest
        let freshGrant = try altered(grant) { $0[grantPrefix] ^= 1; $0.replaceSubrange(grantPrefix + 16..<grantPrefix + 48, with: freshHash) }
        let freshManifest = try altered(manifests[0]) { $0.replaceSubrange(objectPrefix..<objectPrefix + 32, with: freshHash) }
        // A filesystem failure cannot return a receipt; reopen cleans the stranded partial write.
        let failureRoot = config.root.appendingPathComponent("disk-failure")
        try FileManager.default.copyItem(at: config.root.appendingPathComponent("received"), to: failureRoot)
        let disk = try ReceivedMediaStore(peers: b, root: failureRoot)
        let existing = try await disk.savedObject(captureHash: capture.digest, sequence: 0)!
        guard case .writing(let stranded) = try await disk.begin(descriptor: freshDescriptor, grant: freshGrant, manifest: freshManifest, sender: recorder) else { fatalError() }
        try await disk.append(blobs[0], to: stranded)
        let scope = existing.file.deletingLastPathComponent().deletingLastPathComponent()
        let displaced = config.root.appendingPathComponent("displaced-scope")
        try FileManager.default.moveItem(at: scope, to: displaced)
        try Data().write(to: scope)
        try await rejects { _ = try await disk.commit(stranded) }
        try FileManager.default.removeItem(at: scope)
        try FileManager.default.moveItem(at: displaced, to: scope)
        let recoveredDisk = try ReceivedMediaStore(peers: b, root: failureRoot)
        try expect(try await recoveredDisk.inventory(captureHash: freshHash).isEmpty, "Failed write became a saved object")
        try expect(try await recoveredDisk.inventory(captureHash: capture.digest).count == 3, "Storage failure lost earlier commits")
        guard case .writing(let revoked) = try await store.begin(descriptor: freshDescriptor, grant: freshGrant, manifest: freshManifest, sender: recorder) else { fatalError() }
        try await store.append(blobs[0], to: revoked); try await b.revoke(approval.id)
        try await rejects { _ = try await store.commit(revoked) }
        try expect(try await store.relayGrants(captureHash: capture.digest).isEmpty, "Revoked grant scheduled for upload")
        // A modified saved file is not advertised after reopening.
        let saved = try await store.savedObject(captureHash: capture.digest, sequence: 0)!
        try Data("corrupt".utf8).write(to: saved.file)
        let corruptStore = try ReceivedMediaStore(peers: b, root: config.root.appendingPathComponent("received"))
        try await rejects { _ = try await corruptStore.inventory(captureHash: capture.digest) }
        print("PASS: signed records, bounded receive, duplicate/conflict checks, sparse completion, restart, revocation, and corrupt-file recovery")
    }
    static func checkVectors(_ fixtures: Fixtures) throws {
        for vector in fixtures.vectors {
            var valid = true
            do {
                let capture = try MediaRecords.Capture(vector.capture, recorder: fixtures.recorder)
                switch vector.kind {
                case "capture": _ = try MediaRecords.Capture(vector.record, recorder: fixtures.recorder)
                case "grant": _ = try capture.grant(vector.record, approval: fixtures.approval)
                case "object": _ = try capture.manifest(vector.record)
                default: _ = try capture.completion(vector.record)
                }
            } catch { valid = false }
            try expect(valid == vector.valid, "Swift disagreed with vector: \(vector.name)")
        }
    }
    static func checkOwner(config: Config, identity: DeviceIdentity, peers: PeerStore, recipient: PeerStore, approval: PeerApproval) async throws {
        let root = config.root.appendingPathComponent("owner-records"), queueRoot = config.root.appendingPathComponent("owner-queue")
        let queue = try UploadQueue(root: queueRoot), source = try OwnerMediaRecords(identity: identity, peers: peers, root: root)
        let captureId = UUID().uuidString.lowercased(), account = peers.device.accountId
        let approvals: Set<String> = [approval.id]
        try await rejects { _ = try OwnerMediaRecords(identity: .ephemeralForCheck(), peers: peers, root: root) }
        try expect(try await source.prepare(captureId: captureId, queue: queue, approvalIDs: approvals) == nil, "Empty recording was shared")
        try queue.enqueue(Data("init".utf8), accountId: account, captureId: captureId, captureKind: "video", sequence: 0, kind: "init")
        try expect(try await source.prepare(captureId: captureId, queue: queue, approvalIDs: []) == nil, "Approval alone enabled sharing")
        let initial = try await source.prepare(captureId: captureId, queue: queue, approvalIDs: approvals)!
        try expect(initial.objects.count == 1 && initial.completion == nil, "Live recording got a false ending")
        let capture = try MediaRecords.Capture(initial.descriptor, recorder: peers.device)
        try expect(capture.descriptor.recorderAccountId == account, "Original recorder changed")
        let receiver = try ReceivedMediaStore(peers: recipient, root: config.root.appendingPathComponent("owner-to-recipient"))
        func receive(_ records: OwnerMediaRecords.Prepared) async throws {
            for object in records.objects {
                if case .writing(let id) = try await receiver.begin(descriptor: records.descriptor, grant: records.grants[approval.id]!, manifest: object.manifest, sender: peers.device) {
                    try await receiver.append(Data(contentsOf: object.file), to: id)
                    _ = try await receiver.commit(id)
                }
            }
            if let completion = records.completion {
                try await receiver.receiveCompletion(completion, descriptor: records.descriptor, grant: records.grants[approval.id]!, sender: peers.device)
            }
        }
        try await receive(initial)
        try expect(try await receiver.inventory(captureHash: capture.digest).count == 1, "Live fragment was not saved")
        try expect(try await receiver.completed(captureHash: capture.digest) == nil, "Live received recording prematurely completed")
        try queue.enqueue(Data("fragment".utf8), accountId: account, captureId: captureId, captureKind: "video", sequence: 1, kind: "media", duration: 1.25)
        let live = try await source.prepare(captureId: captureId, queue: queue, approvalIDs: approvals)!
        try expect(live.objects.count == 2 && live.completion == nil && live.descriptor == initial.descriptor && live.grants == initial.grants,
                   "Growing capture replaced stable records or prematurely ended")
        for object in queue.retainedObjects(accountId: account, captureId: captureId) { try queue.acknowledge(object) }
        try queue.finishCapture(accountId: account, captureId: captureId, ending: .interrupted, expectedObjects: 2)
        let finished = try await source.prepare(captureId: captureId, queue: queue, approvalIDs: approvals)!
        try expect(finished.objects.map(\.manifest) == live.objects.map(\.manifest) && finished.grants == live.grants, "Cloud acknowledgement replaced signed records")
        try expect(try capture.completion(finished.completion!).ending == .interrupted, "Interruption became a normal stop")
        try await receive(finished)
        try expect(try await receiver.completed(captureHash: capture.digest) == .interrupted, "Owner-generated records did not recover at the recipient")
        let reopenedQueue = try UploadQueue(root: queueRoot), reopened = try OwnerMediaRecords(identity: identity, peers: peers, root: root)
        let restored = try await reopened.prepare(captureId: captureId, queue: reopenedQueue, approvalIDs: approvals)!
        try expect(restored.descriptor == initial.descriptor && restored.completion == finished.completion && restored.grants == initial.grants && restored.objects.map(\.manifest) == live.objects.map(\.manifest), "Restart replaced original signatures")
        let oldGrant = try capture.grant(initial.grants[approval.id]!, approval: approval)
        let renewed = try await reopened.prepare(captureId: captureId, queue: reopenedQueue, approvalIDs: approvals, now: oldGrant.expiresAt)!
        let newGrant = try capture.grant(renewed.grants[approval.id]!, approval: approval)
        try expect(newGrant.id != oldGrant.id && newGrant.issuedAt == oldGrant.expiresAt && renewed.descriptor == initial.descriptor, "Permission renewal changed media or reused an expired grant")
        try await rejects { _ = try await source.prepare(captureId: captureId, queue: queue, approvalIDs: [String(repeating: "0", count: 32)]) }
        try await rejects { try queue.finishCapture(accountId: account, captureId: captureId, ending: .stopped, expectedObjects: 2) }
        try await rejects { try queue.enqueue(Data([1]), accountId: account, captureId: captureId, captureKind: "video", sequence: 2, kind: "media") }
        let photoId = UUID().uuidString.lowercased()
        try queue.enqueue(Data("photo".utf8), accountId: account, captureId: photoId, captureKind: "photo", sequence: 0, kind: "photo")
        let photo = try await source.prepare(captureId: photoId, queue: queue, approvalIDs: approvals)!
        let photoCapture = try MediaRecords.Capture(photo.descriptor, recorder: peers.device)
        try expect(try photoCapture.completion(photo.completion!).ending == .stopped && photoCapture.grant(photo.grants[approval.id]!, approval: approval).byteLimit == 5, "Photo ending or allowance incorrect")
        // Corruption before the first signature cannot turn into authentic shared bytes.
        let corruptId = UUID().uuidString.lowercased()
        try queue.enqueue(Data("init".utf8), accountId: account, captureId: corruptId, captureKind: "video", sequence: 0, kind: "init")
        let corrupt = queue.retainedObjects(accountId: account, captureId: corruptId)[0]
        try Data("evil".utf8).write(to: queue.file(corrupt))
        try await rejects { _ = try await source.prepare(captureId: corruptId, queue: queue, approvalIDs: approvals) }
        try queue.remove(accountId: account, captureId: captureId)
        try expect(try await source.prepare(captureId: captureId, queue: queue, approvalIDs: approvals) == nil, "Deleted media was offered again")
        let blocked = try PeerStore(api: API(baseURL: config.baseUrl, token: config.sessionA.token), session: config.sessionA, device: peers.device,
            root: config.root.appendingPathComponent("owner-revoked-peers"))
        try await blocked.refresh(); try await blocked.revoke(approval.id)
        let stopped = try OwnerMediaRecords(identity: identity, peers: blocked, root: root)
        try await rejects { _ = try await stopped.prepare(captureId: photoId, queue: queue, approvalIDs: approvals) }
        print("PASS: live owner records, retained cloud uploads, exact signature reuse, ending intent, renewal, corruption, and deletion")
    }
    static func restart(_ file: URL, stageOnly: Bool) async throws {
        let input = try JSONDecoder().decode(Restart.self, from: Data(contentsOf: file)), config = input.config, fixtures = input.fixtures
        let b = try PeerStore(api: API(baseURL: config.baseUrl, token: config.sessionB.token), session: config.sessionB, device: input.recipient,
                              root: config.root.appendingPathComponent("peers"))
        let store = try ReceivedMediaStore(peers: b, root: config.root.appendingPathComponent("received"))
        let digest = try fixtures.descriptor.digest
        let inventory = try await store.inventory(captureHash: digest)
        try expect(inventory.map(\.sequence) == (input.complete ? [0, 1, 2] : [0, 2]), "Restart lost saved fragments or claimed a partial write")
        try expect(try await store.completed(captureHash: digest) == (input.complete ? .stopped : nil), "Restart reported incorrect completion")
        if stageOnly {
            guard case .writing(let id) = try await store.begin(descriptor: fixtures.descriptor, grant: fixtures.grant,
                manifest: fixtures.manifests[1], sender: fixtures.recorder) else { throw MediaRecords.failure("Expected incomplete sequence") }
            try await store.append(Data([7, 7, 7]), to: id)
            // Terminate with an actual open write, without calling stop/abort/commit.
            exit(0)
        }
        try verifyNoStaging(config.root.appendingPathComponent("received"))
        print("PASS: separate-process offline inventory and interrupted staging cleanup")
    }
    static func verifyNoStaging(_ root: URL) throws {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files { try expect(!url.lastPathComponent.hasPrefix(".tmp-"), "Restart kept partial staging") }
    }
}

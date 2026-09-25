import Foundation
import CryptoKit
import Darwin

// Signs committed originals, including ones already acknowledged by the cloud.
// The caller selects recipients explicitly; approval alone never starts sharing.
actor OwnerMediaRecords {
    struct Object: Sendable {
        let manifest: MediaRecords.Envelope
        let file: URL
    }
    struct Prepared: Sendable {
        let descriptor: MediaRecords.Envelope
        let grants: [String: MediaRecords.Envelope] // approval ID -> permission
        let objects: [Object]
        let completion: MediaRecords.Envelope?
    }
    private struct State {
        let capture: MediaRecords.Capture
        var manifests: [Int: MediaRecords.Envelope] = [:]
        var grants: [String: MediaRecords.Envelope] = [:]
        var completion: MediaRecords.Envelope?
    }
    private let identity: DeviceIdentity
    private let peers: PeerStore
    private let device: RegisteredDevice
    private let root: URL
    private var states: [String: State] = [:]
    private var healthy = true

    init(identity: DeviceIdentity, peers: PeerStore, root: URL? = nil) throws {
        guard identity.matches(peers.device) else { throw MediaRecords.failure("Sharing keys belong to another device") }
        self.identity = identity; self.peers = peers; device = peers.device
        let directory = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("SharedMediaRecords", isDirectory: true)
        let scope = Data((peers.baseURL.absoluteString + "\n" + device.accountId + "\n" + device.id).utf8)
        self.root = directory.appendingPathComponent(Self.hex(Data(SHA256.hash(data: scope))), isDirectory: true)
    }

    func prepare(captureId: String, queue: UploadQueue, approvalIDs: Set<String>,
                 now: Int64 = Int64(Date().timeIntervalSince1970)) async throws -> Prepared? {
        guard !approvalIDs.isEmpty else { return nil }
        guard approvalIDs.count <= 3, UUID(uuidString: captureId)?.uuidString.lowercased() == captureId,
              now > 0, now <= Int64.max - MediaRecords.grantLifetime else { throw MediaRecords.failure("Invalid sharing request") }
        let snapshot = await peers.snapshot()
        guard healthy, snapshot.accessActive else { throw MediaRecords.failure("Sharing is unavailable") }
        let approvals = snapshot.approvals.filter { approvalIDs.contains($0.id) && $0.sender == device }
        guard approvals.count == approvalIDs.count else { throw MediaRecords.failure("Recipient is no longer approved") }
        let items = queue.retainedObjects(accountId: device.accountId, captureId: captureId)
        guard let first = items.first else { states[captureId] = nil; return nil }
        guard items.count <= MediaRecords.maxSequence + 1, items.enumerated().allSatisfy({ $0.offset == $0.element.sequence }),
              items.allSatisfy({ $0.captureKind == first.captureKind }),
              let kind: MediaRecords.CaptureKind = first.captureKind == "video" ? .video : (first.captureKind == "photo" ? .photo : nil),
              kind != .photo || items.count == 1,
              first.createdAt.timeIntervalSince1970 > 0, first.createdAt.timeIntervalSince1970 < Double(Int64.max) else {
            throw MediaRecords.failure("Saved recording is incomplete or invalid")
        }
        let descriptor = MediaRecords.Descriptor(captureId: captureId, recorderAccountId: device.accountId, recorderDeviceId: device.id,
            signingKeyHash: Data(SHA256.hash(data: DeviceIdentity.decodeURL(device.signingPublicKey)!)), kind: kind,
            createdAt: Int64(first.createdAt.timeIntervalSince1970))
        var state = try load(captureId, descriptor: descriptor)
        try state.capture.checkTime(now)
        guard state.manifests.keys.allSatisfy({ $0 < items.count }) else { throw MediaRecords.failure("Previously shared fragments are missing") }
        var total: Int64 = 0
        for item in items {
            guard let objectKind: MediaRecords.ObjectKind = item.kind == "init" ? .initialization : (item.kind == "media" ? .media : (item.kind == "photo" ? .photo : nil)),
                  item.sha256.utf8.count == 64, let sha = Self.unhex(item.sha256), let md5 = Data(base64Encoded: item.md5),
                  md5.base64EncodedString() == item.md5 else { throw MediaRecords.failure("Invalid saved fragment metadata") }
            let manifest = MediaRecords.Manifest(descriptorHash: state.capture.digest, sequence: item.sequence, kind: objectKind,
                size: item.size, sha256: sha, md5: md5, duration: item.duration, startTime: item.startTime)
            // Validate even cached records against the current queue, without resigning them.
            let payload = try MediaRecords.Record.manifest(manifest).encoded()
            guard (kind == .photo) == (objectKind == .photo) else { throw MediaRecords.failure("Saved fragment has the wrong kind") }
            total += Int64(item.size)
            guard total <= MediaRecords.maxCapture else { throw MediaRecords.failure("Recording exceeds sharing allowance") }
            if let old = state.manifests[item.sequence] {
                guard try old.bytes == payload else { throw MediaRecords.failure("Previously shared fragment changed") }
            } else {
                guard state.completion == nil else { throw MediaRecords.failure("Recording already ended") }
                try verifyBytes(queue.file(item), manifest: manifest)
                let signed = try MediaRecords.sign(.manifest(manifest), with: identity)
                try save(signed, name: "object-\(item.sequence)", captureId: captureId)
                state.manifests[item.sequence] = signed
                states[captureId] = state
            }
        }
        let last = items[items.count - 1]
        guard items.dropLast().allSatisfy({ $0.terminal == nil }) else { throw MediaRecords.failure("Fragment follows recording ending") }
        let ending: MediaRecords.Ending?
        if let terminal = last.terminal {
            guard terminal.objectCount == items.count, Int64(terminal.totalBytes) == total else { throw MediaRecords.failure("Recording ending changed") }
            ending = terminal.ending == .stopped ? .stopped : .interrupted
        } else { ending = kind == .photo ? .stopped : nil }
        if let ending {
            let completion = MediaRecords.Completion(descriptorHash: state.capture.digest, ending: ending,
                lastSequence: last.sequence, objectCount: items.count, totalBytes: total)
            if let old = state.completion {
                guard try state.capture.completion(old) == completion else { throw MediaRecords.failure("Conflicting recording ending") }
            } else {
                let signed = try MediaRecords.sign(.completion(completion), with: identity)
                try save(signed, name: "completion", captureId: captureId); state.completion = signed
                states[captureId] = state
            }
        } else if state.completion != nil { throw MediaRecords.failure("Saved recording ending is missing") }
        var grants: [String: MediaRecords.Envelope] = [:]
        for approval in approvals {
            for id in state.grants.keys.sorted() {
                let signed = state.grants[id]!
                if let grant = try? state.capture.grant(signed, approval: approval), (try? grant.checkTime(now)) != nil {
                    grants[approval.id] = signed; break
                }
            }
            if grants[approval.id] == nil {
                guard state.grants.count < 4096 else { throw MediaRecords.failure("Too many sharing permissions") }
                let grant = MediaRecords.Grant(id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""),
                    descriptorHash: state.capture.digest, senderDeviceId: device.id, recipientAccountId: approval.recipient.accountId,
                    recipientDeviceId: approval.recipient.id, approvalId: approval.id, issuedAt: now,
                    expiresAt: now + MediaRecords.grantLifetime, byteLimit: kind == .photo ? total : MediaRecords.maxCapture)
                let signed = try MediaRecords.sign(.grant(grant), with: identity)
                _ = try state.capture.grant(signed, approval: approval)
                try save(signed, name: "grant-" + grant.id, captureId: captureId)
                state.grants[grant.id] = signed; grants[approval.id] = signed
                states[captureId] = state
            }
        }
        states[captureId] = state
        // Disk work can outlast a user revocation or capture deletion.
        let current = await peers.snapshot()
        guard healthy, current.accessActive, approvals.allSatisfy({ approval in
            current.approvals.contains { $0.id == approval.id && $0.sender == approval.sender && $0.recipient == approval.recipient }
        }) else { throw MediaRecords.failure("Sharing permission changed") }
        let retained = queue.retainedObjects(accountId: device.accountId, captureId: captureId)
        guard Set(items.map(\.id)).isSubset(of: Set(retained.map(\.id))) else { states[captureId] = nil; return nil }
        return Prepared(descriptor: state.capture.envelope, grants: grants,
            objects: items.map { Object(manifest: state.manifests[$0.sequence]!, file: queue.file($0)) }, completion: state.completion)
    }

    private func load(_ captureId: String, descriptor: MediaRecords.Descriptor) throws -> State {
        if let state = states[captureId] {
            guard state.capture.descriptor == descriptor else { throw MediaRecords.failure("Recorder metadata changed") }
            return state
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var directory = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let folder = root.appendingPathComponent(captureId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        try syncDirectory(root)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard files.count <= MediaRecords.maxSequence + 4099 else { throw MediaRecords.failure("Too many saved records") }
        for file in files where file.lastPathComponent.hasPrefix(".tmp-") { try FileManager.default.removeItem(at: file) }
        let descriptorFile = folder.appendingPathComponent("descriptor.json")
        let envelope: MediaRecords.Envelope
        if FileManager.default.fileExists(atPath: descriptorFile.path) { envelope = try read(descriptorFile) }
        else {
            guard files.allSatisfy({ $0.lastPathComponent.hasPrefix(".tmp-") }) else { throw MediaRecords.failure("Saved recorder metadata is missing") }
            envelope = try MediaRecords.sign(.descriptor(descriptor), with: identity)
            _ = try MediaRecords.Capture(envelope, recorder: device)
            try save(envelope, name: "descriptor", captureId: captureId)
        }
        let capture = try MediaRecords.Capture(envelope, recorder: device)
        guard capture.descriptor == descriptor else { throw MediaRecords.failure("Recorder metadata changed") }
        var state = State(capture: capture)
        for file in files where !file.lastPathComponent.hasPrefix(".tmp-") && file.lastPathComponent != "descriptor.json" {
            let signed = try read(file)
            let name: String
            switch try signed.verified(by: device) {
            case .manifest:
                let manifest = try capture.manifest(signed)
                state.manifests[manifest.sequence] = signed; name = "object-\(manifest.sequence)"
            case .grant(let grant):
                guard grant.descriptorHash == capture.digest, grant.senderDeviceId == device.id,
                      descriptor.kind != .photo || grant.byteLimit <= MediaRecords.maxObject else { throw MediaRecords.failure("Saved sharing permission changed") }
                state.grants[grant.id] = signed; name = "grant-" + grant.id
            case .completion:
                _ = try capture.completion(signed); state.completion = signed; name = "completion"
            default: throw MediaRecords.failure("Unexpected saved record")
            }
            guard file.lastPathComponent == name + ".json" else { throw MediaRecords.failure("Saved record has the wrong name") }
        }
        guard state.grants.count <= 4096 else { throw MediaRecords.failure("Too many saved permissions") }
        return state
    }
    private func read(_ url: URL) throws -> MediaRecords.Envelope {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: 2049) ?? Data()
        guard bytes.count <= 2048 else { throw MediaRecords.failure("Saved record is too large") }
        return try JSONDecoder().decode(MediaRecords.Envelope.self, from: bytes)
    }
    private func save(_ envelope: MediaRecords.Envelope, name: String, captureId: String) throws {
        let folder = root.appendingPathComponent(captureId, isDirectory: true)
        let temporary = folder.appendingPathComponent(".tmp-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try JSONEncoder().encode(envelope).write(to: temporary, options: [.completeFileProtection])
            let file = try FileHandle(forWritingTo: temporary)
            do { try file.synchronize(); try file.close() } catch { try? file.close(); throw error }
            try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent(name + ".json"))
            try syncDirectory(folder)
        } catch {
            // Reopen and read the first persisted signature after any uncertain write.
            healthy = false; throw error
        }
    }
    private func verifyBytes(_ url: URL, manifest: MediaRecords.Manifest) throws {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var sha = SHA256(), md5 = Insecure.MD5(), count = 0
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            count += data.count
            guard count <= manifest.size else { throw MediaRecords.failure("Saved fragment length changed") }
            sha.update(data: data); md5.update(data: data)
        }
        guard count == manifest.size, Data(sha.finalize()) == manifest.sha256, Data(md5.finalize()) == manifest.md5 else {
            throw MediaRecords.failure("Saved fragment is corrupt")
        }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func unhex(_ value: String) -> Data? {
        let bytes = Array(value.utf8)
        var data = Data()
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let byte = UInt8(String(decoding: bytes[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return hex(data) == value ? data : nil
    }
}

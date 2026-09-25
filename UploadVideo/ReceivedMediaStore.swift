import Foundation
import CryptoKit
import Darwin

// Stores received copies separately from the owner's upload queue. No network I/O
// or caller-supplied path is involved in publishing a durable receipt.
actor ReceivedMediaStore {
    struct Receipt: Codable, Equatable, Sendable {
        let recorderAccountId: String
        let captureId: String
        let sequence: Int
        let sha256: Data
        let size: Int
    }
    enum Admission: Sendable { case saved(Receipt), writing(UUID) }
    struct SavedObject: Sendable {
        let descriptor: MediaRecords.Envelope
        let manifest: MediaRecords.Envelope
        let recorder: RegisteredDevice
        let file: URL
    }
    private struct Authorization: Codable {
        let descriptor: MediaRecords.Envelope
        let grant: MediaRecords.Envelope
        let approval: PeerApproval
    }
    private struct Metadata: Codable {
        let descriptor: MediaRecords.Envelope
        let manifest: MediaRecords.Envelope
        let recorder: RegisteredDevice
    }
    private struct Entry {
        let metadata: Metadata
        let manifest: MediaRecords.Manifest
        let receipt: Receipt
    }
    private struct Incoming {
        let metadata: Metadata
        let manifest: MediaRecords.Manifest
        let authorization: Authorization
        let folder: URL
        let file: FileHandle
        let reservation: UUID?
        var written = 0
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var finishing = false
    }
    private let root: URL
    private let budget: MediaStorageBudget?
    let peers: PeerStore
    private let device: RegisteredDevice
    private var loaded = false
    private var healthy = true
    private var entries: [String: Entry] = [:]
    private var grants: [String: Authorization] = [:]
    private var captureBindings: [String: Data] = [:]
    private var endings: [String: MediaRecords.Envelope] = [:]
    private var cloudObjects: Set<String> = []
    private var cloudComplete: Set<String> = []
    private var deleted: Set<String> = []
    private var pending: [UUID: Incoming] = [:]
    private var used = 0
    private let limit = 1024 * 1024 * 1024
    private let controlLimit = 8192

    init(peers: PeerStore, root: URL? = nil, budget: MediaStorageBudget? = nil) throws {
        self.budget = budget
        self.peers = peers; device = peers.device
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true).appendingPathComponent("ReceivedMedia", isDirectory: true)
        let scope = Data((peers.baseURL.absoluteString + "\n" + device.accountId + "\n" + device.id).utf8)
        self.root = base.appendingPathComponent(Self.hex(Data(SHA256.hash(data: scope))), isDirectory: true)
    }

    func begin(descriptor: MediaRecords.Envelope, grant: MediaRecords.Envelope, manifest: MediaRecords.Envelope,
               sender: RegisteredDevice, now: Int64 = Int64(Date().timeIntervalSince1970)) async throws -> Admission {
        try restore()
        let snapshot = await peers.snapshot()
        try restore() // A different receive may have failed while authorization yielded.
        guard let approval = snapshot.approvals.first(where: { $0.sender == sender && $0.recipient == device }) else {
            throw MediaRecords.failure("Sender is not approved")
        }
        let authorization = Authorization(descriptor: descriptor, grant: grant, approval: approval)
        let (capture, permission) = try verify(authorization)
        guard !deleted.contains(Self.hex(capture.digest)) else { throw APIError(status: 410, message: "Copy removed from this phone") }
        try permission.checkTime(now)
        try capture.checkTime(now)
        let object = try capture.manifest(manifest)
        guard object.size <= permission.byteLimit else { throw MediaRecords.failure("Sharing allowance exceeded") }
        let key = Self.key(capture.digest, object.sequence)
        let metadata = Metadata(descriptor: descriptor, manifest: manifest, recorder: sender)
        try checkEnding(object, capture: capture)
        let existingBytes = entries.values.filter { $0.manifest.descriptorHash == capture.digest }.reduce(0) { $0 + $1.manifest.size }
        let inFlightBytes = pending.values.filter { $0.manifest.descriptorHash == capture.digest }.reduce(0) { $0 + $1.manifest.size }
        guard Int64(existingBytes + inFlightBytes + (entries[key] == nil ? object.size : 0)) <= permission.byteLimit else {
            throw MediaRecords.failure("Sharing allowance exceeded")
        }
        // Save renewed permission even when this exact object is already present.
        try saveGrant(authorization, id: permission.id)
        if let existing = entries[key] {
            guard existing.manifest == object else { throw MediaRecords.failure("Conflicting received object") }
            try verifyBytes(folder: root.appendingPathComponent(key), object: object)
            return .saved(existing.receipt)
        }
        guard pending.count < 2, entries.count < 100_000,
              !pending.values.contains(where: { Self.key($0.manifest.descriptorHash, $0.manifest.sequence) == key }) else {
            throw MediaRecords.failure("Receiver is busy")
        }
        try checkSpace(object.size + controlLimit)
        let reservation = try budget?.reserve(object.size + controlLimit, area: .received)
        let id = UUID(), folder = root.appendingPathComponent(".tmp-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.protectionKey: FileProtectionType.complete])
            try Data().write(to: folder.appendingPathComponent("media"), options: [.completeFileProtection])
            let file = try FileHandle(forWritingTo: folder.appendingPathComponent("media"))
            pending[id] = Incoming(metadata: metadata, manifest: object, authorization: authorization, folder: folder, file: file, reservation: reservation)
        } catch { try? FileManager.default.removeItem(at: folder); try? budget?.finish(reservation, paths: [folder]); throw error }
        return .writing(id)
    }
    func append(_ data: Data, to id: UUID) throws {
        guard healthy, var item = pending[id], !item.finishing else { throw MediaRecords.failure("No incoming object") }
        guard !data.isEmpty, data.count <= 65_536, data.count <= item.manifest.size - item.written else {
            abort(id); throw MediaRecords.failure("Invalid media chunk")
        }
        do { try item.file.write(contentsOf: data) }
        catch { abort(id); throw error }
        item.sha.update(data: data); item.md5.update(data: data); item.written += data.count
        pending[id] = item
    }
    func commit(_ id: UUID, now: Int64 = Int64(Date().timeIntervalSince1970)) async throws -> Receipt {
        guard healthy, var item = pending[id], !item.finishing else { throw MediaRecords.failure("No incoming object") }
        item.finishing = true; pending[id] = item
        var published = false
        do {
            let snapshot = await peers.snapshot()
            guard healthy, pending[id] != nil, snapshot.approvals.contains(where: { $0.samePermission(as: item.authorization.approval) }) else { throw MediaRecords.failure("Sharing approval was removed") }
            let (capture, grant) = try verify(item.authorization)
            try grant.checkTime(now)
            try checkEnding(item.manifest, capture: capture)
            guard item.written == item.manifest.size, Data(item.sha.finalize()) == item.manifest.sha256,
                  Data(item.md5.finalize()) == item.manifest.md5 else { throw MediaRecords.failure("Received media failed integrity check") }
            try item.file.synchronize(); try item.file.close()
            let metadata = try JSONEncoder().encode(item.metadata)
            try writeControl(metadata, to: item.folder.appendingPathComponent("record.json"))
            try syncDirectory(item.folder)
            let key = Self.key(capture.digest, item.manifest.sequence)
            try FileManager.default.moveItem(at: item.folder, to: root.appendingPathComponent(key))
            published = true
            try syncDirectory(root)
            try budget?.finish(item.reservation, paths: [item.folder, root.appendingPathComponent(key)])
            let receipt = Receipt(recorderAccountId: capture.descriptor.recorderAccountId, captureId: capture.descriptor.captureId,
                                  sequence: item.manifest.sequence, sha256: item.manifest.sha256, size: item.manifest.size)
            entries[key] = Entry(metadata: item.metadata, manifest: item.manifest, receipt: receipt)
            used += item.manifest.size + metadata.count; pending[id] = nil
            return receipt
        } catch {
            if published {
                pending[id] = nil
                try? budget?.finish(item.reservation, paths: [item.folder, root.appendingPathComponent(Self.key(item.manifest.descriptorHash, item.manifest.sequence))])
                invalidateStorage() // Reopen and revalidate a commit whose final sync failed.
            } else { abort(id) }
            throw error
        }
    }
    func abort(_ id: UUID) {
        guard let item = pending.removeValue(forKey: id) else { return }
        try? item.file.close(); try? FileManager.default.removeItem(at: item.folder)
        try? budget?.finish(item.reservation, paths: [item.folder])
    }
    func stop() { for id in Array(pending.keys) { abort(id) } }
    private func invalidateStorage() { healthy = false; stop() }

    func inventory(captureHash: Data) throws -> [Receipt] {
        try restore()
        return entries.values.filter { $0.manifest.descriptorHash == captureHash }.map(\.receipt).sorted { $0.sequence < $1.sequence }
    }
    func authorize(descriptor: MediaRecords.Envelope, grant: MediaRecords.Envelope, sender: RegisteredDevice) async throws -> Data {
        try restore()
        let snapshot = await peers.snapshot()
        try restore()
        guard let approval = snapshot.approvals.first(where: { $0.sender == sender && $0.recipient == device }) else {
            throw MediaRecords.failure("Sender is not approved")
        }
        let auth = Authorization(descriptor: descriptor, grant: grant, approval: approval)
        let (capture, permission) = try verify(auth)
        guard !deleted.contains(Self.hex(capture.digest)) else { throw APIError(status: 410, message: "Copy removed from this phone") }
        let now = Int64(Date().timeIntervalSince1970)
        try capture.checkTime(now); try permission.checkTime(now)
        try saveGrant(auth, id: permission.id)
        return capture.digest
    }
    func savedObject(captureHash: Data, sequence: Int) throws -> SavedObject? {
        try restore()
        let key = Self.key(captureHash, sequence)
        guard let entry = entries[key] else { return nil }
        try verifyBytes(folder: root.appendingPathComponent(key), object: entry.manifest)
        return SavedObject(descriptor: entry.metadata.descriptor, manifest: entry.metadata.manifest, recorder: entry.metadata.recorder,
                           file: root.appendingPathComponent(key).appendingPathComponent("media"))
    }
    func relayGrants(captureHash: Data, now: Int64 = Int64(Date().timeIntervalSince1970)) async throws -> [MediaRecords.Envelope] {
        try restore()
        let snapshot = await peers.snapshot()
        try restore()
        return try grants.values.filter { auth in
            let (capture, grant) = try verify(auth)
            return capture.digest == captureHash && (try? grant.checkTime(now)) != nil && snapshot.approvals.contains {
                $0.id == auth.approval.id && $0.sender == auth.approval.sender && $0.recipient == device
            }
        }.map(\.grant)
    }
    func receiveCompletion(_ envelope: MediaRecords.Envelope, descriptor: MediaRecords.Envelope, grant: MediaRecords.Envelope,
                           sender: RegisteredDevice, now: Int64 = Int64(Date().timeIntervalSince1970)) async throws {
        try restore()
        let snapshot = await peers.snapshot()
        try restore()
        guard let approval = snapshot.approvals.first(where: { $0.sender == sender && $0.recipient == device }) else { throw MediaRecords.failure("Sender is not approved") }
        let auth = Authorization(descriptor: descriptor, grant: grant, approval: approval)
        let (capture, permission) = try verify(auth)
        guard !deleted.contains(Self.hex(capture.digest)) else { throw APIError(status: 410, message: "Copy removed from this phone") }
        try permission.checkTime(now)
        try capture.checkTime(now)
        let completion = try capture.completion(envelope)
        if let old = endings[Self.hex(capture.digest)] {
            guard try old.digest == envelope.digest else { throw MediaRecords.failure("Conflicting completion") }
            return
        }
        for item in entries.values where item.manifest.descriptorHash == capture.digest {
            guard item.manifest.sequence <= completion.lastSequence else { throw MediaRecords.failure("Completion excludes saved media") }
        }
        let known = entries.values.filter { $0.manifest.descriptorHash == capture.digest }
        let total = known.reduce(0) { $0 + $1.manifest.size }
        guard total <= completion.totalBytes,
              known.count != completion.objectCount || total == completion.totalBytes else { throw MediaRecords.failure("Completion byte count conflicts") }
        try saveGrant(auth, id: permission.id)
        let data = try JSONEncoder().encode(envelope)
        try checkSpace(data.count)
        do {
            try writeControl(data, to: root.appendingPathComponent("end-" + Self.hex(capture.digest) + ".json"))
            try syncDirectory(root)
        } catch { invalidateStorage(); throw error }
        endings[Self.hex(capture.digest)] = envelope; used += data.count
    }
    func completed(captureHash: Data) throws -> MediaRecords.Ending? {
        try restore()
        let items = entries.values.filter { $0.manifest.descriptorHash == captureHash }
        guard let first = items.first, let envelope = endings[Self.hex(captureHash)] else { return nil }
        let capture = try MediaRecords.Capture(first.metadata.descriptor, recorder: first.metadata.recorder)
        let ending = try capture.completion(envelope)
        guard items.count == ending.objectCount, items.reduce(0, { $0 + $1.manifest.size }) == ending.totalBytes,
              Set(items.map { $0.manifest.sequence }) == Set(0...ending.lastSequence) else { return nil }
        return ending.ending
    }

    private func verify(_ auth: Authorization) throws -> (MediaRecords.Capture, MediaRecords.Grant) {
        guard auth.approval.recipient == device else { throw MediaRecords.failure("Received permission belongs to another device") }
        let capture = try MediaRecords.Capture(auth.descriptor, recorder: auth.approval.sender)
        return (capture, try capture.grant(auth.grant, approval: auth.approval))
    }
    private func saveGrant(_ auth: Authorization, id: String) throws {
        let (capture, _) = try verify(auth)
        try checkBinding(capture)
        if let old = grants[id] {
            guard try old.grant.digest == auth.grant.digest else { throw MediaRecords.failure("Conflicting grant identifier") }
            return
        }
        guard grants.count < 4096 else { throw MediaRecords.failure("Too many saved sharing permissions") }
        let data = try JSONEncoder().encode(auth)
        try checkSpace(data.count)
        do {
            try writeControl(data, to: root.appendingPathComponent("grant-" + id + ".json"))
            try syncDirectory(root)
        } catch { invalidateStorage(); throw error }
        grants[id] = auth; used += data.count
        captureBindings[bindingKey(capture)] = capture.digest
    }
    private func bindingKey(_ capture: MediaRecords.Capture) -> String {
        capture.descriptor.recorderAccountId + "/" + capture.descriptor.captureId
    }
    private func checkBinding(_ capture: MediaRecords.Capture) throws {
        if let digest = captureBindings[bindingKey(capture)], digest != capture.digest { throw MediaRecords.failure("Conflicting capture descriptor") }
    }
    private func checkEnding(_ object: MediaRecords.Manifest, capture: MediaRecords.Capture) throws {
        guard let envelope = endings[Self.hex(capture.digest)] else { return }
        let ending = try capture.completion(envelope)
        let others = entries.values.filter { $0.manifest.descriptorHash == capture.digest && $0.manifest.sequence != object.sequence }
        let total = others.reduce(object.size) { $0 + $1.manifest.size }
        guard object.sequence <= ending.lastSequence, total <= ending.totalBytes,
              others.count + 1 != ending.objectCount || total == ending.totalBytes else { throw MediaRecords.failure("Object conflicts with completion") }
    }
    private func restore() throws {
        guard healthy else { throw MediaRecords.failure("Reopen received media to recover storage") }
        if loaded { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var directory = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count <= 108_194 else { throw MediaRecords.failure("Received media index is too large") }
        // Only rebuild once. A partial restore must not publish a partial inventory.
        do {
            var captures: [String: MediaRecords.Capture] = [:]
            for url in files where url.lastPathComponent.hasPrefix(".tmp-") { try FileManager.default.removeItem(at: url) }
            for url in files where url.lastPathComponent.hasPrefix("deleted-") {
                let data = try control(url), hash = try JSONDecoder().decode(Data.self, from: data)
                guard hash.count == 32, url.lastPathComponent == "deleted-" + Self.hex(hash) + ".json" else { throw MediaRecords.failure("Invalid local deletion") }
                deleted.insert(Self.hex(hash))
                used += data.count
            }
            for url in files where url.lastPathComponent.hasPrefix("grant-") {
                let data = try control(url), auth = try JSONDecoder().decode(Authorization.self, from: data)
                let (capture, grant) = try verify(auth)
                if deleted.contains(Self.hex(capture.digest)) { try FileManager.default.removeItem(at: url); continue }
                try checkBinding(capture)
                guard url.lastPathComponent == "grant-" + grant.id + ".json", grants.count < 4096 else { throw MediaRecords.failure("Invalid saved permission") }
                grants[grant.id] = auth; used += data.count
                captureBindings[bindingKey(capture)] = capture.digest
                captures[Self.hex(capture.digest)] = capture
            }
            for url in files where url.lastPathComponent.hasPrefix("end-") {
                let data = try control(url), envelope = try JSONDecoder().decode(MediaRecords.Envelope.self, from: data)
                let key = String(url.lastPathComponent.dropFirst(4).dropLast(5))
                if deleted.contains(key) { try FileManager.default.removeItem(at: url); continue }
                guard let capture = captures[key], url.lastPathComponent == "end-" + key + ".json" else {
                    throw MediaRecords.failure("Completion has no saved permission")
                }
                _ = try capture.completion(envelope)
                endings[Self.hex(capture.digest)] = envelope; used += data.count
            }
            for folder in files where !folder.lastPathComponent.hasPrefix(".tmp-") && !folder.lastPathComponent.hasPrefix("grant-") && !folder.lastPathComponent.hasPrefix("end-") && !folder.lastPathComponent.hasPrefix("deleted-") {
                if deleted.contains(String(folder.lastPathComponent.prefix(64))) { try FileManager.default.removeItem(at: folder); continue }
                let data = try control(folder.appendingPathComponent("record.json")), metadata = try JSONDecoder().decode(Metadata.self, from: data)
                let capture = try MediaRecords.Capture(metadata.descriptor, recorder: metadata.recorder), object = try capture.manifest(metadata.manifest)
                guard folder.lastPathComponent == Self.key(capture.digest, object.sequence), entries.count < 100_000,
                      captures[Self.hex(capture.digest)]?.recorder == metadata.recorder else { throw MediaRecords.failure("Saved media is outside its permission") }
                try verifyBytes(folder: folder, object: object)
                try checkEnding(object, capture: capture)
                let receipt = Receipt(recorderAccountId: capture.descriptor.recorderAccountId, captureId: capture.descriptor.captureId,
                                      sequence: object.sequence, sha256: object.sha256, size: object.size)
                entries[folder.lastPathComponent] = Entry(metadata: metadata, manifest: object, receipt: receipt)
                used += object.size + data.count
                let cloud = folder.appendingPathComponent("cloud.json")
                if FileManager.default.fileExists(atPath: cloud.path) {
                    let marker = try control(cloud)
                    guard try JSONDecoder().decode(Data.self, from: marker) == metadata.manifest.digest else { throw MediaRecords.failure("Invalid cloud acknowledgement") }
                    cloudObjects.insert(folder.lastPathComponent); used += marker.count
                }
            }
            guard used <= limit else { throw MediaRecords.failure("Received media exceeds storage limit") }
            loaded = true
            try budget?.reconcile(root)
        } catch { healthy = false; throw error }
    }
    private func checkSpace(_ additional: Int) throws {
        guard healthy else { throw MediaRecords.failure("Reopen received media to recover storage") }
        let reserved = pending.values.reduce(0) { $0 + $1.manifest.size + controlLimit }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard used + reserved + additional <= limit, free >= Int64(additional + reserved + 100 * 1024 * 1024) else {
            throw APIError(status: 413, message: "Received media storage is full")
        }
    }
    private func control(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: controlLimit + 1) ?? Data()
        guard bytes.count <= controlLimit else { throw MediaRecords.failure("Saved record is too large") }
        return bytes
    }
    private func writeControl(_ data: Data, to url: URL) throws {
        guard data.count <= controlLimit else { throw MediaRecords.failure("Signed metadata is too large") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        // Object metadata is already covered by its full in-flight reservation.
        let objectMetadata = url.lastPathComponent == "record.json"
        let reservation = objectMetadata ? nil : try budget?.reserve(data.count, area: .received)
        defer { if !objectMetadata { try? budget?.finish(reservation, paths: [temporary, url]) } }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.completeFileProtection])
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
    private func verifyBytes(folder: URL, object: MediaRecords.Manifest) throws {
        let file = try FileHandle(forReadingFrom: folder.appendingPathComponent("media")); defer { try? file.close() }
        var sha = SHA256(), md5 = Insecure.MD5(), count = 0
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            count += data.count
            guard count <= object.size else { throw MediaRecords.failure("Saved media length changed") }
            sha.update(data: data); md5.update(data: data)
        }
        guard count == object.size, Data(sha.finalize()) == object.sha256, Data(md5.finalize()) == object.md5 else { throw MediaRecords.failure("Saved media is corrupt") }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func key(_ hash: Data, _ sequence: Int) -> String { hex(hash) + "-" + String(sequence) }
}

extension ReceivedMediaStore {
    struct Playback: Sendable {
        let manifests: [MediaRecords.Manifest]
        let ended: Bool
    }
    func playback(captureHash: Data) throws -> Playback {
        try restore()
        guard !deleted.contains(Self.hex(captureHash)) else { throw CancellationError() }
        let objects = entries.values.filter { $0.manifest.descriptorHash == captureHash }.map(\.manifest).sorted { $0.sequence < $1.sequence }
        let prefix = objects.enumerated().prefix { $0.offset == $0.element.sequence }.map(\.element)
        return Playback(manifests: prefix, ended: try completed(captureHash: captureHash) != nil)
    }
    struct CaptureInfo: Identifiable, Equatable, Sendable {
        let id: String
        let hash: Data
        let recorderName: String
        let local: LocalCapture
        let savedObjects: Int
        let cloudObjects: Int
        let expectedObjects: Int?
        let complete: Bool
        let cloudComplete: Bool
        let ending: String
    }
    struct RelayMaterial: Sendable {
        let descriptor: MediaRecords.Envelope
        let grant: MediaRecords.Envelope
        let permission: MediaRecords.Grant
        let object: SavedObject?
        let sequence: Int?
        let completion: MediaRecords.Envelope?
    }
    func captures() throws -> [CaptureInfo] {
        try restore()
        return try Dictionary(grouping: entries.values.filter { !deleted.contains(Self.hex($0.manifest.descriptorHash)) }, by: { Self.hex($0.manifest.descriptorHash) }).map { hash, items in
            let sorted = items.sorted { $0.manifest.sequence < $1.manifest.sequence }
            let first = sorted[0], capture = try MediaRecords.Capture(first.metadata.descriptor, recorder: first.metadata.recorder)
            let prefix = sorted.enumerated().prefix { $0.offset == $0.element.manifest.sequence }.map(\.element)
            let ending = try endings[hash].map { try capture.completion($0) }
            let complete = try completed(captureHash: capture.digest) != nil
            let cloudCount = sorted.filter { cloudObjects.contains(Self.key(capture.digest, $0.manifest.sequence)) }.count
            let name = grants.values.first { $0.approval.sender == capture.recorder }?.approval.senderName ?? ""
            let local = LocalCapture(id: capture.descriptor.captureId, accountId: capture.recorder.accountId,
                kind: capture.descriptor.kind == .photo ? "photo" : "video", createdAt: Date(timeIntervalSince1970: Double(capture.descriptor.createdAt)),
                duration: prefix.reduce(0) { $0 + $1.manifest.duration }, uploaded: cloudComplete.contains(hash),
                playable: capture.descriptor.kind == .photo ? !prefix.isEmpty : prefix.count > 1,
                parts: prefix.map { root.appendingPathComponent(Self.key(capture.digest, $0.manifest.sequence)).appendingPathComponent("media") })
            return CaptureInfo(id: hash, hash: capture.digest, recorderName: name.isEmpty ? "Nearby recorder" : name,
                local: local, savedObjects: items.count, cloudObjects: cloudCount, expectedObjects: ending?.objectCount,
                complete: complete, cloudComplete: cloudComplete.contains(hash), ending: ending.map { $0.ending == .stopped ? "stopped" : "interrupted" } ?? "unknown")
        }.sorted { $0.local.createdAt > $1.local.createdAt }
    }
    func relayMaterial(captureHash: Data) async throws -> RelayMaterial? {
        let active = try await relayGrants(captureHash: captureHash)
        guard let envelope = active.first, let auth = grants.values.first(where: { $0.grant == envelope }) else { return nil }
        let (capture, permission) = try verify(auth)
        guard !deleted.contains(Self.hex(captureHash)) else { return nil }
        let entry = entries.values.filter { $0.manifest.descriptorHash == captureHash && !cloudObjects.contains(Self.key(captureHash, $0.manifest.sequence)) }
            .min { $0.manifest.sequence < $1.manifest.sequence }
        let object = try entry.flatMap { try savedObject(captureHash: captureHash, sequence: $0.manifest.sequence) }
        return RelayMaterial(descriptor: capture.envelope, grant: envelope, permission: permission, object: object,
            sequence: entry?.manifest.sequence, completion: endings[Self.hex(captureHash)])
    }
    func markCloudObject(captureHash: Data, sequence: Int) throws {
        try restore()
        let key = Self.key(captureHash, sequence)
        guard let entry = entries[key], !deleted.contains(Self.hex(captureHash)) else { throw CancellationError() }
        if cloudObjects.contains(key) { return }
        let folder = root.appendingPathComponent(key)
        let data = try JSONEncoder().encode(entry.metadata.manifest.digest)
        try checkSpace(data.count)
        do { try writeControl(data, to: folder.appendingPathComponent("cloud.json")); try syncDirectory(folder) }
        catch { invalidateStorage(); throw error }
        cloudObjects.insert(key); used += data.count
    }
    func markCloudComplete(captureHash: Data, complete: Bool) {
        let key = Self.hex(captureHash)
        if complete && !deleted.contains(key) { cloudComplete.insert(key) } else { cloudComplete.remove(key) }
    }
    func completion(captureHash: Data) throws -> MediaRecords.Envelope? { try restore(); return endings[Self.hex(captureHash)] }
    func remove(captureHash: Data) throws {
        try restore()
        var succeeded = false
        defer { if !succeeded { invalidateStorage() } }
        guard captureHash.count == 32 else { throw MediaRecords.failure("Invalid capture") }
        let hash = Self.hex(captureHash)
        if !deleted.contains(hash) {
            let tombstone = root.appendingPathComponent("deleted-" + hash + ".json")
            try writeControl(JSONEncoder().encode(captureHash), to: tombstone); try syncDirectory(root)
            deleted.insert(hash)
        }
        for (id, item) in pending where item.manifest.descriptorHash == captureHash { abort(id) }
        // The durable local tombstone also lets reopen finish any interrupted deletion.
        for (id, auth) in grants where (try auth.descriptor.digest) == captureHash {
            let url = root.appendingPathComponent("grant-" + id + ".json")
            try FileManager.default.removeItem(at: url); grants[id] = nil
        }
        let end = root.appendingPathComponent("end-" + hash + ".json")
        if FileManager.default.fileExists(atPath: end.path) { try FileManager.default.removeItem(at: end) }
        for (key, entry) in entries where entry.manifest.descriptorHash == captureHash {
            try FileManager.default.removeItem(at: root.appendingPathComponent(key)); entries[key] = nil; cloudObjects.remove(key)
        }
        endings[hash] = nil; cloudComplete.remove(hash)
        try syncDirectory(root)
        // Rebuild counters from the remaining committed metadata, without hashing media again.
        used = 0
        for (key, entry) in entries {
            let folder = root.appendingPathComponent(key)
            used += entry.manifest.size + (try control(folder.appendingPathComponent("record.json"))).count
            if cloudObjects.contains(key) { used += (try control(folder.appendingPathComponent("cloud.json"))).count }
        }
        for id in grants.keys { used += (try control(root.appendingPathComponent("grant-" + id + ".json"))).count }
        for id in endings.keys { used += (try control(root.appendingPathComponent("end-" + id + ".json"))).count }
        for id in deleted { used += (try control(root.appendingPathComponent("deleted-" + id + ".json"))).count }
        try budget?.reconcile(root)
        succeeded = true
    }
}

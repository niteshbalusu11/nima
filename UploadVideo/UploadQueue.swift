import Foundation
import CryptoKit

struct QueuedObject: Codable, Sendable, Identifiable {
    let id: UUID
    let accountId: String
    let captureId: String
    let captureKind: String
    let sequence: Int
    let kind: String
    let sha256: String
    let md5: String
    let size: Int
    let duration: Double
    let startTime: Double
    let createdAt: Date
    var acknowledged: Bool
    var reservation: Data {
        get throws {
            struct Body: Encodable {
                let sequence: Int; let kind: String; let sha256: String; let md5: String
                let size: Int; let duration: Double; let startTime: Double
            }
            return try API.encode(Body(sequence: sequence, kind: kind, sha256: sha256, md5: md5,
                                       size: size, duration: duration, startTime: startTime))
        }
    }
}

// Disk and in-memory metadata share this lock. No network operation holds it.
final class UploadQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var items: [QueuedObject] = []
    private var bytes = 0
    static let limit = 256 * 1024 * 1024
    init(root: URL? = nil) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true).appendingPathComponent("PendingMedia")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var directory = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        for folder in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
            if folder.lastPathComponent.hasPrefix(".tmp-") { try FileManager.default.removeItem(at: folder); continue }
            let item = try JSONDecoder().decode(QueuedObject.self, from: Data(contentsOf: folder.appendingPathComponent("item.json")))
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("media").path) else {
                throw APIError(status: 0, message: "Saved media is missing")
            }
            items.append(item); bytes += item.size
        }
        items.sort { $0.createdAt < $1.createdAt }
    }
    func checkSpace() throws {
        lock.lock(); defer { lock.unlock() }
        try checkSpaceLocked(additional: 12 * 1024 * 1024)
    }
    private func checkSpaceLocked(additional: Int) throws {
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        if bytes + additional > Self.limit || capacity < Int64(additional + 100 * 1024 * 1024) {
            throw APIError(status: 413, message: "Storage full")
        }
    }
    func enqueue(_ data: Data, accountId: String, captureId: String, captureKind: String,
                 sequence: Int, kind: String, duration: Double = 0, startTime: Double = 0) throws {
        lock.lock(); defer { lock.unlock() }
        try checkSpaceLocked(additional: data.count)
        let item = QueuedObject(id: UUID(), accountId: accountId, captureId: captureId, captureKind: captureKind,
                                sequence: sequence, kind: kind,
                                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                md5: Data(Insecure.MD5.hash(data: data)).base64EncodedString(), size: data.count,
                                duration: duration.isFinite ? duration : 0, startTime: startTime.isFinite ? max(0, startTime) : 0,
                                createdAt: Date(), acknowledged: false)
        let staging = root.appendingPathComponent(".tmp-\(item.id.uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try data.write(to: staging.appendingPathComponent("media"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.moveItem(at: staging, to: folder(item))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        items.append(item); bytes += data.count
    }
    func next(accountId: String, captureKind: String) -> QueuedObject? {
        lock.lock(); defer { lock.unlock() }
        // Serial per media type keeps init ahead of its video fragments, and reserves a worker for photos.
        return items.first { $0.accountId == accountId && $0.captureKind == captureKind && !$0.acknowledged }
    }
    func pending(accountId: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.accountId == accountId && !$0.acknowledged }.count
    }
    func file(_ item: QueuedObject) -> URL { folder(item).appendingPathComponent("media") }
    private func folder(_ item: QueuedObject) -> URL { root.appendingPathComponent(item.id.uuidString) }
    func acknowledge(_ item: QueuedObject) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items[index]; updated.acknowledged = true
        try JSONEncoder().encode(updated).write(to: folder(item).appendingPathComponent("item.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        items[index] = updated
    }
}

struct UploadWorker: Sendable {
    let api: API
    let queue: UploadQueue
    let accountId: String
    func send(_ item: QueuedObject) async throws {
        struct Capture: Encodable { let kind: String }
        let _: OK = try await api.request("PUT", "captures/\(item.captureId)", body: API.encode(Capture(kind: item.captureKind)))
        struct Reservation: Decodable, Sendable { let acknowledged: Bool; let url: String?; let headers: [String: String]? }
        let signed: Reservation = try await api.request("POST", "captures/\(item.captureId)/objects/reserve", body: item.reservation)
        if !signed.acknowledged {
            guard let value = signed.url, let url = URL(string: value) else { throw URLError(.badURL) }
            #if !DEBUG
            guard url.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
            #endif
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"; request.timeoutInterval = 30
            for (name, value) in signed.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            let (_, response) = try await URLSession.shared.upload(for: request, fromFile: queue.file(item))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            // A repeated conditional PUT is expected to return 412; /ack verifies the original bytes.
            guard (200..<300).contains(http.statusCode) || http.statusCode == 412 else {
                throw APIError(status: http.statusCode == 401 ? 503 : http.statusCode, message: "Upload paused")
            }
            struct Ack: Encodable { let sequence: Int }
            let _: OK = try await api.request("POST", "captures/\(item.captureId)/objects/ack", body: API.encode(Ack(sequence: item.sequence)))
        }
        try queue.acknowledge(item)
    }
}

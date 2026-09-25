import Foundation

// One instance owns the app's entire Application Support media budget, across
// accounts and stores. Reservations are shared even while files are still staging.
final class MediaStorageBudget: @unchecked Sendable {
    enum Area: Sendable { case owner, received }
    private struct Allocation { let bytes: Int; let area: Area }
    private let lock = NSLock()
    private let root: URL
    private let limit: Int
    private let receivedLimit: Int
    private var files: [String: Allocation] = [:]
    private var reservations: [UUID: Allocation] = [:]
    private var used = 0
    private var received = 0

    init(root: URL, limit: Int = 3 * 1024 * 1024 * 1024, receivedLimit: Int = 1024 * 1024 * 1024) throws {
        self.root = root; self.limit = limit; self.receivedLimit = receivedLimit
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["PendingMedia", "ReceivedMedia", "SharedMediaRecords"] {
            try reconcile(root.appendingPathComponent(name, isDirectory: true))
        }
    }
    func reserve(_ bytes: Int, area: Area) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let reserved = reservations.values.reduce(0) { $0 + $1.bytes }
        let incoming = reservations.values.filter { $0.area == .received }.reduce(0) { $0 + $1.bytes }
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard bytes > 0, bytes <= limit, used + reserved + bytes <= limit,
              area != .received || received + incoming + bytes <= receivedLimit,
              free >= Int64(reserved + bytes + 100 * 1024 * 1024) else { throw APIError(status: 413, message: "Storage full") }
        let id = UUID(); reservations[id] = Allocation(bytes: bytes, area: area); return id
    }
    // Reconcile both old/new paths after a rename, or any partial files left by a
    // failed removal. A filesystem error keeps the reservation conservatively.
    func finish(_ reservation: UUID?, paths: [URL]) throws {
        lock.lock(); defer { lock.unlock() }
        var updates: [(URL, [String: Allocation])] = []
        for path in paths { updates.append((path, try sizes(path))) }
        for (path, replacements) in updates {
            let prefix = path.standardizedFileURL.path
            for key in Array(files.keys) where key == prefix || key.hasPrefix(prefix + "/") {
                let old = files.removeValue(forKey: key)!; used -= old.bytes
                if old.area == .received { received -= old.bytes }
            }
            for (key, value) in replacements {
                files[key] = value; used += value.bytes
                if value.area == .received { received += value.bytes }
            }
        }
        if let reservation { reservations[reservation] = nil }
    }
    func reconcile(_ path: URL) throws { try finish(nil, paths: [path]) }
    private func sizes(_ path: URL) throws -> [String: Allocation] {
        let prefix = root.standardizedFileURL.path + "/"
        guard path.standardizedFileURL.path.hasPrefix(prefix) else { throw APIError(status: 0, message: "Media is outside storage budget") }
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        let properties = try path.resourceValues(forKeys: keys)
        var urls = [path]
        if properties.isDirectory == true {
            var failure: Error?
            guard let iterator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in failure = error; return false }) else {
                throw APIError(status: 0, message: "Could not inspect saved media")
            }
            urls = iterator.allObjects.compactMap { $0 as? URL }
            if let failure { throw failure }
        }
        var result: [String: Allocation] = [:]
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            if values.isRegularFile == true, let size = values.fileSize {
                let area: Area = url.standardizedFileURL.path.hasPrefix(root.appendingPathComponent("ReceivedMedia").standardizedFileURL.path + "/") ? .received : .owner
                result[url.standardizedFileURL.path] = Allocation(bytes: size, area: area)
            }
        }
        return result
    }
}

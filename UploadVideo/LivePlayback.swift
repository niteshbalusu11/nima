import Foundation
@preconcurrency import Network

// AVPlayer reads an EVENT playlist of already verified fragments. No appended
// MP4 assumptions, remote listener, path traversal, or bytes beyond a local gap.
@MainActor
final class LivePlayback {
    private var listener: NWListener?
    private var channels: [UUID: NearbyChannel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ready: CheckedContinuation<URL, Error>?
    private var deadline: Task<Void, Never>?
    private var token = UUID().uuidString.lowercased()
    private var run = UUID()
    private var targetDuration = 2
    func start(store: ReceivedMediaStore, hash: Data) async throws -> URL {
        stop()
        let snapshot = try await store.playback(captureHash: hash)
        targetDuration = max(2, Int(ceil(snapshot.manifests.map(\.duration).max() ?? 1)))
        let generation = run
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                switch state {
                case .ready:
                    if let port = listener?.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/index.m3u8") {
                        self.ready?.resume(returning: url); self.ready = nil; self.deadline?.cancel(); self.deadline = nil
                    }
                case .failed(let error): self.ready?.resume(throwing: error); self.ready = nil; self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.run == generation, self.channels.count < 6 else { connection.cancel(); return }
                let id = UUID(), channel = NearbyChannel(connection)
                self.channels[id] = channel
                self.tasks[id] = Task { [weak self] in
                    guard let self else { channel.close(); return }
                    defer { channel.close(); self.channels[id] = nil; self.tasks[id] = nil }
                    do {
                        try await channel.start()
                        var header = Data()
                        while header.range(of: Data("\r\n\r\n".utf8)) == nil {
                            guard header.count < 8192 else { throw URLError(.badServerResponse) }
                            header.append(try await channel.receive(upTo: min(2048, 8192 - header.count)))
                        }
                        guard self.run == generation else { return }
                        try await self.respond(header, channel: channel, store: store, hash: hash)
                        try await channel.finish()
                    } catch { /* Playback failure never touches replication or cloud work. */ }
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.stop()
                }
                listener.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in self.stop() } }
    }
    private func respond(_ data: Data, channel: NearbyChannel, store: ReceivedMediaStore, hash: Data) async throws {
        guard let request = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw URLError(.badServerResponse) }
        let prefix = "/" + token + "/", path = String(first[1])
        guard path.hasPrefix(prefix) else {
            try await channel.write(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        let leaf = String(path.dropFirst(prefix.count)), snapshot = try await store.playback(captureHash: hash)
        if leaf == "index.m3u8" {
            let playlist = try Self.playlist(snapshot, targetDuration: targetDuration)
            let body = Data(playlist.utf8)
            try await channel.write(Data("HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
            for start in stride(from: 0, to: body.count, by: 65_536) { try await channel.write(body.subdata(in: start..<min(start + 65_536, body.count))) }
            return
        }
        guard leaf.hasSuffix(".mp4"), let sequence = Int(leaf.dropLast(4)), leaf == "\(sequence).mp4",
              sequence >= 0, sequence < snapshot.manifests.count,
              let object = try await store.savedObject(captureHash: hash, sequence: sequence) else { throw URLError(.fileDoesNotExist) }
        let size = snapshot.manifests[sequence].size
        let rangeHeaders = lines.filter { $0.lowercased().hasPrefix("range:") }
        guard rangeHeaders.count <= 1 else { throw URLError(.badServerResponse) }
        let range = try Self.byteRange(rangeHeaders.first.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }, size: size)
        let partial = !rangeHeaders.isEmpty
        let extra = partial ? "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)\r\n" : ""
        try await channel.write(Data("HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n\(extra)Content-Length: \(range.count)\r\nConnection: close\r\n\r\n".utf8))
        let file = try FileHandle(forReadingFrom: object.file); defer { try? file.close() }
        try file.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            let bytes = try file.read(upToCount: min(65_536, remaining)) ?? Data()
            guard !bytes.isEmpty else { throw CocoaError(.fileReadUnknown) }
            try await channel.write(bytes); remaining -= bytes.count
        }
    }
    static func byteRange(_ value: String?, size: Int) throws -> Range<Int> {
        guard size > 0 else { throw URLError(.badServerResponse) }
        guard let value else { return 0..<size }
        guard value.hasPrefix("bytes=") else { throw URLError(.badServerResponse) }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw URLError(.badServerResponse) }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 { return max(0, size - suffix)..<size }
        guard let start = Int(parts[0]), start >= 0, start < size else { throw URLError(.badServerResponse) }
        if parts[1].isEmpty { return start..<size }
        guard let end = Int(parts[1]), end >= start, end < Int.max else { throw URLError(.badServerResponse) }
        return start..<min(size, end + 1)
    }
    static func playlist(_ snapshot: ReceivedMediaStore.Playback, targetDuration: Int) throws -> String {
        guard snapshot.manifests.count > 1, snapshot.manifests[0].kind == .initialization,
              snapshot.manifests.allSatisfy({ $0.duration.rounded() <= Double(targetDuration) }) else { throw MediaRecords.failure("Waiting for playable video") }
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(targetDuration)\n#EXT-X-PLAYLIST-TYPE:EVENT\n#EXT-X-MEDIA-SEQUENCE:1\n#EXT-X-MAP:URI=\"0.mp4\"\n"
        for object in snapshot.manifests.dropFirst() {
            text += "#EXTINF:\(String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), object.duration)),\n\(object.sequence).mp4\n"
        }
        if snapshot.ended { text += "#EXT-X-ENDLIST\n" }
        return text
    }
    func stop() {
        run = UUID(); token = UUID().uuidString.lowercased()
        ready?.resume(throwing: CancellationError()); ready = nil
        deadline?.cancel(); deadline = nil; listener?.cancel(); listener = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        channels.values.forEach { $0.close() }; channels.removeAll()
    }
}

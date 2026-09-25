import Foundation
import Security
@preconcurrency import Network

// The wire carries bounded controls and two interleaved media slots. A saved
// response is sent only after ReceivedMediaStore has synced the original bytes.
struct NearbyControl: Codable, Sendable {
    var type: String
    var descriptor: MediaRecords.Envelope?
    var grant: MediaRecords.Envelope?
    var manifest: MediaRecords.Envelope?
    var completion: MediaRecords.Envelope?
    var slot: Int?
    var cursor: Int?
    var receipts: [ReceivedMediaStore.Receipt]?
    var receipt: ReceivedMediaStore.Receipt?
    var message: String?
    var status: Int?
}

@MainActor
final class NearbyChannel {
    private let connection: NWConnection
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var deadline: Task<Void, Never>?
    private var closed = false
    private var started = false
    var operationTimeout: Double = 20
    init(_ connection: NWConnection) { self.connection = connection }

    // TLS proves possession here; the server credential authenticates the key
    // before consent or media. Never use these parameters for ordinary uploads.
    static func pairingParameters(identity: SecIdentity) throws -> NWParameters {
        guard let local = sec_identity_create(identity) else { throw MediaRecords.failure("Invalid sharing identity") }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            let key = chain?.first.flatMap { SecCertificateCopyKey($0) }
            complete(key.flatMap { SecKeyCopyExternalRepresentation($0, nil) as Data? }?.count == 65)
        }, .main)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
    var remotePublicKey: Data? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var result: Data?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if result == nil, let key = SecCertificateCopyKey(sec_certificate_copy_ref(certificate).takeRetainedValue()) {
                result = SecKeyCopyExternalRepresentation(key, nil) as Data?
            }
        }
        return result
    }
    func sendPairing(_ message: NearbyPairing.Message) async throws { try await send(kind: 1, data: JSONEncoder().encode(message)) }
    func readPairing() async throws -> NearbyPairing.Message {
        let (kind, data) = try await read()
        guard kind == 1 else { throw MediaRecords.failure("Invalid pairing message") }
        return try JSONDecoder().decode(NearbyPairing.Message.self, from: data)
    }

    func start() async throws {
        guard !started else { throw MediaRecords.failure("Connection already started") }
        started = true
        _ = try await wait { id in
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.resolve(id, .success(Data()))
                    case .failed(let error), .waiting(let error): self.close(error)
                    case .cancelled: self.close(CancellationError())
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }
    func close(_ error: Error = CancellationError()) {
        guard !closed else { return }
        closed = true; deadline?.cancel(); deadline = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let callbacks = pending.values; pending.removeAll()
        for callback in callbacks { callback.resume(throwing: error) }
    }
    private func wait(_ begin: (UUID) -> Void) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadline?.cancel()
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.operationTimeout ?? 20)) } catch { return }
                    self?.close(APIError(status: 0, message: "Nearby connection timed out"))
                }
                begin(id)
            }
        } onCancel: { Task { @MainActor in self.close() } }
    }
    private func resolve(_ id: UUID, _ result: Result<Data, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if pending.isEmpty { deadline?.cancel(); deadline = nil }
        continuation.resume(with: result)
    }
    private func send(kind: UInt8, data: Data) async throws {
        guard data.count <= (kind == 1 ? 8192 : 65_537), !data.isEmpty else { throw MediaRecords.failure("Invalid nearby frame") }
        let size = UInt32(data.count)
        var frame = Data([1, kind, UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        frame.append(data)
        try await write(frame)
    }
    // Also used by the loopback player; callers bound each buffer to 64 KiB.
    func write(_ data: Data) async throws {
        guard data.count <= 65_543 else { throw MediaRecords.failure("Network buffer is too large") }
        _ = try await wait { id in
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    self?.resolve(id, error.map { .failure($0) } ?? .success(Data()))
                }
            })
        }
    }
    func finish() async throws {
        _ = try await wait { id in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                Task { @MainActor in self?.resolve(id, error.map { .failure($0) } ?? .success(Data())) }
            })
        }
        _ = try? await receive(upTo: 1)
        close()
    }
    func receive(upTo maximum: Int) async throws -> Data {
        guard maximum > 0, maximum <= 65_537 else { throw MediaRecords.failure("Invalid network read") }
        return try await wait { id in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, _, error in
                Task { @MainActor in
                    if let error { self?.resolve(id, .failure(error)) }
                    else if let data, !data.isEmpty { self?.resolve(id, .success(data)) }
                    else { self?.resolve(id, .failure(APIError(status: 0, message: "Nearby connection ended"))) }
                }
            }
        }
    }
    private func bytes(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let maximum = count - buffer.count
            let data = try await receive(upTo: maximum)
            buffer.append(data)
        }
        return buffer
    }
    func read() async throws -> (UInt8, Data) {
        let header = try await bytes(6)
        let length = header.dropFirst(2).reduce(0) { ($0 << 8) | Int($1) }
        guard header[0] == 1, header[1] == 1 || header[1] == 2, length > 0,
              length <= (header[1] == 1 ? 8192 : 65_537) else { throw MediaRecords.failure("Unsupported nearby frame") }
        return (header[1], try await bytes(length))
    }
    func send(_ control: NearbyControl) async throws { try await send(kind: 1, data: JSONEncoder().encode(control)) }
    func chunk(_ data: Data, slot: Int) async throws {
        guard (0...1).contains(slot), !data.isEmpty, data.count <= 65_536 else { throw MediaRecords.failure("Invalid media chunk") }
        var body = Data([UInt8(slot)]); body.append(data); try await send(kind: 2, data: body)
    }
    func request(_ control: NearbyControl) async throws -> NearbyControl {
        try await send(control)
        let (kind, data) = try await read()
        guard kind == 1 else { throw MediaRecords.failure("Expected nearby receipt") }
        let response = try JSONDecoder().decode(NearbyControl.self, from: data)
        if response.type == "error" { throw APIError(status: response.status ?? 0, message: response.message ?? "Nearby transfer paused") }
        return response
    }
}

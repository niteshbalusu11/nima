#if DEBUG
import Foundation
import Combine
import CryptoKit
import Security
@preconcurrency import Network

// Development-only transport experiment. Transfers synthetic bytes, never camera media.
// Uses either isolated fixtures or the registered identity and cached directional consent.
@MainActor
final class NearbyProbe: ObservableObject {
    enum Event { case listening(UInt16), completed, rejectedPeer, failed(String) }
    static let service = "_uv-probe._tcp"
    static let byteCount = 256 * 1024
    private static let block = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
    @Published private(set) var status = "Import a test identity"
    @Published private(set) var identityLabel: String?
    var onEvent: ((Event) -> Void)?
    private var identity: SecIdentity?
    private var peerCertificate = Data()
    private var peerPublicKey = Data()
    private var registeredPeer: (store: PeerStore, approval: PeerApproval, sending: Bool)?
    private var approvalTask: Task<Void, Never>?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var timeout: Task<Void, Never>?
    private var run = UUID()

    func load(_ data: Data) throws {
        struct Fixture: Decodable { let label: String; let pkcs12: Data; let password: String; let peerCertificate: Data }
        guard data.count <= 64 * 1024 else { throw ProbeError("Test identity is too large") }
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        guard fixture.label.count <= 80,
              SecCertificateCreateWithData(nil, fixture.peerCertificate as CFData) != nil else {
            throw ProbeError("Invalid peer certificate")
        }
        var options: [String: Any] = [kSecImportExportPassphrase as String: fixture.password]
        if #available(iOS 18, macOS 15, *) { options[kSecImportToMemoryOnly as String] = true }
        #if os(macOS)
        guard #available(macOS 15, *) else { throw ProbeError("Memory-only identity import requires macOS 15") }
        #endif
        var items: CFArray?
        let result = SecPKCS12Import(fixture.pkcs12 as CFData, options as CFDictionary, &items)
        guard result == errSecSuccess, let entries = items as? [[String: Any]],
              let value = entries.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw ProbeError("Could not import test identity (\(result))")
        }
        stop()
        identity = (value as! SecIdentity)
        peerCertificate = fixture.peerCertificate
        peerPublicKey = Data(); registeredPeer = nil
        identityLabel = fixture.label
        status = "Ready"
    }

    func load(registeredIdentity: SecIdentity, approval: PeerApproval, store: PeerStore) throws {
        let device = store.device
        guard approval.sender == device || approval.recipient == device else { throw ProbeError("Approval belongs to another phone") }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(registeredIdentity, &certificate) == errSecSuccess, let certificate,
              Self.publicKey(certificate) == DeviceIdentity.decodeURL(device.tlsPublicKey) else { throw ProbeError("Nearby identity does not match this phone") }
        let sending = approval.sender == device
        let peer = sending ? approval.recipient : approval.sender
        guard let key = DeviceIdentity.decodeURL(peer.tlsPublicKey), peer.isValid else { throw ProbeError("Invalid approved identity") }
        stop()
        identity = registeredIdentity; peerCertificate = Data(); peerPublicKey = key
        registeredPeer = (store, approval, sending)
        identityLabel = "Registered device"
        status = "Ready"
    }

    nonisolated private static func publicKey(_ certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    private func parameters() throws -> NWParameters {
        guard let identity, let local = sec_identity_create(identity), !peerCertificate.isEmpty || !peerPublicKey.isEmpty else {
            throw ProbeError("Import a test identity first")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let approved = peerCertificate
        let approvedKey = peerPublicKey
        let registered = registeredPeer
        let generation = run
        if let registered {
            approvalTask?.cancel()
            approvalTask = Task { [weak self] in
                for await snapshot in await registered.store.updates() {
                    guard !Task.isCancelled, let self, self.run == generation else { return }
                    guard snapshot.approvals.contains(registered.approval) else {
                        self.fail("Sharing approval was removed", generation); return
                    }
                }
            }
        }
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { @Sendable [weak self] _, remote, complete in
            let verification = Verification(complete: complete)
            let trust = sec_trust_copy_ref(remote).takeRetainedValue()
            let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            // TLS proves private-key possession. Names and self-signed certificate
            // dates do not confer trust; only the pinned key and active consent do.
            let matches = certificates?.first.map {
                registered == nil ? SecCertificateCopyData($0) as Data == approved : Self.publicKey($0) == approvedKey
            } ?? false
            Task { @MainActor in
                var allowed = matches
                if let registered {
                    let snapshot = await registered.store.snapshot()
                    allowed = allowed && snapshot.approvals.contains(registered.approval)
                }
                guard let self, self.run == generation else { verification.complete(false); return }
                verification.complete(allowed)
                if !allowed { self.stop(); self.status = "Peer identity not approved"; self.onEvent?(.rejectedPeer) }
            }
        }, .main)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    func listen(localOnly: Bool = false) throws {
        stop()
        guard registeredPeer?.sending != true else { throw ProbeError("This approval only allows sending") }
        let generation = run
        let parameters = try parameters()
        if localOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        if !localOnly { listener.service = NWListener.Service(name: UUID().uuidString, type: Self.service) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                switch state {
                case .ready:
                    self.status = "Listening for approved peer"
                    if let port = listener?.port { self.onEvent?(.listening(port.rawValue)) }
                case .failed(let error): self.fail("Listener failed: \(error)", generation)
                case .waiting: self.status = "Waiting for network access"
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.run == generation, self.connection == nil else { connection.cancel(); return }
                self.start(connection, sending: false, generation)
            }
        }
        status = "Starting listener"
        listener.start(queue: .main)
    }

    func browse() throws {
        stop()
        guard registeredPeer?.sending != false else { throw ProbeError("This approval only allows receiving") }
        let generation = run
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: try parameters())
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                if case .failed(let error) = state { self.fail("Discovery failed: \(error)", generation) }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.run == generation, self.connection == nil, let endpoint = results.first?.endpoint else { return }
                self.browser?.cancel(); self.browser = nil
                do { self.start(NWConnection(to: endpoint, using: try self.parameters()), sending: true, generation) }
                catch { self.fail(error.localizedDescription, generation) }
            }
        }
        status = "Looking for receiver"
        browser.start(queue: .main)
        deadline(generation)
    }

    // Loopback exercises the exact TLS and byte-transfer implementation without Bonjour/radio claims.
    func connectLoopback(port: UInt16) throws {
        stop()
        guard registeredPeer?.sending != false else { throw ProbeError("This approval only allows receiving") }
        guard let port = NWEndpoint.Port(rawValue: port) else { throw ProbeError("Invalid port") }
        start(NWConnection(host: "127.0.0.1", port: port, using: try parameters()), sending: true, run)
    }

    private func start(_ connection: NWConnection, sending: Bool, _ generation: UUID) {
        self.connection = connection
        status = "Authenticating peer"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.run == generation else { return }
                switch state {
                case .ready:
                    self.status = "Authenticated · transferring 256 KiB"
                    if sending { self.sendBlock(connection, remaining: Self.byteCount, generation) }
                    else { self.receiveBlock(connection, remaining: Self.byteCount, hash: SHA256(), generation) }
                case .failed(let error): self.fail("Connection failed: \(error)", generation)
                case .waiting(let error): self.fail("Connection waiting: \(error)", generation)
                default: break
                }
            }
        }
        deadline(generation)
        connection.start(queue: .main)
    }

    private func sendBlock(_ connection: NWConnection, remaining: Int, _ generation: UUID) {
        guard remaining > 0 else { receiveReceipt(connection, generation); return }
        connection.send(content: Self.block, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                if let error { self.fail("Send failed: \(error)", generation); return }
                self.sendBlock(connection, remaining: remaining - Self.block.count, generation)
            }
        })
    }

    private func receiveBlock(_ connection: NWConnection, remaining: Int, hash: SHA256, _ generation: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, Self.block.count)) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                guard error == nil, let data, !data.isEmpty else { self.fail("Transfer interrupted", generation); return }
                var updated = hash; updated.update(data: data)
                let left = remaining - data.count
                guard left >= 0, !ended || left == 0 else { self.fail("Transfer length mismatch", generation); return }
                if left > 0 { self.receiveBlock(connection, remaining: left, hash: updated, generation); return }
                connection.send(content: Data(updated.finalize()), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.run == generation else { return }
                        if let error { self.fail("Receipt failed: \(error)", generation); return }
                        self.timeout?.cancel(); self.timeout = nil
                        self.status = "Received and hashed 256 KiB (memory only)"
                        self.onEvent?(.completed)
                        // Wait for the sender to consume the receipt before cancelling the connection.
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                            Task { @MainActor in
                                guard let self, self.run == generation else { return }
                                let status = self.status; self.stop(); self.status = status
                            }
                        }
                    }
                })
            }
        }
    }

    private func receiveReceipt(_ connection: NWConnection, _ generation: UUID) {
        connection.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.run == generation else { return }
                var expected = SHA256()
                for _ in 0..<(Self.byteCount / Self.block.count) { expected.update(data: Self.block) }
                guard error == nil, data == Data(expected.finalize()) else { self.fail("Receipt digest mismatch", generation); return }
                self.stop()
                self.status = "Receiver verified 256 KiB (memory only)"
                self.onEvent?(.completed)
            }
        }
    }

    private func deadline(_ generation: UUID) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail("Timed out; check receiver, identity and network permission", generation)
        }
    }
    private func fail(_ message: String, _ generation: UUID) {
        guard run == generation else { return }
        stop(); status = message; onEvent?(.failed(message))
    }
    func stop() {
        run = UUID()
        approvalTask?.cancel(); approvalTask = nil
        timeout?.cancel(); timeout = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        status = identity == nil ? "Import a test identity" : "Stopped"
    }
    private struct ProbeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    // Security's completion is designed for asynchronous verification but is not
    // annotated Sendable. Transfer it to one task, which invokes it exactly once.
    private struct Verification: @unchecked Sendable { let complete: (Bool) -> Void }
}
#endif

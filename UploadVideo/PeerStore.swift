import Foundation
import CryptoKit

struct PeerApproval: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let sender: RegisteredDevice
    let recipient: RegisteredDevice
    let createdAt: Int64
    let senderName: String
    let recipientName: String
    func samePermission(as other: PeerApproval) -> Bool {
        id == other.id && sender == other.sender && recipient == other.recipient
    }
}
struct PeerInvitation: Decodable, Sendable {
    let token: String
    let expiresAt: Int64
    let recipientName: String
}
struct PeerInvitationPreview: Decodable, Sendable {
    let sender: RegisteredDevice
    let senderName: String
    let expiresAt: Int64
}

// Codes contain routing identifiers, not trusted keys. Never follow a code's server URL.
enum PeerCode {
    struct Contact: Codable, Sendable { let server: String; let accountId: String; let deviceId: String }
    private struct Invitation: Codable { let server: String; let token: String }
    static func contact(server: URL, device: RegisteredDevice) throws -> String {
        try encode("contact", Contact(server: server.absoluteString, accountId: device.accountId, deviceId: device.id))
    }
    static func invitation(server: URL, token: String) throws -> String {
        try encode("peer-invite", Invitation(server: server.absoluteString, token: token))
    }
    static func readContact(_ code: String, server: URL) throws -> Contact {
        let contact: Contact = try decode("contact", code)
        guard contact.server == server.absoluteString, RegisteredDevice.validID(contact.accountId), RegisteredDevice.validID(contact.deviceId) else {
            throw PeerStore.failure("Contact belongs to another server or is invalid")
        }
        return contact
    }
    static func readInvitation(_ code: String, server: URL) throws -> String {
        let invite: Invitation = try decode("peer-invite", code)
        guard invite.server == server.absoluteString, DeviceIdentity.decodeURL(invite.token)?.count == 32 else {
            throw PeerStore.failure("Invitation belongs to another server or is invalid")
        }
        return invite.token
    }
    static func isInvitation(_ code: String) -> Bool { code.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("uploadvideo:peer-invite:") }
    private static func encode<T: Encodable>(_ kind: String, _ value: T) throws -> String {
        "uploadvideo:\(kind):v1:" + DeviceIdentity.encodeURL(try API.encode(value))
    }
    private static func decode<T: Decodable>(_ kind: String, _ value: String) throws -> T {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "uploadvideo:\(kind):v1:"
        guard code.utf8.count <= 2048, code.hasPrefix(prefix) else { throw PeerStore.failure("Invalid sharing code") }
        let encoded = String(code.dropFirst(prefix.count))
        let text = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)),
              DeviceIdentity.encodeURL(data) == encoded else { throw PeerStore.failure("Invalid sharing code") }
        return try API.decoder.decode(T.self, from: data)
    }
}

// One instance per signed-in device in AppModel. Network calls may yield; local
// revocation always updates the current state, including while a sync is in flight.
actor PeerStore {
    struct Snapshot: Sendable {
        let approvals: [PeerApproval]
        let pendingRevocations: Int
        let syncedAt: Date?
        let accessActive: Bool
    }
    private struct State: Codable {
        var version = 1
        let server: String
        let device: RegisteredDevice
        var approvals: [PeerApproval] = []
        var pendingRevocations: Set<String> = []
        var syncedAt: Date?
        var accessActive = true
    }
    let device: RegisteredDevice
    let baseURL: URL
    let sessionToken: String
    private let api: API
    private let file: URL
    private var state: State
    private var healthy = true
    private var syncing = false
    private var authorizationVersion = 0
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    init(api: API, session: Session, device: RegisteredDevice, root: URL? = nil) throws {
        guard api.token == session.token, session.deviceId == device.id, session.accountId == device.accountId, device.isValid else {
            throw Self.failure("Sharing session does not match this device")
        }
        self.api = api; self.device = device; baseURL = api.baseURL; sessionToken = session.token
        var directory = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true).appendingPathComponent("NearbyApprovals", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let scope = Data((api.baseURL.absoluteString + "\n" + device.accountId + "\n" + device.id).utf8)
        let name = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        file = directory.appendingPathComponent(name + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else { throw Self.failure("Saved approvals are too large") }
            state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 1, state.server == api.baseURL.absoluteString, state.device == device,
                  state.pendingRevocations.count <= 64, state.pendingRevocations.allSatisfy(RegisteredDevice.validID) else {
                throw Self.failure("Saved approvals do not match this device")
            }
            try Self.validate(state.approvals, for: device)
        } else { state = State(server: api.baseURL.absoluteString, device: device) }
    }

    func snapshot() -> Snapshot {
        Snapshot(approvals: healthy && state.accessActive ? state.approvals.filter { !state.pendingRevocations.contains($0.id) } : [],
                 pendingRevocations: state.pendingRevocations.count, syncedAt: state.syncedAt, accessActive: healthy && state.accessActive)
    }
    func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func revoke(_ id: String) throws {
        guard state.approvals.contains(where: { $0.id == id }) || state.pendingRevocations.contains(id) else { return }
        state.pendingRevocations.insert(id)
        try save()
    }

    func refresh() async throws {
        guard !syncing else { throw Self.failure("Sharing is already updating") }
        syncing = true; defer { syncing = false }
        let authorization = authorizationVersion
        do {
            let pending = state.pendingRevocations
            for id in pending {
                do { let _: OK = try await api.request("DELETE", "peer-approvals/\(id)") }
                catch let error as APIError where error.status == 404 { /* Removed at the server already. */ }
            }
            struct Response: Decodable, Sendable { let approvals: [PeerApproval] }
            let response: Response = try await api.request("GET", "peer-approvals")
            guard authorization == authorizationVersion else { throw Self.failure("Sharing access changed; refresh again") }
            try Self.validate(response.approvals, for: device)
            guard response.approvals.allSatisfy({ !pending.contains($0.id) }) else { throw Self.failure("Removed peer is still present; try again") }
            // Keep removals made during the awaits, and clear only those reconciled
            // against a snapshot requested after their DELETE completed.
            state.pendingRevocations.subtract(pending)
            state.approvals = response.approvals
            state.syncedAt = Date(); state.accessActive = true
            try save()
        } catch {
            try invalidateIfUnauthorized(error)
            throw error
        }
    }

    func createInvitation(for code: String) async throws -> PeerInvitation {
        let contact = try PeerCode.readContact(code, server: baseURL)
        struct Input: Encodable { let recipientAccountId: String; let recipientDeviceId: String }
        do {
            return try await api.request("POST", "peer-invitations", body: API.encode(Input(recipientAccountId: contact.accountId, recipientDeviceId: contact.deviceId)))
        } catch { try invalidateIfUnauthorized(error); throw error }
    }
    func previewInvitation(_ code: String) async throws -> PeerInvitationPreview {
        let token = try PeerCode.readInvitation(code, server: baseURL)
        do {
            let result: PeerInvitationPreview = try await api.request("POST", "peer-invitations/preview", body: API.encode(["token": token]))
            guard result.sender.isValid, result.sender.id != device.id, result.senderName.utf8.count <= 120 else { throw Self.failure("Invalid invitation sender") }
            return result
        } catch { try invalidateIfUnauthorized(error); throw error }
    }
    func acceptInvitation(_ code: String) async throws {
        guard !syncing else { throw Self.failure("Sharing is already updating") }
        let token = try PeerCode.readInvitation(code, server: baseURL)
        syncing = true; defer { syncing = false }
        let authorization = authorizationVersion
        do {
            let approval: PeerApproval = try await api.request("POST", "peer-invitations/accept", body: API.encode(["token": token]))
            guard authorization == authorizationVersion else { throw Self.failure("Sharing access changed; refresh again") }
            guard approval.recipient == device, !state.pendingRevocations.contains(approval.id) else { throw Self.failure("Ask for a new invitation for this phone") }
            // Fresh consent supersedes a stale cached record for this direction.
            let next = state.approvals.filter { $0.id != approval.id && !($0.sender == approval.sender && $0.recipient == approval.recipient) } + [approval]
            try Self.validate(next, for: device)
            state.approvals = next; state.accessActive = true
            try save()
        } catch { try invalidateIfUnauthorized(error); throw error }
    }

    private func invalidateIfUnauthorized(_ error: Error) throws {
        if let error = error as? APIError, error.status == 401 || error.status == 403 {
            authorizationVersion += 1
            state.accessActive = false; state.approvals = []
            try save()
        }
    }
    private func save() throws {
        defer { for observer in observers.values { observer.yield(snapshot()) } }
        do {
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            healthy = true
        } catch {
            healthy = false // Do not use permissions that could not be persisted.
            throw error
        }
    }
    private static func validate(_ approvals: [PeerApproval], for device: RegisteredDevice) throws {
        guard approvals.count <= 64, Set(approvals.map(\.id)).count == approvals.count else { throw failure("Invalid approval snapshot") }
        var identities = [device.id: device]
        var directions = Set<String>()
        for approval in approvals {
            guard RegisteredDevice.validID(approval.id), approval.createdAt > 0,
                  approval.sender.id != approval.recipient.id,
                  approval.sender == device || approval.recipient == device,
                  approval.senderName.utf8.count <= 120, approval.recipientName.utf8.count <= 120,
                  directions.insert(approval.sender.id + ":" + approval.recipient.id).inserted else { throw failure("Invalid approval participants") }
            for peer in [approval.sender, approval.recipient] {
                guard peer.isValid, identities[peer.id] == nil || identities[peer.id] == peer else { throw failure("Conflicting peer identity") }
                identities[peer.id] = peer
            }
        }
    }
    static func failure(_ message: String) -> APIError { APIError(status: 0, message: message) }
}

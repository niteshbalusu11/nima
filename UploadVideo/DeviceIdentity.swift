import Foundation
import CryptoKit
import Security

struct RegisteredDevice: Codable, Sendable, Equatable {
    let id: String
    let accountId: String
    let signingPublicKey: String
    let tlsPublicKey: String
}

// Owns both private keys. Callers see public registration data, never private bytes.
// TLS certificate construction is separate from this registration proof.
struct DeviceIdentity: Sendable {
    private let signing: P256.Signing.PrivateKey
    private let tls: P256.Signing.PrivateKey
    private struct StoredKeys: Codable {
        let version: Int
        let signing: Data
        let tls: Data
    }
    private struct PublicKeys: Encodable {
        let signingPublicKey: String
        let tlsPublicKey: String
    }
    private struct Challenge: Decodable {
        let nonce: String
        let expiresAt: Int64
    }
    private struct Proof: Encodable {
        let nonce: String
        let signingSignature: String
        let tlsSignature: String
    }

    private init() {
        signing = P256.Signing.PrivateKey()
        tls = P256.Signing.PrivateKey()
    }
    private init(stored data: Data) throws {
        let keys = try JSONDecoder().decode(StoredKeys.self, from: data)
        guard keys.version == 1, keys.signing != keys.tls else { throw Self.identityError("Saved device identity is invalid") }
        signing = try P256.Signing.PrivateKey(rawRepresentation: keys.signing)
        tls = try P256.Signing.PrivateKey(rawRepresentation: keys.tls)
    }

    static func loadOrCreate(for session: Session, at baseURL: URL) throws -> DeviceIdentity {
        // A single atomic Keychain item avoids persisting only half of an identity.
        let scope = Data((baseURL.absoluteString + "\n" + session.accountId).utf8)
        let name = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "UploadVideo.nearby.identity.v1",
            kSecAttrAccount as String: name,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        func load() throws -> DeviceIdentity? {
            var read = query
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw identityError("Could not read device identity", status: status)
            }
            return try DeviceIdentity(stored: data)
        }
        if let saved = try load() { return saved }
        guard session.deviceId == nil else {
            throw identityError("This device's sharing keys are missing. Recording still works.")
        }
        let identity = DeviceIdentity()
        let stored = StoredKeys(version: 1, signing: identity.signing.rawRepresentation, tls: identity.tls.rawRepresentation)
        var write = query
        write[kSecValueData as String] = try JSONEncoder().encode(stored)
        write[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(write as CFDictionary, nil)
        if status == errSecDuplicateItem, let saved = try load() { return saved }
        guard status == errSecSuccess else { throw identityError("Could not save device identity", status: status) }
        return identity
    }

    func register(using api: API, session: Session) async throws -> RegisteredDevice {
        guard api.token == session.token else { throw Self.identityError("Device setup session changed") }
        let keys = PublicKeys(signingPublicKey: Self.encodeURL(signing.publicKey.x963Representation),
                              tlsPublicKey: Self.encodeURL(tls.publicKey.x963Representation))
        let challenge: Challenge = try await api.request("POST", "devices/challenge", body: API.encode(keys))
        guard let nonce = Self.decodeURL(challenge.nonce), nonce.count == 32,
              session.accountId.utf8.count <= Int(UInt16.max), challenge.expiresAt > 0 else {
            throw Self.identityError("Invalid device challenge")
        }
        var payload = Data("uploadvideo.device-registration.v1\0".utf8)
        payload.append(nonce)
        payload.append(contentsOf: SHA256.hash(data: Data(session.token.utf8)))
        var accountLength = UInt16(session.accountId.utf8.count).bigEndian
        withUnsafeBytes(of: &accountLength) { payload.append(contentsOf: $0) }
        payload.append(Data(session.accountId.utf8))
        payload.append(signing.publicKey.x963Representation)
        payload.append(tls.publicKey.x963Representation)
        var expiry = UInt64(challenge.expiresAt).bigEndian
        withUnsafeBytes(of: &expiry) { payload.append(contentsOf: $0) }
        let proof = Proof(nonce: challenge.nonce,
                          signingSignature: Self.encodeURL(try signing.signature(for: payload).derRepresentation),
                          tlsSignature: Self.encodeURL(try tls.signature(for: payload).derRepresentation))
        let device: RegisteredDevice = try await api.request("POST", "devices/register", body: API.encode(proof))
        guard device.accountId == session.accountId, device.signingPublicKey == keys.signingPublicKey,
              device.tlsPublicKey == keys.tlsPublicKey, !device.id.isEmpty,
              session.deviceId == nil || session.deviceId == device.id else {
            throw Self.identityError("Registered device does not match this phone")
        }
        return device
    }

    private static func encodeURL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func decodeURL(_ value: String) -> Data? {
        guard value.utf8.count <= 128 else { return nil }
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)),
              encodeURL(data) == value else { return nil }
        return data
    }
    private static func identityError(_ message: String, status: OSStatus = 0) -> APIError {
        APIError(status: Int(status), message: message)
    }

    #if DEBUG
    // Cross-language checks never create credentials in the developer's real Keychain.
    static func ephemeralForCheck() -> DeviceIdentity { DeviceIdentity() }
    #endif
}

import Foundation
import CryptoKit
import Security
#if canImport(X509)
import X509
#endif

struct RegisteredDevice: Codable, Sendable, Equatable {
    let id: String
    let accountId: String
    let signingPublicKey: String
    let tlsPublicKey: String
    var isValid: Bool {
        guard Self.validID(id), Self.validID(accountId), signingPublicKey != tlsPublicKey,
              let signing = DeviceIdentity.decodeURL(signingPublicKey), let tls = DeviceIdentity.decodeURL(tlsPublicKey) else { return false }
        return (try? P256.Signing.PublicKey(x963Representation: signing)) != nil
            && (try? P256.Signing.PublicKey(x963Representation: tls)) != nil
    }
    static func validID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

// Owns both private keys. Callers see public registration data, never private bytes.
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
              device.tlsPublicKey == keys.tlsPublicKey, device.isValid,
              session.deviceId == nil || session.deviceId == device.id else {
            throw Self.identityError("Registered device does not match this phone")
        }
        return device
    }

    func registeredDevice(for session: Session) throws -> RegisteredDevice {
        guard let id = session.deviceId else { throw Self.identityError("Set up this device first") }
        let device = RegisteredDevice(id: id, accountId: session.accountId,
                                      signingPublicKey: Self.encodeURL(signing.publicKey.x963Representation),
                                      tlsPublicKey: Self.encodeURL(tls.publicKey.x963Representation))
        guard device.isValid else { throw Self.identityError("Invalid registered device") }
        return device
    }

    func matches(_ device: RegisteredDevice) -> Bool {
        device.isValid && device.signingPublicKey == Self.encodeURL(signing.publicKey.x963Representation)
            && device.tlsPublicKey == Self.encodeURL(tls.publicKey.x963Representation)
    }
    func signNearby(_ payload: Data) throws -> Data {
        guard payload.count <= 512, payload.starts(with: Data("uploadvideo.nearby-".utf8)) else { throw Self.identityError("Invalid nearby signing domain") }
        return try signing.signature(for: payload).derRepresentation
    }
    func signMedia(_ payload: Data) throws -> Data {
        guard payload.count <= 512, payload.starts(with: Data("uploadvideo.media.".utf8)) else {
            throw Self.identityError("Invalid media signing domain")
        }
        return try signing.signature(for: payload).derRepresentation
    }

    #if canImport(X509)
    // The certificate is only a TLS key container. Trust comes from the approved
    // public key, so regenerating this self-signed certificate does not change identity.
    // Kept conditional so the registration-only command-line checks need no packages.
    func tlsIdentity() throws -> SecIdentity {
        let name = try DistinguishedName { CommonName("Nearby device") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(tls.publicKey),
            notValidBefore: now.addingTimeInterval(-300), notValidAfter: now.addingTimeInterval(86400 * 365),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
            }, issuerPrivateKey: .init(tls))
        let leaf = try SecCertificate.makeWithCertificate(certificate)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                         kSecAttrKeySizeInBits as String: 256]
        guard let key = SecKeyCreateWithData(tls.x963Representation as CFData, attributes as CFDictionary, nil),
              let identity = SecIdentityCreate(nil, leaf, key) else {
            throw Self.identityError("Could not prepare nearby identity")
        }
        return identity
    }
    #endif

    static func encodeURL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeURL(_ value: String, maximumEncodedBytes: Int = 128) -> Data? {
        guard value.utf8.count <= maximumEncodedBytes else { return nil }
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

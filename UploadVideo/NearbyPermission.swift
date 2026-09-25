import Foundation
import CryptoKit

struct NearbyCertificate: Codable, Sendable {
    let payload: String
    let signature: String
    struct Claims: Codable, Sendable {
        let device: RegisteredDevice
        let name: String
        let issuedAt: Int64
        let expiresAt: Int64
    }
    func verify(authority: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> Claims {
        guard let key = DeviceIdentity.decodeURL(authority), key.count == 32,
              let bytes = DeviceIdentity.decodeURL(payload, maximumEncodedBytes: 2731), bytes.count <= 2048,
              let signature = DeviceIdentity.decodeURL(signature), signature.count == 64 else {
            throw PeerStore.failure("Invalid nearby credential")
        }
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key)
        guard verifier.isValidSignature(signature, for: Data("uploadvideo.nearby-credential.v1\0".utf8) + bytes) else {
            throw PeerStore.failure("This phone is not enrolled on your server")
        }
        let claims = try API.decoder.decode(Claims.self, from: bytes)
        guard claims.device.isValid, claims.name.utf8.count <= 120, claims.issuedAt > 0,
              claims.issuedAt <= now + 300, claims.expiresAt > now,
              claims.expiresAt > claims.issuedAt, claims.expiresAt - claims.issuedAt <= 30 * 86400 else {
            throw PeerStore.failure("Connect to the internet to renew Nearby setup")
        }
        return claims
    }
}
struct NearbyCredentials: Codable, Sendable {
    let authority: String
    let certificate: NearbyCertificate
}
struct NearbyPermission: Codable, Sendable {
    let approval: PeerApproval
    let authority: String
    var senderSignature = ""
    var recipientSignature = ""
    func payload() throws -> Data {
        guard let key = DeviceIdentity.decodeURL(authority), key.count == 32,
              approval.createdAt > 0, approval.sender.id != approval.recipient.id else { throw PeerStore.failure("Invalid nearby permission") }
        var bytes = Data("uploadvideo.nearby-permission.v1\0".utf8) + key
        func id(_ value: String) throws -> Data {
            guard RegisteredDevice.validID(value) else { throw PeerStore.failure("Invalid nearby identity") }
            let characters = Array(value.utf8)
            return Data(stride(from: 0, to: characters.count, by: 2).map {
                UInt8(String(bytes: characters[$0...($0 + 1)], encoding: .utf8)!, radix: 16)!
            })
        }
        bytes.append(try id(approval.id))
        for device in [approval.sender, approval.recipient] {
            guard device.isValid else { throw PeerStore.failure("Invalid registered phone") }
            bytes.append(try id(device.id)); bytes.append(try id(device.accountId))
            bytes.append(DeviceIdentity.decodeURL(device.signingPublicKey)!)
            bytes.append(DeviceIdentity.decodeURL(device.tlsPublicKey)!)
        }
        var date = UInt64(approval.createdAt).bigEndian
        withUnsafeBytes(of: &date) { bytes.append(contentsOf: $0) }
        return bytes
    }
    func verify(recipientRequired: Bool = true) throws {
        let data = try payload()
        try Self.verify(senderSignature, key: approval.sender.signingPublicKey, data: data)
        if recipientRequired { try Self.verify(recipientSignature, key: approval.recipient.signingPublicKey, data: data) }
    }
    static func verify(_ signature: String, key: String, data: Data) throws {
        guard let raw = DeviceIdentity.decodeURL(key), let signature = DeviceIdentity.decodeURL(signature), signature.count <= 72 else {
            throw PeerStore.failure("Invalid nearby proof")
        }
        guard try P256.Signing.PublicKey(x963Representation: raw).isValidSignature(P256.Signing.ECDSASignature(derRepresentation: signature), for: data) else {
            throw PeerStore.failure("Nearby identity could not be verified")
        }
    }
}


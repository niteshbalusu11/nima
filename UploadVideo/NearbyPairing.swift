import Foundation
import CryptoKit

// This handshake runs only inside the system-paired, encrypted Wi-Fi Aware link.
// Mutual TLS additionally binds each certified app identity to this exact channel,
// so forwarding a valid credential/proof through another TLS peer cannot impersonate it.
@MainActor
enum NearbyPairing {
    struct Message: Codable, Sendable {
        let type: String
        var server: String?
        var certificate: NearbyCertificate?
        var nonce: String?
        var proof: String?
        var permission: NearbyPermission?
    }
    private static func nonce() -> String { DeviceIdentity.encodeURL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
    static func proof(sender: RegisteredDevice, recipient: RegisteredDevice, senderNonce: String, recipientNonce: String, authority: String) throws -> Data {
        guard let a = DeviceIdentity.decodeURL(senderNonce), a.count == 32,
              let b = DeviceIdentity.decodeURL(recipientNonce), b.count == 32,
              let key = DeviceIdentity.decodeURL(authority), key.count == 32,
              sender.isValid, recipient.isValid, sender.id != recipient.id else { throw PeerStore.failure("Invalid nearby challenge") }
        return Data("uploadvideo.nearby-proof.v1\0".utf8) + key + Data(sender.id.utf8) + Data(recipient.id.utf8) + a + b
    }
    private static func peer(_ message: Message, channel: NearbyChannel, store: PeerStore, credentials: NearbyCredentials) throws -> NearbyCertificate.Claims {
        guard message.type == "hello", message.server == store.baseURL.absoluteString,
              let certificate = message.certificate else { throw PeerStore.failure("The phones use different servers") }
        let claims = try certificate.verify(authority: credentials.authority)
        guard claims.device.id != store.device.id, channel.remotePublicKey == DeviceIdentity.decodeURL(claims.device.tlsPublicKey) else {
            throw PeerStore.failure("Nearby credential does not match the connected phone")
        }
        return claims
    }
    static func send(channel: NearbyChannel, store: PeerStore, identity: DeviceIdentity) async throws -> PeerApproval {
        channel.operationTimeout = 120; defer { channel.operationTimeout = 20 }
        let credentials = try await store.pairingCredentials()
        let me = try credentials.certificate.verify(authority: credentials.authority)
        let challenge = nonce()
        try await channel.sendPairing(Message(type: "hello", server: store.baseURL.absoluteString, certificate: credentials.certificate, nonce: challenge))
        let hello = try await channel.readPairing()
        let other = try peer(hello, channel: channel, store: store, credentials: credentials)
        let proof = try proof(sender: me.device, recipient: other.device, senderNonce: challenge, recipientNonce: hello.nonce ?? "", authority: credentials.authority)
        try NearbyPermission.verify(hello.proof ?? "", key: other.device.signingPublicKey, data: proof)
        // The recipient may have saved consent just before our connection was lost.
        if let saved = hello.permission {
            guard saved.authority == credentials.authority, saved.approval.sender == me.device,
                  saved.approval.recipient == other.device else { throw PeerStore.failure("Invalid saved permission") }
            try saved.verify()
        }
        let old = await store.snapshot().approvals.first { $0.sender == me.device && $0.recipient == other.device } ?? hello.permission?.approval
        let approval = PeerApproval(id: old?.id ?? UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""), sender: me.device, recipient: other.device, createdAt: old?.createdAt ?? Int64(Date().timeIntervalSince1970), senderName: me.name, recipientName: other.name)
        var permission = NearbyPermission(approval: approval, authority: credentials.authority)
        permission.senderSignature = DeviceIdentity.encodeURL(try identity.signNearby(permission.payload()))
        try await channel.sendPairing(Message(type: "offer", proof: DeviceIdentity.encodeURL(try identity.signNearby(proof)), permission: permission))
        let accepted = try await channel.readPairing()
        guard accepted.type == "accept", let signed = accepted.permission,
              try signed.payload() == permission.payload() else { throw PeerStore.failure("Sharing was not accepted") }
        try signed.verify()
        try await store.savePairing(signed)
        try await channel.sendPairing(Message(type: "ready"))
        return signed.approval
    }
    static func receive(channel: NearbyChannel, store: PeerStore, identity: DeviceIdentity,
                        consent: @escaping @MainActor (PeerApproval) async -> Bool) async throws -> PeerApproval {
        channel.operationTimeout = 120; defer { channel.operationTimeout = 20 }
        let credentials = try await store.pairingCredentials()
        let hello = try await channel.readPairing()
        let other = try peer(hello, channel: channel, store: store, credentials: credentials)
        let challenge = nonce()
        let proof = try proof(sender: other.device, recipient: store.device, senderNonce: hello.nonce ?? "", recipientNonce: challenge, authority: credentials.authority)
        try await channel.sendPairing(Message(type: "hello", server: store.baseURL.absoluteString, certificate: credentials.certificate,
                                             nonce: challenge, proof: DeviceIdentity.encodeURL(try identity.signNearby(proof)),
                                             permission: await store.savedPairing(from: other.device)))
        let offered = try await channel.readPairing()
        try NearbyPermission.verify(offered.proof ?? "", key: other.device.signingPublicKey, data: proof)
        guard offered.type == "offer", var permission = offered.permission, permission.authority == credentials.authority,
              permission.approval.sender == other.device, permission.approval.recipient == store.device,
              permission.approval.senderName == other.name else { throw PeerStore.failure("Invalid sharing offer") }
        try permission.verify(recipientRequired: false)
        let known = await store.snapshot().approvals.contains { $0.samePermission(as: permission.approval) }
        if !known {
            guard await consent(permission.approval), !Task.isCancelled else { throw CancellationError() }
        }
        permission.recipientSignature = DeviceIdentity.encodeURL(try identity.signNearby(permission.payload()))
        try await store.savePairing(permission)
        try await channel.sendPairing(Message(type: "accept", permission: permission))
        guard try await channel.readPairing().type == "ready" else { throw PeerStore.failure("Sharing setup interrupted") }
        return permission.approval
    }
}

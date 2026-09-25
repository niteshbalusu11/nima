import Foundation

// Protocol-level tests create the same two-device permission as NearbyPairing.
// The media integration check separately exercises the real TLS consent exchange.
enum PairingFixture {
    @discardableResult
    static func approve(_ sender: PeerStore, _ recipient: PeerStore,
                        _ senderIdentity: DeviceIdentity, _ recipientIdentity: DeviceIdentity) async throws -> NearbyPermission {
        try await sender.refresh(); try await recipient.refresh()
        let a = try await sender.pairingCredentials(), b = try await recipient.pairingCredentials()
        guard a.authority == b.authority else { throw PeerStore.failure("Fixture servers differ") }
        let approval = PeerApproval(id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            sender: sender.device, recipient: recipient.device, createdAt: Int64(Date().timeIntervalSince1970),
            senderName: try a.certificate.verify(authority: a.authority).name,
            recipientName: try b.certificate.verify(authority: b.authority).name)
        var permission = NearbyPermission(approval: approval, authority: a.authority)
        permission.senderSignature = DeviceIdentity.encodeURL(try senderIdentity.signNearby(permission.payload()))
        permission.recipientSignature = DeviceIdentity.encodeURL(try recipientIdentity.signNearby(permission.payload()))
        try await sender.savePairing(permission); try await recipient.savePairing(permission)
        try await recipient.refresh(); try await sender.refresh()
        return permission
    }
}

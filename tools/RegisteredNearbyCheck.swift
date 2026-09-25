import Foundation
import Security

@MainActor
enum RegisteredNearbyCheck {
    static func run(identityA: DeviceIdentity, identityB: DeviceIdentity, identityC: DeviceIdentity,
                    a: PeerStore, b: PeerStore, c: PeerStore, approval: PeerApproval, otherApproval: PeerApproval) async throws {
        let localA = try identityA.tlsIdentity(), localB = try identityB.tlsIdentity()
        let replacement = try identityA.tlsIdentity()
        var firstCertificate: SecCertificate?, replacementCertificate: SecCertificate?
        SecIdentityCopyCertificate(localA, &firstCertificate)
        SecIdentityCopyCertificate(replacement, &replacementCertificate)
        try PeerCheck.expect(SecCertificateCopyData(firstCertificate!) != SecCertificateCopyData(replacementCertificate!), "Certificate was not renewed")
        for identity in [localA, replacement] {
            let sender = NearbyProbe(), receiver = NearbyProbe()
            try sender.load(registeredIdentity: identity, approval: approval, store: a)
            try receiver.load(registeredIdentity: localB, approval: approval, store: b)
            try PeerCheck.rejected { try sender.listen(localOnly: true) }
            try PeerCheck.rejected { try receiver.connectLoopback(port: 1) }
            try await exchange(sender: sender, receiver: receiver, success: true)
        }
        print("PASS: registered TLS identities, offline cached approval, certificate renewal, and direction checks")

        let other = NearbyProbe(), selected = NearbyProbe()
        try other.load(registeredIdentity: identityC.tlsIdentity(), approval: otherApproval, store: c)
        try selected.load(registeredIdentity: localB, approval: approval, store: b)
        try await exchange(sender: other, receiver: selected, success: false)
        print("PASS: selected approval rejects another registered peer's TLS key")

        let wrong = DeviceIdentity.ephemeralForCheck()
        let wrongIdentity = try wrong.tlsIdentity()
        let unapproved = NearbyProbe(), receiving = NearbyProbe()
        // A caller cannot associate a private key with another registered device.
        try PeerCheck.rejected { try unapproved.load(registeredIdentity: wrongIdentity, approval: approval, store: a) }
        try unapproved.load(registeredIdentity: localA, approval: approval, store: a)
        try receiving.load(registeredIdentity: localB, approval: approval, store: b)
        // Revoke B's local permission while a listener is running; no server access is used.
        let stopped: Bool = await withCheckedContinuation { continuation in
            var resolved = false
            var watchdog: Task<Void, Never>?
            let finish: (Bool) -> Void = { result in
                guard !resolved else { return }; resolved = true
                watchdog?.cancel(); receiving.stop(); receiving.onEvent = nil
                continuation.resume(returning: result)
            }
            watchdog = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { finish(false) } }
            receiving.onEvent = { event in
                if case .listening = event { Task { try await b.revoke(approval.id) } }
                if case .failed(let reason) = event { finish(reason == "Sharing approval was removed") }
            }
            do { try receiving.listen(localOnly: true) } catch { finish(false) }
        }
        try PeerCheck.expect(stopped, "Removing consent did not stop listener")
        // Reusing the loaded identities cannot bypass the recipient's local removal.
        try await exchange(sender: unapproved, receiver: receiving, success: false)
        print("PASS: mismatched local identity rejected and local revocation immediately stops nearby access")
    }

    private static func exchange(sender: NearbyProbe, receiver: NearbyProbe, success: Bool) async throws {
        let result: Bool = await withCheckedContinuation { continuation in
            var resolved = false
            var watchdog: Task<Void, Never>?
            let finish: (Bool) -> Void = { value in
                guard !resolved else { return }; resolved = true
                watchdog?.cancel(); sender.stop(); receiver.stop()
                sender.onEvent = nil; receiver.onEvent = nil
                continuation.resume(returning: value)
            }
            watchdog = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { finish(false) } }
            receiver.onEvent = { event in
                switch event {
                case .listening(let port):
                    do { try sender.connectLoopback(port: port) } catch { finish(false) }
                case .failed(let reason):
                    if success { print(reason); finish(false) }
                    else if reason == "Sharing approval was removed" { finish(true) }
                case .rejectedPeer: finish(!success)
                case .completed: break
                }
            }
            sender.onEvent = { event in
                switch event {
                case .completed: finish(success)
                case .rejectedPeer: finish(!success)
                case .failed(let reason): if success { print(reason); finish(false) }
                case .listening: break
                }
            }
            do { try receiver.listen(localOnly: true) } catch { finish(false) }
        }
        try PeerCheck.expect(result, "Registered nearby exchange had the wrong outcome")
    }
}

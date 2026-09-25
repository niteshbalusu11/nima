import Foundation
import CryptoKit

@main
struct PeerCheck {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw PeerStore.failure(message) }
    }
    static func rejected(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw PeerStore.failure("Invalid cache was accepted")
    }
    @MainActor
    static func main() async throws {
        struct Configuration: Decodable { let baseUrl: URL; var sessionA: Session; var sessionB: Session; let cacheRoot: String }
        var config = try API.decoder.decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let root = URL(fileURLWithPath: config.cacheRoot, isDirectory: true)
        let apiA = API(baseURL: config.baseUrl, token: config.sessionA.token)
        let apiB = API(baseURL: config.baseUrl, token: config.sessionB.token)
        let identityA = DeviceIdentity.ephemeralForCheck(), identityB = DeviceIdentity.ephemeralForCheck()
        let deviceA = try await identityA.register(using: apiA, session: config.sessionA)
        let deviceB = try await identityB.register(using: apiB, session: config.sessionB)
        config.sessionA.deviceId = deviceA.id; config.sessionB.deviceId = deviceB.id
        let a = try PeerStore(api: apiA, session: config.sessionA, device: deviceA, root: root)
        let b = try PeerStore(api: apiB, session: config.sessionB, device: deviceB, root: root)
        func restoreA(_ directory: URL) throws -> PeerStore {
            try PeerStore(api: apiA, session: config.sessionA, device: deviceA, root: directory)
        }
        let permission = try await PairingFixture.approve(a, b, identityA, identityB)
        let approval = await a.snapshot().approvals[0]
        try expect(approval.sender == deviceA && approval.recipient == deviceB, "Wrong direction")
        try expect(await restoreA(root).snapshot().approvals == [approval], "Offline restart lost approvals")
        let isolatedURL = URL(string: "https://other.invalid")!
        let isolated = try PeerStore(api: API(baseURL: isolatedURL, token: config.sessionA.token), session: config.sessionA, device: deviceA, root: root)
        try expect(await isolated.snapshot().approvals.isEmpty, "Environment reused trust")

        let _: OK = try await apiA.request("POST", "test/hold-next-snapshot")
        let refreshing = Task { try await a.refresh() }
        let _: OK = try await apiA.request("POST", "test/wait-for-snapshot")
        try await a.revoke(approval.id)
        try expect(await a.snapshot().approvals.isEmpty, "Local removal waited for network")
        let _: OK = try await apiA.request("POST", "test/release-snapshot")
        try await refreshing.value
        let stale = await a.snapshot()
        try expect(stale.approvals.isEmpty && stale.pendingRevocations == 1, "Stale snapshot undid local removal")
        let offline = try restoreA(root)
        try expect(await offline.snapshot().approvals.isEmpty, "Restart forgot removal")
        try await a.refresh()
        try expect(await a.snapshot().pendingRevocations == 0, "Removal not reconciled")
        do { try await a.savePairing(permission); throw PeerStore.failure("Revoked permission accepted") }
        catch let error as APIError { try expect(error.message == "Sharing permission removed; pair again", "Wrong replay result") }
        try expect(await b.snapshot().approvals == [approval], "Fixture needs a stale recipient cache")
        try await PairingFixture.approve(a, b, identityA, identityB)
        let renewed = await a.snapshot().approvals[0]
        try expect(renewed.id != approval.id, "Fresh consent reused revoked approval")
        try expect(await b.snapshot().approvals == [renewed], "Fresh consent failed to replace stale direction")

        let scope = Data((config.baseUrl.absoluteString + "\n" + deviceA.accountId + "\n" + deviceA.id).utf8)
        let name = SHA256.hash(data: scope).map { String(format: "%02x", $0) }.joined() + ".json"
        let original = try Data(contentsOf: root.appendingPathComponent(name))
        let fixture = root.deletingLastPathComponent().appendingPathComponent("invalid-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let target = fixture.appendingPathComponent(name)
        var json = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var owner = json["device"] as! [String: Any]
        owner["accountId"] = deviceB.accountId; json["device"] = owner
        try JSONSerialization.data(withJSONObject: json).write(to: target)
        try rejected { _ = try restoreA(fixture) }
        try Data(repeating: 0, count: 1_048_577).write(to: target)
        try rejected { _ = try restoreA(fixture) }
        try original.write(to: target)
        let failedDisk = try restoreA(fixture)
        try FileManager.default.removeItem(at: fixture)
        try Data().write(to: fixture) // A regular file cannot hold the cache file.
        do { try await failedDisk.revoke(renewed.id); throw PeerStore.failure("Removal falsely reported durable") }
        catch let error as APIError { throw error }
        catch { /* Expected filesystem failure. */ }
        try expect(await failedDisk.snapshot().approvals.isEmpty, "Failed persistence left trust usable")
        try rejected { _ = try restoreA(fixture) }

        let _: OK = try await apiA.request("DELETE", "devices/\(deviceA.id)")
        do { try await a.refresh(); throw PeerStore.failure("Revoked device refreshed approvals") }
        catch let error as APIError { try expect(error.status == 403, "Wrong device revocation result") }
        let inactive = await a.snapshot()
        try expect(!inactive.accessActive && inactive.approvals.isEmpty, "Known device revocation kept cached permission")
        try expect(!(await restoreA(root).snapshot().accessActive), "Restart restored revoked device")
        let _: Profile = try await apiA.request("GET", "me")
        print("PASS: Swift peer approvals, offline restart, stale-sync revocation, fresh consent, cache isolation, and fail-closed persistence")
    }
}

import Foundation
import Security
import UIKit

// Runs as a separately signed, disposable simulator app; never uses the real app's access group.
@main
final class DeviceKeychainApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task {
            do { try await DeviceKeychainCheck.run(); exit(0) }
            catch { print("FAIL: Keychain check: \(error)"); exit(1) }
        }
        return true
    }
}

struct DeviceKeychainCheck {
    static func run() async throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "UploadVideo.nearby.identity.v1",
                                   kSecAttrSynchronizable as String: false,
                                   kSecUseDataProtectionKeychain as String: true]
        if CommandLine.arguments.last == "cleanup" {
            let status = SecItemDelete(query as CFDictionary)
            precondition(status == errSecSuccess || status == errSecItemNotFound)
            return
        }
        struct Configuration: Decodable { let baseUrl: URL; let session: Session }
        let config = try API.decoder.decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let api = API(baseURL: config.baseUrl, token: config.session.token)
        let identity = try DeviceIdentity.loadOrCreate(for: config.session, at: config.baseUrl)
        let first = try await identity.register(using: api, session: config.session)
        if CommandLine.arguments.last == "persist" {
            print("PASS: simulator identity persisted")
            return
        }
        defer {
            let status = SecItemDelete(query as CFDictionary)
            precondition(status == errSecSuccess || status == errSecItemNotFound)
        }
        var bound = config.session
        bound.deviceId = first.id
        let restored = try DeviceIdentity.loadOrCreate(for: bound, at: config.baseUrl)
        let second = try await restored.register(using: api, session: bound)
        precondition(first == second)
        // Another account or API environment must get independent keys.
        let anotherAccount = Session(token: config.session.token, accountId: UUID().uuidString, role: .member)
        let isolated = [try DeviceIdentity.loadOrCreate(for: anotherAccount, at: config.baseUrl),
                        try DeviceIdentity.loadOrCreate(for: config.session, at: config.baseUrl.appendingPathComponent("another-environment"))]
        for identity in isolated {
            do {
                _ = try await identity.register(using: api, session: bound)
                fatalError("Account/environment shared keys")
            } catch let error as APIError { precondition(error.status == 409) }
        }
        var attributes = query
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        precondition(SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess)
        let items = result as! [[String: Any]]
        precondition(items.count == 3)
        for item in items {
            precondition(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            precondition((item[kSecAttrSynchronizable as String] as? Bool) != true)
        }
        // Corruption must surface an error rather than replacing a registered identity.
        precondition(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("invalid".utf8)] as CFDictionary) == errSecSuccess)
        do {
            _ = try DeviceIdentity.loadOrCreate(for: bound, at: config.baseUrl)
            fatalError("Corrupt identity was replaced")
        } catch { }
        precondition(SecItemDelete(query as CFDictionary) == errSecSuccess)
        do {
            _ = try DeviceIdentity.loadOrCreate(for: bound, at: config.baseUrl)
            fatalError("Missing registered keys were replaced")
        } catch { }
        print("PASS: Swift device registration with persistent, isolated, device-only Keychain keys")
    }
}

import Foundation

@main
struct DeviceIdentityCheck {
    static func main() async throws {
        struct Configuration: Decodable { let baseUrl: URL; let session: Session }
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: identity-check private-session-file") }
        let config = try API.decoder.decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        precondition(config.session.deviceId == nil, "Legacy session should decode without a device")
        let identity = DeviceIdentity.ephemeralForCheck()
        let api = API(baseURL: config.baseUrl, token: config.session.token)
        let first = try await identity.register(using: api, session: config.session)
        var bound = config.session
        bound.deviceId = first.id
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(bound))
        precondition(restored.deviceId == first.id && restored.token == config.session.token)
        let second = try await identity.register(using: api, session: restored)
        precondition(first == second, "Registration retry changed identity")
        let current: RegisteredDevice = try await api.request("GET", "devices/current")
        precondition(current == first)
        do {
            _ = try await DeviceIdentity.ephemeralForCheck().register(using: api, session: bound)
            fatalError("Bound session replaced its keys")
        } catch let error as APIError { precondition(error.status == 409) }
        print("PASS: Swift device registration, session migration, retry, and key conflict")
    }
}

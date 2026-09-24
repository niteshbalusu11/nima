import Foundation
import Security

struct Session: Codable, Sendable {
    let token: String
    let accountId: String
}
struct Profile: Codable, Sendable {
    var id = ""
    var name = ""
    var email = ""
    var signalUsername = ""
}
struct APIError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}
struct API: Sendable {
    let baseURL: URL
    let token: String?
    static var configuredURL: URL {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["API_BASE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
            ?? "http://127.0.0.1:8080"
        #else
        let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String ?? ""
        #endif
        guard let url = URL(string: value), url.host != nil else {
            preconditionFailure("Set API_BASE_URL in Configuration/Local.xcconfig")
        }
        #if !DEBUG
        precondition(url.scheme == "https", "Release builds require an HTTPS API_BASE_URL")
        #endif
        return url
    }
    func request<Response: Decodable & Sendable>(_ method: String, _ path: String, body: Data? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "Try again"
            throw APIError(status: http.statusCode, message: message)
        }
        return try Self.decoder.decode(Response.self, from: data)
    }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; return try encoder.encode(value)
    }
    private struct ServerError: Decodable { let error: String }
}
struct OK: Decodable, Sendable { let ok: Bool }

enum SessionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "UploadVideo.session",
         kSecAttrAccount as String: API.configuredURL.absoluteString,
         kSecAttrSynchronizable as String: false]
    }
    static func load() -> Session? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
    static func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status != errSecSuccess { throw APIError(status: Int(status), message: "Could not save sign-in") }
        } else if result != errSecSuccess { throw APIError(status: Int(result), message: "Could not save sign-in") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

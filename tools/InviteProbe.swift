import Foundation

@main
struct InviteProbe {
    static func main() throws {
        let token = "Ab9_-" + String(repeating: "z", count: 38)
        for input in [token, InviteToken.prefix + token, " \n" + token + "\t", "\n" + InviteToken.prefix + token + " "] {
            precondition(InviteToken.parse(input) == token)
        }
        for input in ["", "invalid", String(token.dropLast()), token + "z", "https://example.test/" + token,
                      String(repeating: "é", count: 43), String(repeating: "/", count: 43), token + "\nmore"] {
            precondition(InviteToken.parse(input) == nil)
        }
        for role in ["admin", "member"] {
            let data = Data("{\"token\":\"session\",\"account_id\":\"account\",\"role\":\"\(role)\"}".utf8)
            let session = try API.decoder.decode(Session.self, from: data)
            precondition(session.role.rawValue == role && session.accountId == "account")
            let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
            precondition(restored.role == session.role && restored.token == session.token)
        }
        print("Invite parsing and session role storage passed")
    }
}

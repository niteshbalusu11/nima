import Foundation

struct RelayUploadWorker: Sendable {
    let api: API
    let store: ReceivedMediaStore
    let slots: UploadSlots
    init(api: API, store: ReceivedMediaStore, slots: UploadSlots) throws {
        guard api.baseURL == store.peers.baseURL, api.token == store.peers.sessionToken else {
            throw APIError(status: 0, message: "Received copies belong to another session")
        }
        self.api = api; self.store = store; self.slots = slots
    }
    // One object per scheduling turn lets another capture proceed when one grant
    // is blocked. All requests retain B's session, never the recorder's session.
    func sendNext(captureHash: Data) async throws -> Bool {
        try await slots.run(owner: false) {
            guard let material = try await store.relayMaterial(captureHash: captureHash) else {
                throw APIError(status: 403, message: "Sharing permission unavailable", code: "local_permission")
            }
            try await store.peers.synchronizePairing(material.permission.approvalId)
            struct Redemption: Encodable { let approvalId: String; let descriptor: MediaRecords.Envelope; let grant: MediaRecords.Envelope }
            struct Redeemed: Decodable, Sendable { let id: String }
            let redeemed: Redeemed = try await api.request("POST", "relay-grants/redeem", body: API.encode(Redemption(
                approvalId: material.permission.approvalId, descriptor: material.descriptor, grant: material.grant)))
            guard redeemed.id == material.permission.id else { throw URLError(.badServerResponse) }
            let route = "relay-grants/" + redeemed.id
            if let object = material.object, let sequence = material.sequence {
                struct Reservation: Decodable, Sendable { let acknowledged: Bool; let url: String?; let headers: [String: String]? }
                let reservation: Reservation = try await api.request("POST", route + "/objects/reserve", body: API.encode(["manifest": object.manifest]))
                try await checkPermission(material, captureHash: captureHash)
                if !reservation.acknowledged {
                    guard let value = reservation.url, let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { throw URLError(.badURL) }
                    #if !DEBUG
                    guard url.scheme == "https" else { throw URLError(.appTransportSecurityRequiresSecureConnection) }
                    #endif
                    var request = URLRequest(url: url); request.httpMethod = "PUT"; request.timeoutInterval = 30
                    for (name, value) in reservation.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
                    let (_, response) = try await URLSession.shared.upload(for: request, fromFile: object.file)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200..<300).contains(http.statusCode) || http.statusCode == 412 else {
                        throw APIError(status: 503, message: "Cloud upload paused")
                    }
                    try await checkPermission(material, captureHash: captureHash)
                    let _: OK = try await api.request("POST", route + "/objects/ack", body: API.encode(["sequence": sequence]))
                }
                try Task.checkCancellation()
                try await store.markCloudObject(captureHash: captureHash, sequence: sequence)
                return true
            }
            try await checkPermission(material, captureHash: captureHash)
            if let completion = material.completion {
                let _: OK = try await api.request("POST", route + "/completion", body: API.encode(["completion": completion]))
            }
            struct Status: Decodable, Sendable { let cloudComplete: Bool }
            let status: Status = try await api.request("POST", route + "/status", body: API.encode([String: String]()))
            try Task.checkCancellation()
            await store.markCloudComplete(captureHash: captureHash, complete: status.cloudComplete)
            return false
        }
    }
    private func checkPermission(_ material: ReceivedMediaStore.RelayMaterial, captureHash: Data) async throws {
        try Task.checkCancellation()
        guard try await store.relayGrants(captureHash: captureHash).contains(material.grant) else {
            throw APIError(status: 403, message: "Sharing permission changed", code: "local_permission")
        }
    }
}

import Foundation
import CryptoKit

// Fixed-width v1 payloads; JSON is only an envelope, never signature input.
// See docs/signed-media-protocol.md before changing any encoding or validation.
enum MediaRecords {
    static let maxObject = 12 * 1024 * 1024
    static let maxCapture = Int64(3 * 1024 * 1024 * 1024)
    static let maxSequence = 100_000
    static let grantLifetime: Int64 = 30 * 86400
    static let clockSkew: Int64 = 300
    enum CaptureKind: UInt8, Sendable { case video = 1, photo = 2 }
    enum ObjectKind: UInt8, Sendable { case initialization = 1, media = 2, photo = 3 }
    enum Ending: UInt8, Sendable { case stopped = 1, interrupted = 2 }
    struct Descriptor: Equatable, Sendable {
        let captureId: String
        let recorderAccountId: String
        let recorderDeviceId: String
        let signingKeyHash: Data
        let kind: CaptureKind
        let createdAt: Int64
    }
    struct Grant: Equatable, Sendable {
        let id: String
        let descriptorHash: Data
        let senderDeviceId: String
        let recipientAccountId: String
        let recipientDeviceId: String
        let approvalId: String
        let issuedAt: Int64
        let expiresAt: Int64
        let byteLimit: Int64
        func checkTime(_ now: Int64) throws {
            guard now >= 0, now <= Int64.max - clockSkew, issuedAt <= now + clockSkew, expiresAt > now else { throw failure("Sharing permission expired or is not yet valid") }
        }
    }
    struct Manifest: Equatable, Sendable {
        let descriptorHash: Data
        let sequence: Int
        let kind: ObjectKind
        let size: Int
        let sha256: Data
        let md5: Data
        let duration: Double
        let startTime: Double
    }
    struct Completion: Equatable, Sendable {
        let descriptorHash: Data
        let ending: Ending
        let lastSequence: Int
        let objectCount: Int
        let totalBytes: Int64
    }
    enum Record: Equatable, Sendable {
        case descriptor(Descriptor), grant(Grant), manifest(Manifest), completion(Completion)
        func encoded() throws -> Data {
            var w = Writer()
            switch self {
            case .descriptor(let d):
                w.domain("capture"); try w.uuid(d.captureId); try w.id(d.recorderAccountId); try w.id(d.recorderDeviceId)
                try w.bytes(d.signingKeyHash, count: 32); w.byte(d.kind.rawValue); try w.number(d.createdAt)
            case .grant(let g):
                w.domain("grant"); try w.id(g.id); try w.bytes(g.descriptorHash, count: 32); try w.id(g.senderDeviceId)
                try w.id(g.recipientAccountId); try w.id(g.recipientDeviceId); try w.id(g.approvalId)
                w.byte(1); w.byte(1) // destination primary; upload signed material only
                try w.number(g.issuedAt); try w.number(g.expiresAt); try w.number(g.byteLimit)
            case .manifest(let m):
                w.domain("object"); try w.bytes(m.descriptorHash, count: 32); try w.sequence(m.sequence)
                w.byte(m.kind.rawValue); try w.number(Int64(m.size)); try w.bytes(m.sha256, count: 32); try w.bytes(m.md5, count: 16)
                w.bits(m.duration.bitPattern); w.bits(m.startTime.bitPattern)
            case .completion(let c):
                w.domain("completion"); try w.bytes(c.descriptorHash, count: 32); w.byte(c.ending.rawValue)
                try w.sequence(c.lastSequence); try w.sequence(c.objectCount); try w.number(c.totalBytes)
            }
            // One set of constraints for locally generated and received records.
            _ = try Record.decode(w.data)
            return w.data
        }
        static func decode(_ data: Data) throws -> Record {
            var r = Reader(data)
            let record: Record
            switch try r.domain() {
            case "capture":
                let capture = try r.uuid(), account = try r.id(), device = try r.id(), key = try r.bytes(32)
                guard let kind = CaptureKind(rawValue: try r.byte()) else { throw failure("Unknown capture kind") }
                let created = try r.number()
                guard created > 0 else { throw failure("Invalid capture time") }
                record = .descriptor(Descriptor(captureId: capture, recorderAccountId: account, recorderDeviceId: device,
                                                signingKeyHash: key, kind: kind, createdAt: created))
            case "grant":
                let id = try r.id(), hash = try r.bytes(32), sender = try r.id(), account = try r.id(), recipient = try r.id(), approval = try r.id()
                guard try r.byte() == 1, try r.byte() == 1 else { throw failure("Unsupported sharing scope or destination") }
                let issued = try r.number(), expires = try r.number(), limit = try r.number()
                guard issued > 0, expires > issued, expires - issued <= grantLifetime, limit > 0, limit <= maxCapture, sender != recipient else {
                    throw failure("Invalid sharing permission")
                }
                record = .grant(Grant(id: id, descriptorHash: hash, senderDeviceId: sender, recipientAccountId: account,
                                      recipientDeviceId: recipient, approvalId: approval, issuedAt: issued, expiresAt: expires, byteLimit: limit))
            case "object":
                let hash = try r.bytes(32), sequence = try r.sequence()
                guard let kind = ObjectKind(rawValue: try r.byte()) else { throw failure("Unknown object kind") }
                let size = try r.number(), sha = try r.bytes(32), md5 = try r.bytes(16)
                let duration = Double(bitPattern: try r.bits()), start = Double(bitPattern: try r.bits())
                guard sequence <= maxSequence, size > 0, size <= maxObject,
                      duration.isFinite, duration >= 0, duration <= 60, start.isFinite, start >= 0, start <= 6_000_000,
                      duration != 0 || duration.bitPattern == 0, start != 0 || start.bitPattern == 0,
                      kind == .media ? sequence > 0 : (sequence == 0 && duration == 0 && start == 0) else { throw failure("Invalid media metadata") }
                record = .manifest(Manifest(descriptorHash: hash, sequence: sequence, kind: kind, size: Int(size), sha256: sha, md5: md5, duration: duration, startTime: start))
            case "completion":
                let hash = try r.bytes(32)
                guard let ending = Ending(rawValue: try r.byte()) else { throw failure("Unknown ending") }
                let last = try r.sequence(), count = try r.sequence(), total = try r.number()
                guard last <= maxSequence, count == last + 1, total >= count, total <= maxCapture,
                      total <= Int64(count) * Int64(maxObject) else { throw failure("Invalid completion") }
                record = .completion(Completion(descriptorHash: hash, ending: ending, lastSequence: last, objectCount: count, totalBytes: total))
            default: throw failure("Unsupported signed record")
            }
            guard r.offset == data.count else { throw failure("Trailing signed data") }
            return record
        }
    }
    struct Envelope: Codable, Equatable, Sendable {
        let payload: String
        let signature: String
        var bytes: Data { get throws { try decodeURL(payload, limit: 512) } }
        var digest: Data { get throws { Data(SHA256.hash(data: try bytes)) } }
        func verified(by recorder: RegisteredDevice) throws -> Record {
            let data = try bytes, signature = try decodeURL(signature, limit: 80)
            guard recorder.isValid, let key = DeviceIdentity.decodeURL(recorder.signingPublicKey),
                  let publicKey = try? P256.Signing.PublicKey(x963Representation: key),
                  let proof = try? P256.Signing.ECDSASignature(derRepresentation: signature),
                  publicKey.isValidSignature(proof, for: data) else { throw failure("Invalid recorder signature") }
            return try Record.decode(data)
        }
    }
    struct Capture: Sendable {
        let envelope: Envelope
        let recorder: RegisteredDevice
        let descriptor: Descriptor
        let digest: Data
        init(_ envelope: Envelope, recorder: RegisteredDevice) throws {
            guard case .descriptor(let d) = try envelope.verified(by: recorder),
                  d.recorderAccountId == recorder.accountId, d.recorderDeviceId == recorder.id,
                  let key = DeviceIdentity.decodeURL(recorder.signingPublicKey),
                  d.signingKeyHash == Data(SHA256.hash(data: key)) else { throw failure("Capture has the wrong recorder") }
            self.envelope = envelope; self.recorder = recorder; descriptor = d; digest = try envelope.digest
        }
        func checkTime(_ now: Int64) throws {
            guard now >= 0, now <= Int64.max - clockSkew, descriptor.createdAt <= now + clockSkew else { throw failure("Capture is in the future") }
        }
        func grant(_ envelope: Envelope, approval: PeerApproval) throws -> Grant {
            guard case .grant(let g) = try envelope.verified(by: recorder), g.descriptorHash == digest,
                  approval.sender == recorder, g.senderDeviceId == recorder.id, approval.id == g.approvalId,
                  approval.recipient.isValid, g.recipientDeviceId == approval.recipient.id,
                  g.recipientAccountId == approval.recipient.accountId,
                  descriptor.kind != .photo || g.byteLimit <= maxObject else { throw failure("Sharing permission has the wrong participants or capture") }
            return g
        }
        func manifest(_ envelope: Envelope) throws -> Manifest {
            guard case .manifest(let m) = try envelope.verified(by: recorder), m.descriptorHash == digest,
                  (descriptor.kind == .photo) == (m.kind == .photo) else { throw failure("Object belongs to another capture") }
            return m
        }
        func completion(_ envelope: Envelope) throws -> Completion {
            guard case .completion(let c) = try envelope.verified(by: recorder), c.descriptorHash == digest,
                  descriptor.kind != .photo || (c.lastSequence == 0 && c.totalBytes <= maxObject) else { throw failure("Completion belongs to another capture") }
            return c
        }
    }
    static func sign(_ record: Record, with identity: DeviceIdentity) throws -> Envelope {
        let bytes = try record.encoded()
        return Envelope(payload: DeviceIdentity.encodeURL(bytes), signature: DeviceIdentity.encodeURL(try identity.signMedia(bytes)))
    }
    static func decodeURL(_ value: String, limit: Int) throws -> Data {
        guard value.utf8.count <= (limit * 4 + 2) / 3 else { throw failure("Signed record is too large") }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)),
              data.count <= limit, DeviceIdentity.encodeURL(data) == value else { throw failure("Invalid signed record encoding") }
        return data
    }
    static func failure(_ message: String) -> APIError { APIError(status: 0, message: message) }
    private struct Writer {
        var data = Data()
        mutating func domain(_ kind: String) { data.append(Data("uploadvideo.media.\(kind).v1\0".utf8)) }
        mutating func byte(_ value: UInt8) { data.append(value) }
        mutating func bytes(_ bytes: Data, count: Int) throws { guard bytes.count == count else { throw failure("Wrong field length") }; data.append(bytes) }
        mutating func id(_ id: String) throws {
            guard RegisteredDevice.validID(id) else { throw failure("Invalid identifier") }
            for i in stride(from: 0, to: 32, by: 2) {
                let start = id.index(id.startIndex, offsetBy: i), end = id.index(start, offsetBy: 2)
                data.append(UInt8(id[start..<end], radix: 16)!)
            }
        }
        mutating func uuid(_ id: String) throws {
            guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw failure("Invalid capture UUID") }
            try self.id(id.replacingOccurrences(of: "-", with: ""))
        }
        mutating func sequence(_ value: Int) throws {
            guard value >= 0, value <= maxSequence + 1 else { throw failure("Invalid sequence") }
            var n = UInt32(value).bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        }
        mutating func number(_ value: Int64) throws { guard value >= 0 else { throw failure("Invalid negative field") }; bits(UInt64(value)) }
        mutating func bits(_ value: UInt64) { var n = value.bigEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    }
    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        mutating func bytes(_ count: Int) throws -> Data {
            guard count <= data.count - offset else { throw failure("Truncated signed record") }
            defer { offset += count }; return data.subdata(in: offset..<offset + count)
        }
        mutating func byte() throws -> UInt8 { try bytes(1)[0] }
        mutating func bits() throws -> UInt64 { try bytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
        mutating func number() throws -> Int64 { let n = try bits(); guard n <= Int64.max else { throw failure("Integer overflow") }; return Int64(n) }
        mutating func sequence() throws -> Int { try bytes(4).reduce(0) { ($0 << 8) | Int($1) } }
        mutating func id() throws -> String { try bytes(16).map { String(format: "%02x", $0) }.joined() }
        mutating func uuid() throws -> String {
            let b = Array(try bytes(16))
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])).uuidString.lowercased()
        }
        mutating func domain() throws -> String {
            guard data.count <= 512, let end = data.firstIndex(of: 0), end < 48,
                  let text = String(data: data.prefix(end), encoding: .utf8) else { throw failure("Invalid signed domain") }
            for kind in ["capture", "grant", "object", "completion"] where text == "uploadvideo.media.\(kind).v1" {
                offset = end + 1; return kind
            }
            throw failure("Unsupported signed domain")
        }
    }
}

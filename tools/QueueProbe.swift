import Foundation

@main
struct QueueProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try UploadQueue(root: root)
        try queue.enqueue(Data("init".utf8), accountId: "one", captureId: "video", captureKind: "video", sequence: 0, kind: "init")
        try queue.enqueue(Data("fragment".utf8), accountId: "one", captureId: "video", captureKind: "video", sequence: 1, kind: "media", duration: 1.2, startTime: 100)
        try queue.enqueue(Data("photo".utf8), accountId: "two", captureId: "photo", captureKind: "photo", sequence: 0, kind: "photo")
        // Reconstruct after termination/offline capture; no networking has taken place.
        let restored = try UploadQueue(root: root)
        precondition(restored.pending(accountId: "one") == 2)
        precondition(restored.pending(accountId: "two") == 1)
        precondition(restored.next(accountId: "one", captureKind: "photo") == nil)
        let initialization = restored.next(accountId: "one", captureKind: "video")!
        precondition(initialization.sequence == 0)
        let original = try Data(contentsOf: restored.file(initialization))
        precondition(original == Data("init".utf8))
        try restored.acknowledge(initialization)
        let reopened = try UploadQueue(root: root)
        let fragment = reopened.next(accountId: "one", captureKind: "video")!
        precondition(fragment.sequence == 1 && fragment.duration == 1.2 && fragment.startTime == 100)
        precondition(FileManager.default.fileExists(atPath: reopened.file(initialization).path))
        print("PASS: offline queue survives relaunch; ordered init, account isolation, durable ack, retained originals")
    }
}

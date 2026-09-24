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
        // Photos export includes acknowledged fragments and refuses missing pieces or another owner's media.
        let parts = try reopened.videoParts(accountId: "one", captureId: "video")
        precondition(parts == [reopened.file(initialization), reopened.file(fragment)])
        precondition((try? reopened.videoParts(accountId: "two", captureId: "video")) == nil)
        try reopened.enqueue(Data("init".utf8), accountId: "one", captureId: "gap", captureKind: "video", sequence: 0, kind: "init")
        try reopened.enqueue(Data("fragment".utf8), accountId: "one", captureId: "gap", captureKind: "video", sequence: 2, kind: "media")
        precondition((try? reopened.videoParts(accountId: "one", captureId: "gap")) == nil)
        try reopened.enqueue(Data("init".utf8), accountId: "one", captureId: "empty", captureKind: "video", sequence: 0, kind: "init")
        precondition((try? reopened.videoParts(accountId: "one", captureId: "empty")) == nil)
        print("PASS: offline queue survives relaunch; ordered init, account isolation, durable ack, retained originals")
    }
}

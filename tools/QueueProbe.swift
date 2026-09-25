import Foundation

@main
struct QueueProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try UploadQueue(root: root)
        let location = CaptureLocation(latitude: 40.7128, longitude: -74.006, horizontalAccuracyM: 12.5, timestamp: 1_790_000_000)
        try queue.enqueue(Data("init".utf8), accountId: "one", captureId: "video", captureKind: "video", sequence: 0, kind: "init", location: location)
        try queue.enqueue(Data("fragment".utf8), accountId: "one", captureId: "video", captureKind: "video", sequence: 1, kind: "media", duration: 1.2, startTime: 100, location: location)
        try queue.enqueue(Data("photo".utf8), accountId: "two", captureId: "photo", captureKind: "photo", sequence: 0, kind: "photo")
        // Reconstruct after termination/offline capture; no networking has taken place.
        let restored = try UploadQueue(root: root)
        precondition(restored.pending(accountId: "one") == 2)
        precondition(restored.pending(accountId: "two") == 1)
        precondition(restored.next(accountId: "one", captureKind: "photo") == nil)
        let gallery = restored.captures(accountId: "one")
        precondition(gallery.count == 1 && gallery[0].id == "video" && !gallery[0].uploaded && gallery[0].playable)
        precondition(gallery[0].duration == 1.2 && gallery[0].parts.count == 2)
        let initialization = restored.next(accountId: "one", captureKind: "video")!
        precondition(initialization.sequence == 0 && initialization.location == location)
        precondition(restored.next(accountId: "two", captureKind: "photo")?.location == nil)
        let encodedLocation = try JSONSerialization.jsonObject(with: API.encode(location)) as! [String: Any]
        precondition(encodedLocation["horizontal_accuracy_m"] as? Double == 12.5)
        let original = try Data(contentsOf: restored.file(initialization))
        precondition(original == Data("init".utf8))
        try restored.acknowledge(initialization)
        try restored.finishCapture(accountId: "one", captureId: "video", ending: .stopped, expectedObjects: 2)
        precondition(!restored.captures(accountId: "one")[0].uploaded)
        let reopened = try UploadQueue(root: root)
        let fragment = reopened.next(accountId: "one", captureKind: "video")!
        precondition(fragment.sequence == 1 && fragment.duration == 1.2 && fragment.startTime == 100 && fragment.location == location)
        precondition(FileManager.default.fileExists(atPath: reopened.file(initialization).path))
        // Photos export includes acknowledged fragments and refuses missing pieces or another owner's media.
        let parts = try reopened.videoParts(accountId: "one", captureId: "video")
        precondition(parts == [reopened.file(initialization), reopened.file(fragment)])
        precondition((try? reopened.videoParts(accountId: "two", captureId: "video")) == nil)
        try reopened.acknowledge(fragment)
        let finished = try UploadQueue(root: root).retainedObjects(accountId: "one", captureId: "video")
        precondition(finished.last?.terminal?.ending == .stopped)
        let uploaded = try UploadQueue(root: root).captures(accountId: "one")
        precondition(uploaded.count == 1 && uploaded[0].uploaded)
        try reopened.enqueue(Data("init".utf8), accountId: "one", captureId: "gap", captureKind: "video", sequence: 0, kind: "init")
        try reopened.enqueue(Data("fragment".utf8), accountId: "one", captureId: "gap", captureKind: "video", sequence: 2, kind: "media")
        precondition((try? reopened.videoParts(accountId: "one", captureId: "gap")) == nil)
        do {
            try reopened.finishCapture(accountId: "one", captureId: "gap", ending: .stopped, expectedObjects: 2)
            preconditionFailure("gapped recording got a terminal record")
        } catch {}
        precondition(reopened.captures(accountId: "one").first?.id == "gap")
        precondition(reopened.captures(accountId: "one").first?.playable == false)
        try reopened.enqueue(Data("init".utf8), accountId: "one", captureId: "empty", captureKind: "video", sequence: 0, kind: "init")
        precondition((try? reopened.videoParts(accountId: "one", captureId: "empty")) == nil)
        // Deletion removes every fragment, preserves other accounts, and survives a restart.
        let backedUp = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: backedUp) }
        let originalFolder = reopened.file(initialization).deletingLastPathComponent()
        try FileManager.default.copyItem(at: originalFolder, to: backedUp)
        try reopened.remove(accountId: "one", captureId: "video")
        precondition(!FileManager.default.fileExists(atPath: originalFolder.path))
        precondition(!FileManager.default.fileExists(atPath: reopened.file(fragment).path))
        try reopened.acknowledge(initialization) // A late acknowledgment cannot recreate it.
        try reopened.remove(accountId: "one", captureId: "video")
        // Simulate interruption after committing deletion but before unlinking the original.
        try FileManager.default.copyItem(at: backedUp, to: originalFolder)
        let afterDelete = try UploadQueue(root: root)
        precondition(!FileManager.default.fileExists(atPath: originalFolder.path))
        precondition(!afterDelete.captures(accountId: "one").contains { $0.id == "video" })
        precondition(afterDelete.pending(accountId: "two") == 1)
        do {
            try afterDelete.enqueue(Data("late".utf8), accountId: "one", captureId: "video", captureKind: "video", sequence: 2, kind: "media")
            preconditionFailure("deleted capture accepted more fragments")
        } catch let error as APIError { precondition(error.status == 410) }
        print("PASS: durable deletion, interrupted removal, no resurrection, account isolation")
        print("PASS: offline queue, account isolation, retained originals, gallery grouping, newest first, pending-to-uploaded status")
    }
}

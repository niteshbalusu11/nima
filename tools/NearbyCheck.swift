import Foundation

@main
struct NearbyProbeCheck {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: nearby-probe fixture-directory") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for (name, success) in [("a", true), ("unapproved-client", false), ("wrong-server", false)] {
            let sender = NearbyProbe(), receiver = NearbyProbe()
            try sender.load(Data(contentsOf: root.appendingPathComponent("\(name).nearby.json")))
            try receiver.load(Data(contentsOf: root.appendingPathComponent("b.nearby.json")))
            let outcome: Bool = await withCheckedContinuation { continuation in
                var resolved = false
                var watchdog: Task<Void, Never>?
                let finish: (Bool) -> Void = { result in
                    guard !resolved else { return }
                    resolved = true
                    watchdog?.cancel()
                    sender.stop(); receiver.stop()
                    sender.onEvent = nil; receiver.onEvent = nil
                    continuation.resume(returning: result)
                }
                watchdog = Task {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    finish(false)
                }
                receiver.onEvent = { event in
                    if case .listening(let port) = event {
                        do { try sender.connectLoopback(port: port) }
                        catch { finish(false) }
                    }
                    if case .failed = event, success { finish(false) }
                    if case .rejectedPeer = event { finish(!success) }
                    // A TLS rejection on the listener propagates to the sender as well.
                }
                sender.onEvent = { event in
                    switch event {
                    case .completed: finish(success)
                    case .failed(let message):
                        if success { print(message); finish(false) }
                        // A transport error alone does not prove the certificate was rejected.
                    case .rejectedPeer: finish(!success)
                    case .listening: break
                    }
                }
                do { try receiver.listen(localOnly: true) }
                catch { finish(false) }
            }
            guard outcome else {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                exit(1)
            }
            print("PASS: \(name == "a" ? "approved peers exchange and verify 256 KiB" : "reject " + name)")
        }
    }
}

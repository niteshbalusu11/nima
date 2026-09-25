import Foundation

actor UploadSlots {
    private struct Waiter { let id: UUID; let owner: Bool; let continuation: CheckedContinuation<Void, Error> }
    private var active = 0
    private var waiting: [Waiter] = []
    func run<T: Sendable>(owner: Bool, operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire(owner: owner)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire(owner: Bool) async throws {
        try Task.checkCancellation()
        if active < 2 { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, owner: owner, continuation: continuation))
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiting.isEmpty { active -= 1; return }
        let index = waiting.firstIndex(where: \.owner) ?? 0
        waiting.remove(at: index).continuation.resume()
    }
}

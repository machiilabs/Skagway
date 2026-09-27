import Foundation

/// The operation ran past its deadline. It was cancelled, but may still be running.
struct DeadlineExceeded: Error, Equatable {}

/// Returns the operation's result, or throws `DeadlineExceeded` after `seconds`.
///
/// The operation is cancelled but **not awaited**. A task group waits for every child before it
/// returns, so a decode that ignores cancellation (AV parsing a damaged MPEG-2 file) would hang
/// the caller, and any generation-gate slot it holds, forever.
func withDeadline<T: Sendable>(
    seconds: Double,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, seconds: seconds, operation: operation)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    /// Result that arrived before `start` (caller already cancelled).
    private var early: Result<T, Error>?
    private var isFinished = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(
        _ continuation: CheckedContinuation<T, Error>,
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) {
        lock.lock()
        if isFinished, let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        work = Task {
            do {
                self.finish(.success(try await operation()))
            } catch {
                self.finish(.failure(error))
            }
        }
        timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.finish(.failure(DeadlineExceeded()))
        }
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { early = result }
        let work = self.work
        let timer = self.timer
        lock.unlock()
        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}

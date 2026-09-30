/// Waits out a hedge delay. Injected so tests can decide deterministically whether a hedge fires.
public protocol HedgeSleeper: Sendable {
    /// Suspends for `duration`, throwing `CancellationError` if the task is cancelled first.
    func sleep(for duration: Duration) async throws
}

/// The production sleeper, backed by `Task.sleep`.
public struct TaskSleeper: HedgeSleeper {
    /// Creates a sleeper.
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

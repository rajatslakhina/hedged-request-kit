/// One way of serving a request: a provider, a region, a priority tier.
///
/// Attempts are tried in order. The first is the primary; the rest are hedges or failovers.
/// `operation` must be cancellation-cooperative (URLSession and `AsyncThrowingStream`
/// consumers are): the executor cancels losers, but it cannot return until they stop.
public struct HedgeAttempt<Value: Sendable>: Sendable {
    /// A name for reports, e.g. `"openrouter/standard"`.
    public let label: String
    /// Performs the request.
    public let operation: @Sendable () async throws -> Value

    /// Creates an attempt.
    public init(_ label: String, operation: @escaping @Sendable () async throws -> Value) {
        self.label = label
        self.operation = operation
    }
}

/// Why an attempt was launched.
public enum LaunchReason: String, Sendable, Equatable {
    /// The first attempt.
    case primary
    /// Launched because the attempts before it were still running after the hedge delay.
    case hedge
    /// Launched because an attempt before it failed.
    case failover
}

/// One attempt's failure, kept as text so the outcome stays `Sendable` and `Equatable`.
public struct HedgeFailure: Sendable, Equatable {
    /// The attempt's label.
    public let label: String
    /// `String(describing:)` of the thrown error.
    public let reason: String

    /// Creates a failure record.
    public init(label: String, reason: String) {
        self.label = label
        self.reason = reason
    }
}

/// An attempt that was started.
public struct LaunchedAttempt: Sendable, Equatable {
    /// The attempt's label.
    public let label: String
    /// Why it was started.
    public let reason: LaunchReason

    /// Creates a launch record.
    public init(label: String, reason: LaunchReason) {
        self.label = label
        self.reason = reason
    }
}

/// The result of a hedged request that succeeded.
public struct HedgeOutcome<Value: Sendable>: Sendable {
    /// The winning attempt's value.
    public let value: Value
    /// The winning attempt's label.
    public let winner: String
    /// Why the winner was launched. `.hedge` means hedging changed the answer's latency.
    public let winnerReason: LaunchReason
    /// Every attempt launched, in launch order, with its reason.
    public let launched: [LaunchedAttempt]
    /// Attempts that failed before the winner finished.
    public let failures: [HedgeFailure]
    /// Time from the request's start to the winner's result.
    public let latency: Duration
    /// The delay this request used before hedging.
    public let hedgeDelay: Duration
    /// `true` when a hedge was due but the budget refused it.
    public let budgetDenied: Bool

    /// The number of hedges (not failovers) this request paid for.
    public var hedgesSent: Int {
        launched.filter { $0.reason == .hedge }.count
    }
}

/// Errors a `HedgedExecutor` throws.
public enum HedgeError: Error, Sendable, Equatable {
    /// `execute` was called with no attempts.
    case noAttempts
    /// Every launched attempt failed and nothing else could be launched.
    /// `budgetDenied` is `true` when an unlaunched attempt was held back by the budget.
    case allFailed([HedgeFailure], budgetDenied: Bool)
}

/// Running counters for one executor.
public struct HedgeStats: Sendable, Equatable {
    /// Requests started.
    public var requests = 0
    /// Hedges launched.
    public var hedgesSent = 0
    /// Requests won by a hedge.
    public var hedgeWins = 0
    /// Failovers launched.
    public var failovers = 0
    /// Hedges the budget refused.
    public var budgetDenials = 0
    /// Requests where every attempt failed.
    public var exhausted = 0

    /// Creates zeroed counters.
    public init() {}

    /// Extra paid attempts per request, i.e. the hedging overhead on spend.
    public var hedgeRate: Double {
        requests == 0 ? 0 : Double(hedgesSent) / Double(requests)
    }
}

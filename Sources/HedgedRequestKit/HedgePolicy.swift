/// How long to wait for an outstanding attempt before launching the next one.
public enum HedgeDelay: Sendable, Equatable {
    /// Always wait this long.
    case fixed(Duration)
    /// Wait for the given percentile of recently observed latencies, clamped to
    /// `minimum...maximum`. Until `minimumSamples` latencies have been seen, use `fallback`.
    case percentile(Double, fallback: Duration, minimum: Duration, maximum: Duration, minimumSamples: Int)

    /// The adaptive default: hedge at p95, never sooner than 50ms or later than 5s,
    /// and wait 1s until 20 samples exist.
    public static let p95 = HedgeDelay.percentile(
        0.95, fallback: .seconds(1), minimum: .milliseconds(50), maximum: .seconds(5), minimumSamples: 20
    )

    /// Resolves the delay against the latencies observed so far.
    public func resolve(against window: LatencyWindow) -> Duration {
        switch self {
        case let .fixed(delay):
            return delay
        case let .percentile(fraction, fallback, minimum, maximum, minimumSamples):
            guard window.samples.count >= minimumSamples, let observed = window.percentile(fraction) else {
                return fallback
            }
            return min(maximum, max(minimum, observed))
        }
    }
}

/// Configuration for a `HedgedExecutor`.
public struct HedgePolicy: Sendable, Equatable {
    /// When to launch each hedge.
    public var delay: HedgeDelay
    /// The most attempts running or finished for one request, primary included.
    /// `1` disables hedging entirely.
    public var maxAttempts: Int
    /// Caps hedges relative to request volume. Failovers do not spend from it.
    public var budget: HedgeBudget
    /// When an attempt fails before the hedge delay elapses, launch the next attempt at once
    /// instead of waiting. The failed attempt is no longer costing anything, so this does not
    /// spend budget.
    public var failoverOnError: Bool
    /// How many recent winning latencies the adaptive delay considers.
    public var windowCapacity: Int

    /// Creates a policy. `maxAttempts` is clamped to at least 1.
    public init(
        delay: HedgeDelay = .p95,
        maxAttempts: Int = 2,
        budget: HedgeBudget = HedgeBudget(ratio: 0.1, burst: 10),
        failoverOnError: Bool = true,
        windowCapacity: Int = 100
    ) {
        self.delay = delay
        self.maxAttempts = max(1, maxAttempts)
        self.budget = budget
        self.failoverOnError = failoverOnError
        self.windowCapacity = windowCapacity
    }
}

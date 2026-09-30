/// A token bucket that caps how many hedges a caller may send relative to its request volume.
///
/// A hedge is a second paid request. Without a cap, a provider that slows down for everyone
/// doubles your bill at exactly the moment hedging stops helping, because both copies are slow.
/// Each request deposits `ratio` tokens (up to `burst`) and each hedge spends one, so over
/// time at most `ratio` hedges are sent per request.
public struct HedgeBudget: Sendable, Equatable {
    /// Tokens deposited per request. `0.1` allows one hedge per ten requests on average.
    public let ratio: Double
    /// The most tokens the bucket may hold, which bounds a burst of hedges.
    public let burst: Double
    /// Tokens currently available.
    public private(set) var tokens: Double

    /// Creates a budget that starts full. Negative inputs are clamped to zero.
    public init(ratio: Double, burst: Double) {
        self.ratio = max(0, ratio)
        self.burst = max(0, burst)
        self.tokens = max(0, burst)
    }

    /// A budget that never refuses a hedge.
    public static let unlimited = HedgeBudget(ratio: .infinity, burst: .infinity)

    /// Credits the bucket for one incoming request.
    public mutating func deposit() {
        tokens = min(burst, tokens + ratio)
    }

    /// Spends one token if available. Returns `false`, leaving the bucket untouched, when not.
    public mutating func trySpend() -> Bool {
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

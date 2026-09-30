/// A bounded window of recent latencies, used to derive an adaptive hedge delay.
///
/// Only the newest `capacity` samples are kept, so the delay follows a provider whose
/// latency drifts over a session instead of averaging over its whole history.
public struct LatencyWindow: Sendable, Equatable {
    /// The maximum number of samples retained.
    public let capacity: Int
    /// Samples in arrival order, oldest first.
    public private(set) var samples: [Duration] = []

    /// Creates an empty window. `capacity` is clamped to at least 1.
    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    /// Appends a sample, dropping the oldest once the window is full.
    public mutating func record(_ latency: Duration) {
        samples.append(latency)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// The nearest-rank percentile of the retained samples, or `nil` when the window is empty.
    ///
    /// - Parameter fraction: A value in `0...1` (clamped); `0.95` is the 95th percentile.
    public func percentile(_ fraction: Double) -> Duration? {
        guard !samples.isEmpty else { return nil }
        let clamped = min(1, max(0, fraction))
        let sorted = samples.sorted()
        let rank = Int((clamped * Double(sorted.count)).rounded(.up))
        return sorted[max(0, rank - 1)]
    }
}

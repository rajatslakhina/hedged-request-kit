/// Sends a request to its primary attempt and, if that has not answered within the hedge delay,
/// to the next attempt as well. The first success wins and the rest are cancelled.
///
/// The executor is an actor so its latency window, budget and counters stay consistent across
/// concurrent requests. Each `execute` call runs its attempts in a task group; the actor only
/// makes launch decisions, so a slow attempt never blocks another request.
public actor HedgedExecutor {
    /// The policy in force.
    public let policy: HedgePolicy
    private let sleeper: any HedgeSleeper
    private var window: LatencyWindow
    private var budget: HedgeBudget
    private var stats = HedgeStats()

    /// Creates an executor.
    /// - Parameter sleeper: Waits out hedge delays. Tests inject one that decides timing.
    public init(policy: HedgePolicy = HedgePolicy(), sleeper: any HedgeSleeper = TaskSleeper()) {
        self.policy = policy
        self.sleeper = sleeper
        self.window = LatencyWindow(capacity: policy.windowCapacity)
        self.budget = policy.budget
    }

    /// Counters since creation.
    public func snapshot() -> HedgeStats { stats }

    /// The delay the next request would use.
    public func currentDelay() -> Duration { policy.delay.resolve(against: window) }

    /// Tokens currently in the hedge budget.
    public func budgetTokens() -> Double { budget.tokens }

    /// Feeds a latency observed elsewhere (e.g. an unhedged call) into the adaptive delay.
    public func observe(latency: Duration) { window.record(latency) }

    /// Runs `attempts` under the policy and returns the first success.
    ///
    /// Only the first `policy.maxAttempts` attempts are ever launched.
    /// - Throws: `HedgeError.noAttempts`, or `HedgeError.allFailed` when nothing succeeded.
    public func execute<Value: Sendable>(_ attempts: [HedgeAttempt<Value>]) async throws -> HedgeOutcome<Value> {
        guard !attempts.isEmpty else { throw HedgeError.noAttempts }
        stats.requests += 1
        budget.deposit()
        let usable = Array(attempts.prefix(policy.maxAttempts))
        let delay = policy.delay.resolve(against: window)
        let start = ContinuousClock.now
        var run = HedgeRun(count: usable.count)

        let result: Result<HedgeOutcome<Value>, HedgeError> = await withTaskGroup(
            of: HedgeEvent<Value>.self
        ) { group in
            launch(0, reason: .primary, attempts: usable, run: &run, group: &group)
            scheduleTimer(delay, run: &run, group: &group)

            for await event in group {
                switch event {
                case let .finished(index, .success(value)):
                    group.cancelAll()
                    return .success(finish(value: value, index: index, run: run, start: start, delay: delay))
                case let .finished(index, .failure(error)):
                    run.fail(index, label: usable[index].label, error: error)
                    if policy.failoverOnError, run.canLaunch {
                        stats.failovers += 1
                        launch(run.launched.count, reason: .failover, attempts: usable, run: &run, group: &group)
                        // The replacement gets its own full delay; the pending timer goes stale.
                        scheduleTimer(delay, run: &run, group: &group)
                    }
                case let .timerFired(generation):
                    handleTimer(generation, delay: delay, attempts: usable, run: &run, group: &group)
                }
                if run.isExhausted {
                    group.cancelAll()
                    break
                }
            }
            stats.exhausted += 1
            return .failure(HedgeError.allFailed(run.failures, budgetDenied: run.budgetDenied))
        }
        return try result.get()
    }

    private func handleTimer<Value: Sendable>(
        _ generation: Int,
        delay: Duration,
        attempts: [HedgeAttempt<Value>],
        run: inout HedgeRun,
        group: inout TaskGroup<HedgeEvent<Value>>
    ) {
        guard generation == run.timerGeneration, run.canLaunch else { return }
        guard budget.trySpend() else {
            run.budgetDenied = true
            stats.budgetDenials += 1
            return
        }
        stats.hedgesSent += 1
        launch(run.launched.count, reason: .hedge, attempts: attempts, run: &run, group: &group)
        scheduleTimer(delay, run: &run, group: &group)
    }

    private func launch<Value: Sendable>(
        _ index: Int,
        reason: LaunchReason,
        attempts: [HedgeAttempt<Value>],
        run: inout HedgeRun,
        group: inout TaskGroup<HedgeEvent<Value>>
    ) {
        let attempt = attempts[index]
        run.launched.append(LaunchedAttempt(label: attempt.label, reason: reason))
        run.running += 1
        group.addTask {
            do {
                return .finished(index, .success(try await attempt.operation()))
            } catch {
                return .finished(index, .failure(error))
            }
        }
    }

    private func scheduleTimer<Value: Sendable>(
        _ delay: Duration,
        run: inout HedgeRun,
        group: inout TaskGroup<HedgeEvent<Value>>
    ) {
        guard run.canLaunch else { return }
        run.timerGeneration += 1
        let generation = run.timerGeneration
        let sleeper = sleeper
        group.addTask {
            try? await sleeper.sleep(for: delay)
            return .timerFired(generation)
        }
    }

    private func finish<Value: Sendable>(
        value: Value,
        index: Int,
        run: HedgeRun,
        start: ContinuousClock.Instant,
        delay: Duration
    ) -> HedgeOutcome<Value> {
        let latency = ContinuousClock.now - start
        window.record(latency)
        let reason = run.launched[index].reason
        if reason == .hedge { stats.hedgeWins += 1 }
        return HedgeOutcome(
            value: value,
            winner: run.launched[index].label,
            winnerReason: reason,
            launched: run.launched,
            failures: run.failures,
            latency: latency,
            hedgeDelay: delay,
            budgetDenied: run.budgetDenied
        )
    }
}

/// What a child task of one hedged request reports.
enum HedgeEvent<Value: Sendable>: Sendable {
    case finished(Int, Result<Value, any Error>)
    case timerFired(Int)
}

/// Bookkeeping for one `execute` call, kept separate so each branch is testable.
struct HedgeRun: Equatable {
    let count: Int
    var launched: [LaunchedAttempt] = []
    var failures: [HedgeFailure] = []
    var running = 0
    var timerGeneration = 0
    var budgetDenied = false

    init(count: Int) {
        self.count = count
    }

    /// Another attempt exists that has not been launched.
    var canLaunch: Bool { launched.count < count }

    /// Nothing is running and nothing more can start: either every attempt was launched,
    /// or the budget refused the next hedge (after which no timer is rescheduled).
    var isExhausted: Bool { running == 0 && (!canLaunch || budgetDenied) }

    mutating func fail(_ index: Int, label: String, error: any Error) {
        running -= 1
        failures.append(HedgeFailure(label: label, reason: String(describing: error)))
    }
}

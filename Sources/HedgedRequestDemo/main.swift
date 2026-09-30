import HedgedRequestKit

// Simulated providers. Latencies are real sleeps, chosen with wide gaps (20ms / 300ms, hedge at
// 80ms) so the reported buckets are the same on every run even though exact timings jitter.

struct RateLimited: Error, CustomStringConvertible {
    var description: String { "429 rate limited" }
}

/// A provider whose latency for the n-th request comes from a script.
actor ScriptedProvider {
    let name: String
    private let script: [Duration]
    private var index = 0

    init(_ name: String, script: [Duration]) {
        self.name = name
        self.script = script
    }

    func nextLatency() -> Duration {
        defer { index += 1 }
        return script[index % script.count]
    }

    nonisolated func attempt(_ prompt: String) -> HedgeAttempt<String> {
        HedgeAttempt(name) {
            let latency = await self.nextLatency()
            try await Task.sleep(for: latency)
            return "\(self.name): answer to \(prompt)"
        }
    }
}

func bucket(_ latency: Duration) -> String {
    if latency < .milliseconds(60) { return "fast (<60ms)" }
    if latency < .milliseconds(200) { return "hedged (<200ms)" }
    return "slow (>=200ms)"
}

func line(_ text: String = "") { print(text) }

let fast = Duration.milliseconds(20)
let slow = Duration.milliseconds(300)
// 10 requests; requests 4 and 9 hit the primary's tail.
let tailScript: [Duration] = [fast, fast, fast, slow, fast, fast, fast, fast, slow, fast]

func runBatch(_ title: String, executor: HedgedExecutor, primary: ScriptedProvider,
              backup: ScriptedProvider, count: Int) async throws {
    line(title)
    var buckets: [String: Int] = [:]
    var worst = Duration.zero
    for request in 1...count {
        let outcome = try await executor.execute([
            primary.attempt("q\(request)"), backup.attempt("q\(request)")
        ])
        buckets[bucket(outcome.latency), default: 0] += 1
        worst = max(worst, outcome.latency)
        if outcome.winnerReason != .primary || outcome.budgetDenied {
            let note = outcome.budgetDenied ? "hedge due, BUDGET DENIED" : "won by \(outcome.winnerReason.rawValue)"
            line("   q\(request): \(outcome.winner) \(note) -> \(bucket(outcome.latency))")
        }
    }
    let stats = await executor.snapshot()
    let summary = buckets.keys.sorted().map { "\($0): \(buckets[$0] ?? 0)" }.joined(separator: ", ")
    line("   latency: \(summary)")
    line("   worst case: \(bucket(worst)); hedges sent \(stats.hedgesSent)/\(stats.requests) " +
         "(\(Int((stats.hedgeRate * 100).rounded()))% extra spend), hedge wins \(stats.hedgeWins), " +
         "budget denials \(stats.budgetDenials)")
    line()
}

line("HedgedRequestKit demo — tail latency vs. extra spend")
line("====================================================")
line()

// 1. No hedging: maxAttempts 1 means the backup is never sent.
try await runBatch(
    "1. Unhedged: 10 requests, primary has a 300ms tail on 2 of them",
    executor: HedgedExecutor(policy: HedgePolicy(delay: .fixed(.milliseconds(80)), maxAttempts: 1)),
    primary: ScriptedProvider("primary", script: tailScript),
    backup: ScriptedProvider("backup", script: [fast]),
    count: 10
)

// 2. Same traffic, hedged at 80ms with a generous budget.
try await runBatch(
    "2. Hedged at 80ms: same traffic, backup answers in 20ms",
    executor: HedgedExecutor(policy: HedgePolicy(delay: .fixed(.milliseconds(80)), budget: .unlimited)),
    primary: ScriptedProvider("primary", script: tailScript),
    backup: ScriptedProvider("backup", script: [fast]),
    count: 10
)

// 3. The primary slows down for everyone. Unbounded hedging would double every request's cost;
//    a 10% budget with a burst of 2 caps it.
try await runBatch(
    "3. Provider-wide slowdown: every primary call takes 300ms, budget = 10% + burst 2",
    executor: HedgedExecutor(policy: HedgePolicy(
        delay: .fixed(.milliseconds(80)), budget: HedgeBudget(ratio: 0.1, burst: 2)
    )),
    primary: ScriptedProvider("primary", script: [slow]),
    backup: ScriptedProvider("backup", script: [fast]),
    count: 8
)

// 4. Failover: an error ends the primary early, so the backup starts at once and spends no budget.
line("4. Primary returns 429: immediate failover, no budget spent")
let noBudget = HedgedExecutor(policy: HedgePolicy(
    delay: .fixed(.seconds(5)), budget: HedgeBudget(ratio: 0, burst: 0)
))
let failover = try await noBudget.execute([
    HedgeAttempt<String>("primary") { throw RateLimited() },
    ScriptedProvider("backup", script: [fast]).attempt("q1")
])
line("   winner: \(failover.winner) (\(failover.winnerReason.rawValue)) -> \(bucket(failover.latency)), " +
     "not after the 5s hedge delay")
line("   failures: \(failover.failures.map { "\($0.label): \($0.reason)" })")
line()

// 5. Everything fails.
line("5. Both providers fail")
do {
    _ = try await noBudget.execute([
        HedgeAttempt<String>("primary") { throw RateLimited() },
        HedgeAttempt<String>("backup") { throw RateLimited() }
    ])
} catch let error as HedgeError {
    if case let .allFailed(failures, denied) = error {
        line("   allFailed: \(failures.map(\.label)), budgetDenied: \(denied)")
    }
}
line()

// 6. Adaptive delay: the hedge point follows the observed p95 once enough samples exist.
line("6. Adaptive delay (p95, min 50ms, max 5s, 20 samples before trusting it)")
let adaptive = HedgedExecutor(policy: HedgePolicy(delay: .p95))
line("   before any traffic (fallback): \(await adaptive.currentDelay())")
for sample in 1...20 {
    await adaptive.observe(latency: .milliseconds(sample <= 19 ? 120 : 900))
}
line("   after 19 x 120ms + 1 x 900ms: \(await adaptive.currentDelay())")
for _ in 1...20 { await adaptive.observe(latency: .milliseconds(30)) }
line("   after 20 more x 30ms: \(await adaptive.currentDelay())")
for _ in 1...60 { await adaptive.observe(latency: .milliseconds(10)) }
line("   after 60 more x 10ms (window of 100): \(await adaptive.currentDelay())")
for _ in 1...100 { await adaptive.observe(latency: .milliseconds(10)) }
line("   after 100 x 10ms (slow samples evicted; clamped to the 50ms minimum): \(await adaptive.currentDelay())")

import XCTest
@testable import HedgedRequestKit

/// Fires every hedge timer at once.
private struct ImmediateSleeper: HedgeSleeper {
    func sleep(for duration: Duration) async throws {}
}

/// Never fires a hedge timer; returns only when cancelled.
private struct NeverSleeper: HedgeSleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

/// Fires a timer after a fixed real delay, ignoring the requested one.
private struct FixedSleeper: HedgeSleeper {
    let after: Duration
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: after)
    }
}

/// The first timer fires after `first`; every later timer never fires.
private actor FirstOnlySleeper: HedgeSleeper {
    let first: Duration
    private var calls = 0
    init(first: Duration) { self.first = first }

    func sleep(for duration: Duration) async throws {
        calls += 1
        try await Task.sleep(for: calls == 1 ? first : .seconds(3_600))
    }
}

private struct Boom: Error, CustomStringConvertible {
    let name: String
    var description: String { "boom(\(name))" }
}

private func fast(_ label: String, _ value: Int) -> HedgeAttempt<Int> {
    HedgeAttempt(label) { value }
}

private func slow(_ label: String, _ value: Int, after: Duration) -> HedgeAttempt<Int> {
    HedgeAttempt(label) {
        try await Task.sleep(for: after)
        return value
    }
}

private func failing(_ label: String, after: Duration = .zero) -> HedgeAttempt<Int> {
    HedgeAttempt(label) {
        if after > .zero { try await Task.sleep(for: after) }
        throw Boom(name: label)
    }
}

final class HedgedExecutorTests: XCTestCase {
    private func policy(
        maxAttempts: Int = 2,
        budget: HedgeBudget = .unlimited,
        failoverOnError: Bool = true
    ) -> HedgePolicy {
        HedgePolicy(delay: .fixed(.milliseconds(10)), maxAttempts: maxAttempts, budget: budget,
                    failoverOnError: failoverOnError)
    }

    func testNoAttemptsThrows() async {
        let executor = HedgedExecutor(policy: policy(), sleeper: NeverSleeper())
        do {
            _ = try await executor.execute([HedgeAttempt<Int>]())
            XCTFail("expected noAttempts")
        } catch {
            XCTAssertEqual(error as? HedgeError, .noAttempts)
        }
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.requests, 0)
    }

    func testFastPrimaryWinsWithoutHedging() async throws {
        let executor = HedgedExecutor(policy: policy(), sleeper: NeverSleeper())
        let outcome = try await executor.execute([fast("primary", 1), fast("backup", 2)])
        XCTAssertEqual(outcome.value, 1)
        XCTAssertEqual(outcome.winner, "primary")
        XCTAssertEqual(outcome.winnerReason, .primary)
        XCTAssertEqual(outcome.launched, [LaunchedAttempt(label: "primary", reason: .primary)])
        XCTAssertEqual(outcome.hedgesSent, 0)
        XCTAssertEqual(outcome.hedgeDelay, .milliseconds(10))
        XCTAssertFalse(outcome.budgetDenied)
        let stats = await executor.snapshot()
        var expected = HedgeStats()
        expected.requests = 1
        XCTAssertEqual(stats, expected)
    }

    func testSlowPrimaryIsBeatenByHedgeAndCancelled() async throws {
        let executor = HedgedExecutor(policy: policy(), sleeper: ImmediateSleeper())
        let outcome = try await executor.execute([
            slow("primary", 1, after: .seconds(30)), fast("hedge", 2)
        ])
        XCTAssertEqual(outcome.value, 2)
        XCTAssertEqual(outcome.winnerReason, .hedge)
        XCTAssertEqual(outcome.launched.map(\.reason), [.primary, .hedge])
        XCTAssertLessThan(outcome.latency, .seconds(5), "the 30s primary must have been cancelled")
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.hedgesSent, 1)
        XCTAssertEqual(stats.hedgeWins, 1)
        XCTAssertEqual(stats.hedgeRate, 1)
    }

    func testFailedPrimaryFailsOverImmediatelyWithoutSpendingBudget() async throws {
        let executor = HedgedExecutor(policy: policy(budget: HedgeBudget(ratio: 0, burst: 0)),
                                      sleeper: NeverSleeper())
        let outcome = try await executor.execute([failing("primary"), fast("backup", 7)])
        XCTAssertEqual(outcome.value, 7)
        XCTAssertEqual(outcome.winnerReason, .failover)
        XCTAssertEqual(outcome.failures, [HedgeFailure(label: "primary", reason: "boom(primary)")])
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.failovers, 1)
        XCTAssertEqual(stats.hedgesSent, 0)
        XCTAssertEqual(stats.budgetDenials, 0)
    }

    func testWithoutFailoverAFailedPrimaryWaitsForTheHedgeTimer() async throws {
        let executor = HedgedExecutor(policy: policy(failoverOnError: false),
                                      sleeper: FixedSleeper(after: .milliseconds(30)))
        let outcome = try await executor.execute([failing("primary"), fast("hedge", 3)])
        XCTAssertEqual(outcome.value, 3)
        XCTAssertEqual(outcome.winnerReason, .hedge)
        XCTAssertEqual(outcome.failures.map(\.label), ["primary"])
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.failovers, 0)
    }

    func testBudgetDenialLetsThePrimaryFinish() async throws {
        let executor = HedgedExecutor(policy: policy(budget: HedgeBudget(ratio: 0, burst: 0)),
                                      sleeper: ImmediateSleeper())
        let outcome = try await executor.execute([
            slow("primary", 5, after: .milliseconds(50)), fast("hedge", 6)
        ])
        XCTAssertEqual(outcome.value, 5)
        XCTAssertTrue(outcome.budgetDenied)
        XCTAssertEqual(outcome.launched.count, 1)
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.budgetDenials, 1)
        XCTAssertEqual(stats.hedgesSent, 0)
    }

    func testBudgetDenialThenPrimaryFailureExhausts() async {
        let executor = HedgedExecutor(
            policy: policy(budget: HedgeBudget(ratio: 0, burst: 0), failoverOnError: false),
            sleeper: ImmediateSleeper()
        )
        do {
            _ = try await executor.execute([failing("primary", after: .milliseconds(50)), fast("hedge", 1)])
            XCTFail("expected allFailed")
        } catch {
            XCTAssertEqual(error as? HedgeError, .allFailed(
                [HedgeFailure(label: "primary", reason: "boom(primary)")], budgetDenied: true
            ))
        }
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.exhausted, 1)
    }

    func testEveryAttemptFailing() async {
        let executor = HedgedExecutor(policy: policy(), sleeper: NeverSleeper())
        do {
            _ = try await executor.execute([failing("a"), failing("b")])
            XCTFail("expected allFailed")
        } catch {
            XCTAssertEqual(error as? HedgeError, .allFailed(
                [HedgeFailure(label: "a", reason: "boom(a)"), HedgeFailure(label: "b", reason: "boom(b)")],
                budgetDenied: false
            ))
        }
    }

    func testMaxAttemptsCapsWhatIsLaunched() async {
        let executor = HedgedExecutor(policy: policy(maxAttempts: 1), sleeper: ImmediateSleeper())
        do {
            _ = try await executor.execute([failing("only"), fast("never", 1)])
            XCTFail("expected allFailed")
        } catch {
            XCTAssertEqual(error as? HedgeError, .allFailed(
                [HedgeFailure(label: "only", reason: "boom(only)")], budgetDenied: false
            ))
        }
    }

    func testFailoverRestartsTheHedgeClockSoTheOldTimerIsIgnored() async throws {
        // Primary fails at once; the failover replaces it and reschedules the timer. The first
        // (now stale) timer fires at 20ms and must not launch the third attempt.
        let executor = HedgedExecutor(policy: policy(maxAttempts: 3),
                                      sleeper: FirstOnlySleeper(first: .milliseconds(20)))
        let outcome = try await executor.execute([
            failing("primary"), slow("failover", 9, after: .milliseconds(150)), fast("third", 0)
        ])
        XCTAssertEqual(outcome.value, 9)
        XCTAssertEqual(outcome.launched.map(\.reason), [.primary, .failover])
    }

    func testTimerFiringAfterEverythingLaunchedIsIgnored() async throws {
        let executor = HedgedExecutor(policy: policy(), sleeper: FixedSleeper(after: .milliseconds(20)))
        let outcome = try await executor.execute([
            failing("primary"), slow("failover", 4, after: .milliseconds(150))
        ])
        XCTAssertEqual(outcome.value, 4)
        XCTAssertEqual(outcome.launched.map(\.reason), [.primary, .failover])
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.hedgesSent, 0)
    }

    func testAdaptiveDelayLearnsFromWinsAndObservations() async throws {
        let adaptive = HedgePolicy(
            delay: .percentile(0.5, fallback: .seconds(2), minimum: .milliseconds(1),
                               maximum: .seconds(10), minimumSamples: 2),
            budget: .unlimited
        )
        let executor = HedgedExecutor(policy: adaptive, sleeper: NeverSleeper())
        let initial = await executor.currentDelay()
        XCTAssertEqual(initial, .seconds(2))
        _ = try await executor.execute([fast("a", 1)])
        await executor.observe(latency: .milliseconds(400))
        let learned = await executor.currentDelay()
        XCTAssertLessThanOrEqual(learned, .milliseconds(400))
        XCTAssertNotEqual(learned, .seconds(2))
    }

    func testBudgetDepositsPerRequestAndConcurrentRequestsShareState() async throws {
        // One token covers one of the two due hedges. Whichever request loses the race keeps
        // its primary, so both primaries are short.
        let executor = HedgedExecutor(policy: policy(budget: HedgeBudget(ratio: 0.5, burst: 1)),
                                      sleeper: ImmediateSleeper())
        let full = await executor.budgetTokens()
        XCTAssertEqual(full, 1)
        async let first = executor.execute([slow("p1", 1, after: .milliseconds(80)), fast("h1", 11)])
        async let second = executor.execute([slow("p2", 2, after: .milliseconds(80)), fast("h2", 22)])
        let results = try await [first.value, second.value]
        XCTAssertEqual(results.count, 2)
        let stats = await executor.snapshot()
        XCTAssertEqual(stats.requests, 2)
        XCTAssertEqual(stats.hedgesSent, 1)
        XCTAssertEqual(stats.budgetDenials, 1)
    }
}

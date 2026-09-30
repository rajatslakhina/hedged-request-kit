import XCTest
@testable import HedgedRequestKit

final class LatencyWindowTests: XCTestCase {
    func testEmptyWindowHasNoPercentile() {
        XCTAssertNil(LatencyWindow().percentile(0.5))
    }

    func testCapacityIsClampedAndOldestSamplesAreDropped() {
        var window = LatencyWindow(capacity: 0)
        XCTAssertEqual(window.capacity, 1)
        window.record(.milliseconds(10))
        window.record(.milliseconds(20))
        XCTAssertEqual(window.samples, [.milliseconds(20)])

        var three = LatencyWindow(capacity: 3)
        for value in [1, 2, 3, 4, 5] { three.record(.milliseconds(value)) }
        XCTAssertEqual(three.samples, [.milliseconds(3), .milliseconds(4), .milliseconds(5)])
    }

    func testNearestRankPercentile() {
        var window = LatencyWindow()
        for value in [50, 10, 40, 20, 30, 100, 60, 90, 70, 80] { window.record(.milliseconds(value)) }
        XCTAssertEqual(window.percentile(0.5), .milliseconds(50))
        XCTAssertEqual(window.percentile(0.95), .milliseconds(100))
        XCTAssertEqual(window.percentile(0.9), .milliseconds(90))
        XCTAssertEqual(window.percentile(0), .milliseconds(10))
        XCTAssertEqual(window.percentile(1), .milliseconds(100))
        XCTAssertEqual(window.percentile(-3), .milliseconds(10))
        XCTAssertEqual(window.percentile(7), .milliseconds(100))
    }
}

final class HedgeBudgetTests: XCTestCase {
    func testStartsFullAndClampsNegatives() {
        let budget = HedgeBudget(ratio: -1, burst: -2)
        XCTAssertEqual(budget.ratio, 0)
        XCTAssertEqual(budget.burst, 0)
        XCTAssertEqual(budget.tokens, 0)
        XCTAssertEqual(HedgeBudget(ratio: 0.1, burst: 3).tokens, 3)
    }

    func testSpendRefusesBelowOneTokenAndDepositCapsAtBurst() {
        var budget = HedgeBudget(ratio: 0.5, burst: 1)
        XCTAssertTrue(budget.trySpend())
        XCTAssertFalse(budget.trySpend())
        XCTAssertEqual(budget.tokens, 0)
        budget.deposit()
        XCTAssertFalse(budget.trySpend())
        XCTAssertEqual(budget.tokens, 0.5)
        budget.deposit()
        budget.deposit()
        XCTAssertEqual(budget.tokens, 1)
        XCTAssertTrue(budget.trySpend())
    }

    func testUnlimitedNeverRefuses() {
        var budget = HedgeBudget.unlimited
        for _ in 0..<1_000 { XCTAssertTrue(budget.trySpend()) }
        budget.deposit()
        XCTAssertTrue(budget.trySpend())
    }
}

final class HedgeDelayTests: XCTestCase {
    private let adaptive = HedgeDelay.percentile(
        0.5, fallback: .seconds(1), minimum: .milliseconds(20), maximum: .milliseconds(200), minimumSamples: 3
    )

    func testFixedIgnoresTheWindow() {
        var window = LatencyWindow()
        window.record(.seconds(9))
        XCTAssertEqual(HedgeDelay.fixed(.milliseconds(75)).resolve(against: window), .milliseconds(75))
    }

    func testPercentileFallsBackUntilEnoughSamples() {
        var window = LatencyWindow()
        window.record(.milliseconds(80))
        window.record(.milliseconds(80))
        XCTAssertEqual(adaptive.resolve(against: window), .seconds(1))
        window.record(.milliseconds(80))
        XCTAssertEqual(adaptive.resolve(against: window), .milliseconds(80))
    }

    func testPercentileIsClampedToItsRange() {
        var fast = LatencyWindow()
        for _ in 0..<3 { fast.record(.milliseconds(1)) }
        XCTAssertEqual(adaptive.resolve(against: fast), .milliseconds(20))
        var slow = LatencyWindow()
        for _ in 0..<3 { slow.record(.seconds(3)) }
        XCTAssertEqual(adaptive.resolve(against: slow), .milliseconds(200))
    }

    func testP95DefaultFallsBackToOneSecond() {
        XCTAssertEqual(HedgeDelay.p95.resolve(against: LatencyWindow()), .seconds(1))
    }
}

final class ModelTests: XCTestCase {
    func testPolicyDefaultsAndClamp() {
        let policy = HedgePolicy(maxAttempts: 0)
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.delay, .p95)
        XCTAssertEqual(policy.budget, HedgeBudget(ratio: 0.1, burst: 10))
        XCTAssertTrue(policy.failoverOnError)
        XCTAssertEqual(policy.windowCapacity, 100)
    }

    func testStatsHedgeRate() {
        var stats = HedgeStats()
        XCTAssertEqual(stats.hedgeRate, 0)
        stats.requests = 4
        stats.hedgesSent = 1
        XCTAssertEqual(stats.hedgeRate, 0.25)
    }

    func testRecordsAndOutcomeCountHedgesOnly() {
        XCTAssertEqual(HedgeFailure(label: "a", reason: "x").label, "a")
        XCTAssertEqual(LaunchReason.failover.rawValue, "failover")
        let outcome = HedgeOutcome(
            value: 1, winner: "c", winnerReason: .hedge,
            launched: [
                LaunchedAttempt(label: "a", reason: .primary),
                LaunchedAttempt(label: "b", reason: .failover),
                LaunchedAttempt(label: "c", reason: .hedge)
            ],
            failures: [], latency: .zero, hedgeDelay: .zero, budgetDenied: false
        )
        XCTAssertEqual(outcome.hedgesSent, 1)
    }

    func testRunBookkeeping() {
        var run = HedgeRun(count: 2)
        XCTAssertTrue(run.canLaunch)
        XCTAssertFalse(run.isExhausted, "nothing launched yet but a timer may still launch")
        run.launched.append(LaunchedAttempt(label: "a", reason: .primary))
        run.running = 1
        run.fail(0, label: "a", error: CancellationError())
        XCTAssertEqual(run.running, 0)
        XCTAssertEqual(run.failures, [HedgeFailure(label: "a", reason: "CancellationError()")])
        XCTAssertFalse(run.isExhausted)
        run.budgetDenied = true
        XCTAssertTrue(run.isExhausted)
    }

    func testTaskSleeperSleepsAndHonoursCancellation() async throws {
        try await TaskSleeper().sleep(for: .milliseconds(1))
        let task = Task { try await TaskSleeper().sleep(for: .seconds(30)) }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

import BattCycleCore
import XCTest

final class SamplingPolicyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    func testHeartbeatIsAlwaysTwoSeconds() {
        let policy = SamplingPolicy(historyInterval: 10, enginePollSeconds: 10)
        XCTAssertEqual(SamplingPolicy.heartbeatSeconds, 2)
        XCTAssertEqual(policy.heartbeatInterval, 2)
        XCTAssertEqual(policy.heartbeatInterval, SamplingPolicy.heartbeatSeconds)
    }

    func testSettingHistoryIntervalTo300DoesNotChangeHeartbeatOrEnginePoll() {
        var policy = SamplingPolicy(historyInterval: 10, enginePollSeconds: 10)
        XCTAssertEqual(policy.heartbeatInterval, 2)
        XCTAssertEqual(policy.enginePollSeconds, 10)

        policy.historyInterval = 300

        XCTAssertEqual(policy.historyInterval, 300)
        XCTAssertEqual(policy.heartbeatInterval, SamplingPolicy.heartbeatSeconds)
        XCTAssertEqual(policy.heartbeatInterval, 2)
        XCTAssertEqual(policy.enginePollSeconds, 10)
    }

    func testRecommendedAndCustomHistoryIntervalsValidate() throws {
        XCTAssertEqual(SamplingPolicy.recommendedHistoryIntervals, [2, 5, 10, 30, 60, 300])

        for interval in SamplingPolicy.recommendedHistoryIntervals {
            let policy = SamplingPolicy(historyInterval: interval, enginePollSeconds: 10)
            XCTAssertNoThrow(try policy.validated())
        }

        XCTAssertNoThrow(try SamplingPolicy(historyInterval: 2, enginePollSeconds: 10).validated())
        XCTAssertNoThrow(try SamplingPolicy(historyInterval: 7, enginePollSeconds: 10).validated())
        XCTAssertNoThrow(try SamplingPolicy(historyInterval: 3_600, enginePollSeconds: 10).validated())
    }

    func testRejectsHistoryIntervalOutsideAllowedRange() {
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: 1, enginePollSeconds: 10).validated())
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: 3_601, enginePollSeconds: 10).validated())
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: 0, enginePollSeconds: 10).validated())
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: -5, enginePollSeconds: 10).validated())
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: .nan, enginePollSeconds: 10).validated())
        XCTAssertThrowsError(try SamplingPolicy(historyInterval: .infinity, enginePollSeconds: 10).validated())
    }

    func testValidatedDoesNotRewriteEnginePollFromHistory() throws {
        let policy = try SamplingPolicy(historyInterval: 300, enginePollSeconds: 5).validated()
        XCTAssertEqual(policy.historyInterval, 300)
        XCTAssertEqual(policy.enginePollSeconds, 5)
        XCTAssertEqual(policy.heartbeatInterval, 2)
        XCTAssertNotEqual(Int(policy.historyInterval), policy.enginePollSeconds)
    }

    func testShouldRecordHistoryHonorsIntervalPauseAndSleep() {
        let policy = SamplingPolicy(historyInterval: 10, enginePollSeconds: 10)

        XCTAssertTrue(policy.shouldRecordHistory(now: t0, lastHistoryAt: nil, paused: false, sleeping: false))
        XCTAssertFalse(policy.shouldRecordHistory(now: t0, lastHistoryAt: nil, paused: true, sleeping: false))
        XCTAssertFalse(policy.shouldRecordHistory(now: t0, lastHistoryAt: nil, paused: false, sleeping: true))

        XCTAssertFalse(
            policy.shouldRecordHistory(
                now: t0.addingTimeInterval(9.9),
                lastHistoryAt: t0,
                paused: false,
                sleeping: false
            )
        )
        XCTAssertTrue(
            policy.shouldRecordHistory(
                now: t0.addingTimeInterval(10),
                lastHistoryAt: t0,
                paused: false,
                sleeping: false
            )
        )
    }

    func testHeartbeatStaysOnTwoSecondsWhenHistoryIntervalIs300() {
        let policy = SamplingPolicy(historyInterval: 300, enginePollSeconds: 10)

        XCTAssertTrue(policy.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil, processExiting: false))
        XCTAssertFalse(
            policy.shouldWriteHeartbeat(
                now: t0.addingTimeInterval(1.9),
                lastHeartbeatAt: t0,
                processExiting: false
            )
        )
        XCTAssertTrue(
            policy.shouldWriteHeartbeat(
                now: t0.addingTimeInterval(2),
                lastHeartbeatAt: t0,
                processExiting: false
            )
        )
        XCTAssertFalse(
            policy.shouldRecordHistory(
                now: t0.addingTimeInterval(2),
                lastHistoryAt: t0,
                paused: false,
                sleeping: false
            )
        )
        XCTAssertFalse(
            policy.shouldWriteHeartbeat(
                now: t0.addingTimeInterval(2),
                lastHeartbeatAt: t0,
                processExiting: true
            )
        )
    }

    func testIntervalChangeOnStructAppliesWithoutRestart() {
        var policy = SamplingPolicy(historyInterval: 10, enginePollSeconds: 10)
        XCTAssertEqual(policy.nextSampleAt(from: t0), t0.addingTimeInterval(10))

        policy.historyInterval = 60

        XCTAssertEqual(policy.nextSampleAt(from: t0), t0.addingTimeInterval(60))
        XCTAssertEqual(policy.enginePollSeconds, 10)
        XCTAssertEqual(policy.heartbeatInterval, 2)
    }

    func testThreeClockBoundsStayIndependent() throws {
        XCTAssertEqual(SamplingPolicy.heartbeatSeconds, 2)
        XCTAssertEqual(SamplingPolicy.allowedHistoryRange, 2...3_600)
        XCTAssertEqual(
            SamplingPolicy.recommendedHistoryIntervals.map { Int($0) },
            MonitorSettings.presetIntervals
        )
        XCTAssertEqual(Int(SamplingPolicy.allowedHistoryRange.lowerBound), MonitorSettings.intervalRange.lowerBound)
        XCTAssertEqual(Int(SamplingPolicy.allowedHistoryRange.upperBound), MonitorSettings.intervalRange.upperBound)

        let monitor = MonitorSettings(historyIntervalSeconds: 300, recordingPaused: false, retentionDays: 30)
        var policy = try SamplingPolicy(monitor: monitor, enginePollSeconds: 5).validated()

        XCTAssertEqual(policy.historyInterval, 300)
        XCTAssertEqual(policy.enginePollSeconds, 5)
        XCTAssertEqual(policy.heartbeatInterval, 2)

        policy.historyInterval = 2
        XCTAssertEqual(policy.heartbeatInterval, 2, "历史间隔碰巧为 2 也不得改写心跳常量")
        XCTAssertEqual(policy.enginePollSeconds, 5)
        XCTAssertEqual(SamplingPolicy.heartbeatSeconds, 2)
    }

    func testPauseFlagOnPolicySkipsHistoryButNotHeartbeat() {
        let policy = SamplingPolicy(historyInterval: 10, enginePollSeconds: 10)
        XCTAssertFalse(policy.shouldRecordHistory(now: t0, lastHistoryAt: nil, paused: true, sleeping: false))
        XCTAssertTrue(policy.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil, processExiting: false))
        XCTAssertEqual(policy.enginePollSeconds, 10)
        XCTAssertEqual(policy.heartbeatInterval, 2)
    }
}

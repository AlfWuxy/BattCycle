import BattCycleCore
import XCTest

final class RecordingControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    func testStartIsIdempotent() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        XCTAssertEqual(controller.state, .idle)

        controller.start()
        XCTAssertEqual(controller.state, .recording)

        controller.start()
        controller.start()
        XCTAssertEqual(controller.state, .recording)

        controller.pause()
        XCTAssertEqual(controller.state, .paused)
        controller.start()
        XCTAssertEqual(controller.state, .paused, "重复 start 不得把暂停当成重新开始")
    }

    func testPauseDoesNotChangeEnginePollSecondsOrStopHeartbeat() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()

        let pollBefore = controller.policy.enginePollSeconds
        let heartbeatBefore = controller.policy.heartbeatInterval

        controller.pause()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertNotEqual(controller.state, .stopped)
        XCTAssertEqual(controller.policy.enginePollSeconds, pollBefore)
        XCTAssertEqual(controller.policy.enginePollSeconds, 10)
        XCTAssertEqual(controller.policy.heartbeatInterval, heartbeatBefore)
        XCTAssertEqual(controller.policy.heartbeatInterval, 2)

        XCTAssertFalse(controller.shouldRecordHistory(now: t0, lastHistoryAt: nil))
        XCTAssertTrue(controller.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil))
        XCTAssertTrue(
            controller.shouldWriteHeartbeat(now: t0.addingTimeInterval(2), lastHeartbeatAt: t0)
        )
    }

    func testSleepThenWakeDoesNotInventPoints() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()

        var last: Date?
        var samples: [Date] = []

        func consider(_ now: Date) {
            if controller.shouldRecordHistory(now: now, lastHistoryAt: last) {
                samples.append(now)
                last = now
                _ = controller.consumeGapIfNeeded()
            }
        }

        consider(t0)
        consider(t0.addingTimeInterval(10))
        XCTAssertEqual(samples, [t0, t0.addingTimeInterval(10)])

        controller.systemWillSleep()
        XCTAssertEqual(controller.state, .sleeping)
        XCTAssertTrue(controller.needsGap)
        XCTAssertFalse(controller.shouldRecordHistory(now: t0.addingTimeInterval(20), lastHistoryAt: last))

        for offset in stride(from: 20, through: 3_600, by: 10) {
            consider(t0.addingTimeInterval(TimeInterval(offset)))
        }
        XCTAssertEqual(samples.count, 2, "休眠期间不得伪造历史点")

        controller.systemDidWake()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.needsGap, "唤醒后仍应标记真实缺口，而不是补点")

        let wake = t0.addingTimeInterval(3_600)
        consider(wake)

        XCTAssertEqual(samples, [t0, t0.addingTimeInterval(10), wake])
        XCTAssertEqual(samples[2].timeIntervalSince(samples[1]), 3_590, accuracy: 0.001)
        XCTAssertFalse(controller.needsGap)
        XCTAssertFalse(controller.shouldRecordHistory(now: wake.addingTimeInterval(9), lastHistoryAt: last))
    }

    func testOnSleepOnWakeProtocolDoesNotBackfill() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 30, enginePollSeconds: 10))
        let handler: SleepWakeHandling = controller
        controller.start()

        XCTAssertTrue(controller.shouldRecordHistory(now: t0, lastHistoryAt: nil))

        handler.onSleep()
        XCTAssertTrue(controller.needsGap)
        XCTAssertFalse(controller.shouldRecordHistory(now: t0.addingTimeInterval(120), lastHistoryAt: t0))

        handler.onWake()
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(controller.needsGap)
        XCTAssertTrue(controller.shouldRecordHistory(now: t0.addingTimeInterval(3_600), lastHistoryAt: t0))
        XCTAssertTrue(controller.consumeGapIfNeeded())
        XCTAssertFalse(controller.consumeGapIfNeeded())
    }

    func testIntervalChangeAppliesWithoutRestartingApp() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()
        XCTAssertEqual(controller.nextSampleAt(from: t0), t0.addingTimeInterval(10))
        XCTAssertEqual(controller.state, .recording)

        controller.policy.historyInterval = 300

        XCTAssertEqual(controller.state, .recording, "改间隔只需改 policy，不必重启")
        XCTAssertEqual(controller.nextSampleAt(from: t0), t0.addingTimeInterval(300))
        XCTAssertEqual(controller.policy.enginePollSeconds, 10)
        XCTAssertEqual(controller.policy.heartbeatInterval, 2)

        XCTAssertFalse(
            controller.shouldRecordHistory(now: t0.addingTimeInterval(10), lastHistoryAt: t0)
        )
        XCTAssertTrue(
            controller.shouldRecordHistory(now: t0.addingTimeInterval(300), lastHistoryAt: t0)
        )
        XCTAssertTrue(
            controller.shouldWriteHeartbeat(now: t0.addingTimeInterval(2), lastHeartbeatAt: t0)
        )
    }

    func testTerminateStopsHistoryAndHeartbeat() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()
        controller.appWillTerminate()

        XCTAssertEqual(controller.state, .stopped)
        XCTAssertFalse(controller.shouldRecordHistory(now: t0, lastHistoryAt: nil))
        XCTAssertFalse(controller.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil))

        controller.start()
        XCTAssertEqual(controller.state, .stopped, "退出后重复 start 不得复活采集")
    }

    func testWakeRestoresPausedState() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()
        controller.pause()
        controller.onSleep()
        controller.onWake()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertTrue(controller.needsGap)
        XCTAssertFalse(controller.shouldRecordHistory(now: t0, lastHistoryAt: nil))
        XCTAssertTrue(controller.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil))
        XCTAssertEqual(controller.policy.enginePollSeconds, 10)
    }

    func testPauseSkipsAppendWithoutCrashing() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 5))
        controller.start()

        var appended: [Date] = []
        var last: Date?

        func considerAppend(_ now: Date) {
            // 暂停必须直接跳过追加：不抛错、不写点、不改引擎轮询。
            if controller.shouldRecordHistory(now: now, lastHistoryAt: last) {
                appended.append(now)
                last = now
            }
        }

        considerAppend(t0)
        XCTAssertEqual(appended, [t0])

        controller.pause()
        XCTAssertEqual(controller.state, .paused)

        for offset in stride(from: 2, through: 600, by: 2) {
            let now = t0.addingTimeInterval(TimeInterval(offset))
            considerAppend(now)
            XCTAssertTrue(
                controller.shouldWriteHeartbeat(now: now, lastHeartbeatAt: t0),
                "暂停不得停心跳"
            )
        }

        XCTAssertEqual(appended, [t0], "暂停期间不得追加历史点")
        XCTAssertEqual(controller.policy.enginePollSeconds, 5)
        XCTAssertEqual(controller.policy.heartbeatInterval, 2)
        XCTAssertEqual(controller.policy.historyInterval, 10)

        controller.resume()
        XCTAssertEqual(controller.state, .recording)
        considerAppend(t0.addingTimeInterval(10))
        XCTAssertEqual(appended, [t0, t0.addingTimeInterval(10)])
    }

    func testPauseDuringSleepStillSkipsAppendAfterWake() {
        let controller = RecordingController(policy: SamplingPolicy(historyInterval: 10, enginePollSeconds: 10))
        controller.start()
        controller.onSleep()
        controller.pause()
        controller.onWake()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(controller.shouldRecordHistory(now: t0.addingTimeInterval(3_600), lastHistoryAt: t0))
        XCTAssertTrue(controller.shouldWriteHeartbeat(now: t0, lastHeartbeatAt: nil))
        XCTAssertEqual(controller.policy.enginePollSeconds, 10)
    }
}

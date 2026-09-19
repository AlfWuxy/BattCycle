import BattCycleCore
import XCTest

/// DataTrust：只走注入快照，不调用 IOKit / `BatterySnapshot.capture()`。
final class DataTrustTests: XCTestCase {
    private let heartbeat = SamplingPolicy.heartbeatSeconds

    /// 缺 `Is Charging`：完整度不够，不得标成 trusted；缺键也不算冲突。
    func testMissingIsChargingIsUnavailableNotTrusted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var description = Self.basePowerSourceDescription(state: "AC Power", charging: true)
        description.removeValue(forKey: "Is Charging")
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: now,
            watts: 12.0
        )

        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertFalse(DataTrustEvaluator.isConflicting(snapshot))
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .unavailable
        )
        XCTAssertNotEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .trusted
        )
    }

    /// 缺 `Power Source State`：不得当成电池供电，也不得 trusted。
    func testMissingPowerSourceStateIsUnavailableNotTrusted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var description = Self.basePowerSourceDescription(state: "AC Power", charging: false)
        description.removeValue(forKey: "Power Source State")
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: now,
            watts: -8.5
        )

        XCTAssertEqual(snapshot.drawingFrom, "unknown")
        XCTAssertFalse(snapshot.externalConnectedIsAvailable)
        XCTAssertFalse(snapshot.drawingFromIsAvailable)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .unavailable
        )
        XCTAssertNotEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .trusted
        )
    }

    /// 捕获失败占位：empty 不是新鲜可信读数。
    func testEmptySnapshotIsUnavailable() {
        XCTAssertFalse(BatterySnapshot.empty.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: .empty,
                now: Date(),
                interval: heartbeat
            ),
            .unavailable
        )
    }

    /// 键齐全且采样时刻未超过心跳间隔：trusted。
    func testCompleteFreshSnapshotIsTrusted() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            Self.basePowerSourceDescription(state: "AC Power", charging: true),
            capturedAt: now,
            watts: 18.0
        )

        XCTAssertTrue(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .trusted
        )
        // 年龄恰好等于间隔仍不算过期（判定是严格大于）。
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: snapshot,
                now: now.addingTimeInterval(heartbeat),
                interval: heartbeat
            ),
            .trusted
        )
    }

    /// 构造完整快照、用心跳间隔判定过期：`now - capturedAt > interval` → stale。
    func testStaleWhenOlderThanHeartbeatInterval() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BatterySnapshot(
            percent: 80,
            drawingFrom: "电源适配器",
            isCharging: false,
            externalConnected: true,
            watts: 0,
            summary: "新鲜构造",
            capturedAt: capturedAt,
            isAvailable: true,
            wattsIsAvailable: true
        )
        let now = capturedAt.addingTimeInterval(heartbeat + 0.001)

        XCTAssertTrue(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .stale
        )
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                isAvailable: true,
                capturedAt: capturedAt,
                now: now,
                interval: heartbeat
            ),
            .stale
        )
    }

    /// 充电为真但电池侧功率明显为负：冲突优先于新鲜/过期。
    func testConflictingChargingFlagAndNegativeWatts() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BatterySnapshot(
            percent: 70,
            drawingFrom: "电池供电",
            isCharging: true,
            externalConnected: false,
            watts: -12.5,
            summary: "标志冲突",
            capturedAt: now,
            isAvailable: true,
            wattsIsAvailable: true
        )

        XCTAssertTrue(DataTrustEvaluator.isConflicting(snapshot))
        XCTAssertTrue(DataTrustEvaluator.isConflicting(
            isCharging: true,
            wattsIsAvailable: true,
            watts: -12.5
        ))
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: heartbeat),
            .conflicting
        )
        // 冲突时即使已过心跳间隔也不改判 stale。
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: snapshot,
                now: now.addingTimeInterval(heartbeat + 1),
                interval: heartbeat
            ),
            .conflicting
        )
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                isAvailable: true,
                capturedAt: now,
                now: now,
                interval: heartbeat,
                conflicting: true
            ),
            .conflicting
        )
    }

    /// 缺充电键时即使瓦数为负也不走冲突分支。
    func testMissingIsChargingIsNotConflicting() {
        var description = Self.basePowerSourceDescription(state: "Battery Power", charging: true)
        description.removeValue(forKey: "Is Charging")
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            watts: -20.0
        )

        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertFalse(DataTrustEvaluator.isConflicting(snapshot))
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: snapshot,
                now: snapshot.capturedAt,
                interval: heartbeat
            ),
            .unavailable
        )
    }

    /// 原始参数：捕获失败直接 unavailable，不看年龄。
    func testPrimitiveUnavailableIgnoresAge() {
        let capturedAt = Date.distantPast
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                isAvailable: false,
                capturedAt: capturedAt,
                now: Date(),
                interval: heartbeat,
                conflicting: true
            ),
            .unavailable
        )
    }

    /// 注入用的 IOPS 描述字典；测试只走 `fromPowerSourceDescription`，不读本机电源。
    private static func basePowerSourceDescription(
        state: String,
        charging: Bool
    ) -> [String: Any] {
        [
            "Current Capacity": 80,
            "Max Capacity": 100,
            "Power Source State": state,
            "Is Charging": charging
        ]
    }
}

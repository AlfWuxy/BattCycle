import BattCycleCore
import Foundation
import XCTest

/// 测试共用夹具：构造「IOPS 键齐全」与「缺键」的电源描述、电池快照、历史样本。
///
/// 只走 `BatterySnapshot.fromPowerSourceDescription` 与 `HistorySample.makeLive`。
/// 禁止调用 `BatterySnapshot.capture()`、`IOKitBatteryProvider`、batt CLI 或本机电源。
///
/// IOPS 字符串键与 IOKit.ps 常量同名，此处用字面量注入，避免测试目标链接真实电源查询。
enum TestFixtures {
    /// 与 `kIOPSCurrentCapacityKey` 等 IOKit.ps 常量对应的描述字典键。
    enum IOPSKey {
        static let currentCapacity = "Current Capacity"
        static let maxCapacity = "Max Capacity"
        static let powerSourceState = "Power Source State"
        static let isCharging = "Is Charging"
    }

    /// `Power Source State` 取值；缺该键时快照必须是 `"unknown"`，不得写成「电池供电」。
    enum PowerSourceState {
        static let acPower = "AC Power"
        static let batteryPower = "Battery Power"
    }

    /// 测试时间锚点，避免 `Date()` 造成信任度/过期判定抖动。
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - IOPS 描述字典

    /// 组装 IOPS 电源描述。参数为 `nil` 表示**省略该键**（不是写入 JSON null，也不是写入 0 / false）。
    ///
    /// - Parameters:
    ///   - currentCapacity: `Current Capacity`；缺键则百分比不可用。
    ///   - maxCapacity: `Max Capacity`；缺键则百分比不可用。
    ///   - powerSourceState: `Power Source State`；缺键则 `drawingFrom == "unknown"`。
    ///   - isCharging: `Is Charging`；缺键则兼容值为 false，但 `isChargingIsAvailable == false`。
    static func powerSourceDescription(
        currentCapacity: Int? = 80,
        maxCapacity: Int? = 100,
        powerSourceState: String? = PowerSourceState.acPower,
        isCharging: Bool? = true
    ) -> [String: Any] {
        var description: [String: Any] = [:]
        if let currentCapacity {
            description[IOPSKey.currentCapacity] = currentCapacity
        }
        if let maxCapacity {
            description[IOPSKey.maxCapacity] = maxCapacity
        }
        if let powerSourceState {
            description[IOPSKey.powerSourceState] = powerSourceState
        }
        if let isCharging {
            description[IOPSKey.isCharging] = isCharging
        }
        return description
    }

    /// 四键齐全：容量 + 电源状态 + 充电标志。默认适配器供电且正在充电。
    static func completePowerSourceDescription(
        currentCapacity: Int = 80,
        maxCapacity: Int = 100,
        powerSourceState: String = PowerSourceState.acPower,
        isCharging: Bool = true
    ) -> [String: Any] {
        powerSourceDescription(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            powerSourceState: powerSourceState,
            isCharging: isCharging
        )
    }

    /// 缺 `Is Charging`：不得把兼容 false 当成测到的「未在充电」。
    static func descriptionMissingIsCharging(
        currentCapacity: Int = 80,
        maxCapacity: Int = 100,
        powerSourceState: String = PowerSourceState.acPower
    ) -> [String: Any] {
        powerSourceDescription(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            powerSourceState: powerSourceState,
            isCharging: nil
        )
    }

    /// 缺 `Power Source State`：不得当成「电池供电」或「未使用适配器」。
    static func descriptionMissingPowerSourceState(
        currentCapacity: Int = 80,
        maxCapacity: Int = 100,
        isCharging: Bool = false
    ) -> [String: Any] {
        powerSourceDescription(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            powerSourceState: nil,
            isCharging: isCharging
        )
    }

    /// 同时缺信任相关两键：`Is Charging` 与 `Power Source State`。
    static func descriptionMissingTrustKeys(
        currentCapacity: Int = 80,
        maxCapacity: Int = 100
    ) -> [String: Any] {
        powerSourceDescription(
            currentCapacity: currentCapacity,
            maxCapacity: maxCapacity,
            powerSourceState: nil,
            isCharging: nil
        )
    }

    /// 缺 `Current Capacity` / `Max Capacity`：电量百分比不可用，不得写成真实 0%。
    static func descriptionMissingCapacityKeys(
        powerSourceState: String = PowerSourceState.acPower,
        isCharging: Bool = true
    ) -> [String: Any] {
        powerSourceDescription(
            currentCapacity: nil,
            maxCapacity: nil,
            powerSourceState: powerSourceState,
            isCharging: isCharging
        )
    }

    /// 空描述：所有 IOPS 键均缺失。
    static func emptyPowerSourceDescription() -> [String: Any] {
        [:]
    }

    // MARK: - BatterySnapshot

    /// 由注入的 IOPS 描述构造快照。`watts == nil` 表示未提供电池侧功率（不是真实 0W）。
    static func snapshot(
        description: [String: Any],
        capturedAt: Date = capturedAt,
        watts: Double? = 18.0
    ) -> BatterySnapshot {
        BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: capturedAt,
            watts: watts
        )
    }

    /// IOPS 四键齐全的快照；完整度足够走 DataTrust（在采样足够新鲜时可为 trusted）。
    static func completeSnapshot(
        currentCapacity: Int = 80,
        maxCapacity: Int = 100,
        powerSourceState: String = PowerSourceState.acPower,
        isCharging: Bool = true,
        capturedAt: Date = capturedAt,
        watts: Double? = 18.0
    ) -> BatterySnapshot {
        snapshot(
            description: completePowerSourceDescription(
                currentCapacity: currentCapacity,
                maxCapacity: maxCapacity,
                powerSourceState: powerSourceState,
                isCharging: isCharging
            ),
            capturedAt: capturedAt,
            watts: watts
        )
    }

    /// 缺 `Is Charging` 的快照：`isCompleteForDataTrust == false`。
    static func snapshotMissingIsCharging(
        powerSourceState: String = PowerSourceState.acPower,
        capturedAt: Date = capturedAt,
        watts: Double? = 12.0
    ) -> BatterySnapshot {
        snapshot(
            description: descriptionMissingIsCharging(powerSourceState: powerSourceState),
            capturedAt: capturedAt,
            watts: watts
        )
    }

    /// 缺 `Power Source State` 的快照：`drawingFrom == "unknown"`。
    static func snapshotMissingPowerSourceState(
        isCharging: Bool = false,
        capturedAt: Date = capturedAt,
        watts: Double? = -8.5
    ) -> BatterySnapshot {
        snapshot(
            description: descriptionMissingPowerSourceState(isCharging: isCharging),
            capturedAt: capturedAt,
            watts: watts
        )
    }

    /// 同时缺充电键与电源状态键。
    static func snapshotMissingTrustKeys(
        capturedAt: Date = capturedAt,
        watts: Double? = 0.2
    ) -> BatterySnapshot {
        snapshot(
            description: descriptionMissingTrustKeys(),
            capturedAt: capturedAt,
            watts: watts
        )
    }

    /// 缺容量键：历史样本不得把百分比写成 0。
    static func snapshotMissingCapacityKeys(
        capturedAt: Date = capturedAt,
        watts: Double? = 18.0
    ) -> BatterySnapshot {
        snapshot(
            description: descriptionMissingCapacityKeys(),
            capturedAt: capturedAt,
            watts: watts
        )
    }

    // MARK: - HistorySample

    /// 由快照组装历史点。`pluggedIn` / `useAdapter` 只透传 batt 的 `Bool?`，缺 batt 则为 nil，
    /// 不得用 IOPS `Power Source State` 或 IOKit AC 状态冒充。
    /// 方向缺省按快照分类；百分比/瓦数仅在快照标记可用时写入。
    static func liveHistorySample(
        from snapshot: BatterySnapshot,
        at date: Date? = nil,
        direction: PowerDirection? = nil,
        battStatus: BattStatusSnapshot? = nil,
        thermal: String? = nil,
        enginePhase: String? = nil,
        recordingPaused: Bool = false,
        intervalSeconds: Int? = nil,
        segmentId: String? = nil,
        sleepGap: Bool? = nil
    ) -> HistorySample {
        let at = date ?? snapshot.capturedAt
        let flowDirection = direction ?? EnergyFlow.classify(snapshot).direction
        return HistorySample.makeLive(
            at: at,
            snapshot: snapshot,
            direction: flowDirection,
            battStatus: battStatus,
            thermal: thermal,
            enginePhase: enginePhase,
            recordingPaused: recordingPaused,
            intervalSeconds: intervalSeconds,
            segmentId: segmentId,
            sleepGap: sleepGap
        )
    }

    /// IOPS 键齐全的历史样本。batt 状态默认 nil，避免把缺失写成 false。
    static func completeHistorySample(
        capturedAt: Date = capturedAt,
        isCharging: Bool = true,
        watts: Double? = 18.0,
        battStatus: BattStatusSnapshot? = nil,
        intervalSeconds: Int? = 10
    ) -> HistorySample {
        liveHistorySample(
            from: completeSnapshot(
                isCharging: isCharging,
                capturedAt: capturedAt,
                watts: watts
            ),
            battStatus: battStatus,
            intervalSeconds: intervalSeconds
        )
    }

    /// 缺 `Is Charging`：样本方向仍按瓦数分类；不得因兼容 false 改写成待机。
    static func historySampleMissingIsCharging(
        capturedAt: Date = capturedAt,
        watts: Double? = 12.0,
        battStatus: BattStatusSnapshot? = nil
    ) -> HistorySample {
        liveHistorySample(
            from: snapshotMissingIsCharging(capturedAt: capturedAt, watts: watts),
            battStatus: battStatus
        )
    }

    /// 缺 `Power Source State`：`pluggedIn` 仍只来自 batt；IOPS 缺键不得填 false。
    static func historySampleMissingPowerSourceState(
        capturedAt: Date = capturedAt,
        watts: Double? = -8.5,
        battStatus: BattStatusSnapshot? = nil
    ) -> HistorySample {
        liveHistorySample(
            from: snapshotMissingPowerSourceState(capturedAt: capturedAt, watts: watts),
            battStatus: battStatus
        )
    }

    /// 缺容量键：`percent` 必须为 nil，不得写成 0。
    static func historySampleMissingCapacityKeys(
        capturedAt: Date = capturedAt,
        watts: Double? = 18.0
    ) -> HistorySample {
        liveHistorySample(
            from: snapshotMissingCapacityKeys(capturedAt: capturedAt, watts: watts)
        )
    }

    /// 瓦数未注入：`watts` / `wattsAvailable` 表示缺失，不得写成真实 0W。
    static func historySampleMissingWatts(
        capturedAt: Date = capturedAt
    ) -> HistorySample {
        liveHistorySample(
            from: completeSnapshot(capturedAt: capturedAt, watts: nil)
        )
    }
}

/// 夹具自身契约：完整键 vs 缺键不得被 0 / false 冒充。不读本机 IOKit、不跑 batt。
final class TestFixturesTests: XCTestCase {
    func testCompleteDescriptionContainsAllIOPSKeys() {
        let description = TestFixtures.completePowerSourceDescription()
        XCTAssertEqual(description[TestFixtures.IOPSKey.currentCapacity] as? Int, 80)
        XCTAssertEqual(description[TestFixtures.IOPSKey.maxCapacity] as? Int, 100)
        XCTAssertEqual(
            description[TestFixtures.IOPSKey.powerSourceState] as? String,
            TestFixtures.PowerSourceState.acPower
        )
        XCTAssertEqual(description[TestFixtures.IOPSKey.isCharging] as? Bool, true)
        XCTAssertEqual(description.count, 4)
    }

    func testMissingIOPSKeysAreAbsentNotZeroOrFalse() {
        let missingCharging = TestFixtures.descriptionMissingIsCharging()
        XCTAssertNil(missingCharging[TestFixtures.IOPSKey.isCharging])
        XCTAssertNotNil(missingCharging[TestFixtures.IOPSKey.powerSourceState])

        let missingState = TestFixtures.descriptionMissingPowerSourceState()
        XCTAssertNil(missingState[TestFixtures.IOPSKey.powerSourceState])
        XCTAssertEqual(missingState[TestFixtures.IOPSKey.isCharging] as? Bool, false)

        let empty = TestFixtures.emptyPowerSourceDescription()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty[TestFixtures.IOPSKey.currentCapacity])
        XCTAssertNil(empty[TestFixtures.IOPSKey.isCharging])
    }

    func testCompleteSnapshotIsTrustedWhenFresh() {
        let snapshot = TestFixtures.completeSnapshot()
        XCTAssertTrue(snapshot.isChargingIsAvailable)
        XCTAssertTrue(snapshot.externalConnectedIsAvailable)
        XCTAssertTrue(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(snapshot.percent, 80)
        XCTAssertEqual(snapshot.drawingFrom, "电源适配器")
        XCTAssertEqual(snapshot.watts, 18.0)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: snapshot,
                now: snapshot.capturedAt,
                interval: 10
            ),
            .trusted
        )
    }

    func testSnapshotMissingIsChargingIsNotMeasuredFalse() {
        let snapshot = TestFixtures.snapshotMissingIsCharging()
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertFalse(snapshot.mappedIsCharging)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(snapshot.isChargingAvailability, .deviceDidNotProvide)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: snapshot,
                now: snapshot.capturedAt,
                interval: 10
            ),
            .unavailable
        )
        // 缺充电键不得改写瓦数分类：+12W 仍是充电。
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .charging)
    }

    func testSnapshotMissingPowerSourceStateIsNotBatteryPower() {
        let snapshot = TestFixtures.snapshotMissingPowerSourceState()
        XCTAssertEqual(snapshot.drawingFrom, "unknown")
        XCTAssertFalse(snapshot.drawingFromIsAvailable)
        XCTAssertFalse(snapshot.externalConnectedIsAvailable)
        XCTAssertFalse(snapshot.externalConnected)
        XCTAssertNotEqual(snapshot.drawingFrom, "电池供电")
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .discharging)
    }

    func testHistorySampleOmitsUnavailablePercentAndWatts() {
        let missingPercent = TestFixtures.historySampleMissingCapacityKeys()
        XCTAssertNil(missingPercent.percent)
        XCTAssertNotEqual(missingPercent.percent, 0)
        XCTAssertEqual(missingPercent.watts, 18.0)
        XCTAssertTrue(missingPercent.wattsAvailable)

        let missingWatts = TestFixtures.historySampleMissingWatts()
        XCTAssertEqual(missingWatts.percent, 80)
        XCTAssertNil(missingWatts.watts)
        XCTAssertFalse(missingWatts.wattsAvailable)
        XCTAssertEqual(missingWatts.direction, EnergyFlowDirection.unknown.rawValue)
    }

    func testHistorySampleDoesNotFillPluggedInFromIOPS() {
        let complete = TestFixtures.completeHistorySample()
        XCTAssertNil(complete.pluggedIn)
        XCTAssertNil(complete.useAdapter)
        XCTAssertEqual(complete.percent, 80)
        XCTAssertEqual(complete.watts, 18.0)
        XCTAssertEqual(complete.direction, EnergyFlowDirection.charge.rawValue)

        let missingState = TestFixtures.historySampleMissingPowerSourceState()
        XCTAssertNil(missingState.pluggedIn)
        XCTAssertNil(missingState.useAdapter)
        XCTAssertEqual(missingState.direction, EnergyFlowDirection.discharge.rawValue)

        let withBatt = TestFixtures.completeHistorySample(
            battStatus: BattStatusSnapshot(pluggedIn: true, useAdapter: false)
        )
        XCTAssertEqual(withBatt.pluggedIn, true)
        XCTAssertEqual(withBatt.useAdapter, false)
    }
}

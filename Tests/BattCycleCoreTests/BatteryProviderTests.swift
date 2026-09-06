import BattCycleCore
import XCTest

final class BatteryProviderTests: XCTestCase {
    func testMockProviderReturnsInjectedSnapshot() {
        let injected = BatterySnapshot(
            percent: 72,
            drawingFrom: "电池供电",
            isCharging: false,
            externalConnected: false,
            watts: -9.5,
            summary: "注入",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            isAvailable: true,
            wattsIsAvailable: true
        )
        var provider = MockBatteryProvider(snapshot: injected)

        XCTAssertEqual(provider.capture(), injected)
        XCTAssertEqual(provider.capture().percent, 72)
        XCTAssertEqual(provider.capture().watts, -9.5)
        XCTAssertTrue(provider.capture().isAvailable)
        XCTAssertTrue(provider.capture().wattsIsAvailable)
        XCTAssertFalse(provider.capture().wattsIsTrueZero)

        let updated = BatterySnapshot(
            percent: 73,
            drawingFrom: "电源适配器",
            isCharging: true,
            externalConnected: true,
            watts: 11,
            summary: "更新",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010),
            isAvailable: true,
            wattsIsAvailable: true
        )
        provider.snapshot = updated
        XCTAssertEqual(provider.capture().percent, 73)
        XCTAssertEqual(EnergyFlow.classify(provider.capture()).direction, .charging)
    }

    func testMockCaptureFailureIsNotTrueZero() {
        let provider = MockBatteryProvider(snapshot: .empty)
        let snapshot = provider.capture()
        XCTAssertEqual(snapshot.watts, 0)
        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertFalse(snapshot.percentIsAvailable)
        XCTAssertFalse(snapshot.wattsIsAvailable)
        XCTAssertFalse(snapshot.wattsIsTrueZero)
        XCTAssertEqual(snapshot.availability, .currentlyUnavailable)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .unknown)
        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertFalse(snapshot.externalConnectedIsAvailable)
        XCTAssertFalse(snapshot.drawingFromIsAvailable)
        XCTAssertEqual(snapshot.drawingFrom, "unknown")
        XCTAssertEqual(snapshot.isChargingAvailability, .currentlyUnavailable)
        XCTAssertEqual(snapshot.externalConnectedAvailability, .currentlyUnavailable)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, interval: 10),
            .unavailable
        )
    }

    func testTrueZeroAvailableSnapshotIsTrustedWhenFresh() {
        let now = Date()
        let snapshot = BatterySnapshot(
            percent: 80,
            drawingFrom: "电源适配器",
            isCharging: false,
            externalConnected: true,
            watts: 0,
            summary: "真实 0W",
            capturedAt: now,
            isAvailable: true,
            wattsIsAvailable: true
        )
        let provider = MockBatteryProvider(snapshot: snapshot)
        let captured = provider.capture()
        XCTAssertTrue(captured.wattsIsTrueZero)
        XCTAssertTrue(captured.wattsIsAvailable)
        XCTAssertEqual(captured.watts, 0)
        XCTAssertEqual(EnergyFlow.classify(captured).direction, .idle)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: captured, now: now, interval: 10),
            .trusted
        )
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(
                snapshot: captured,
                now: now.addingTimeInterval(11),
                interval: 10
            ),
            .stale
        )
    }

    func testPowerMetricsFromMockDoesNotAliasBatteryWattsToAdapter() {
        let provider = MockBatteryProvider(
            snapshot: BatterySnapshot(
                percent: 55,
                drawingFrom: "电源适配器",
                isCharging: true,
                externalConnected: true,
                watts: 21.5,
                summary: "注入",
                capturedAt: Date(),
                isAvailable: true,
                wattsIsAvailable: true
            )
        )
        let metrics = PowerMetrics.assemble(snapshot: provider.capture())
        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 21.5)
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertNil(metrics.adapterRatedMaxWatts.value)
        XCTAssertNil(metrics.systemPowerWatts.value)
    }

    func testIOKitProviderConformsAndCanBeSubstituted() {
        let mock: any BatteryProviding = MockBatteryProvider(snapshot: .empty)
        let live: any BatteryProviding = IOKitBatteryProvider()
        XCTAssertEqual(mock.capture().isAvailable, false)
        XCTAssertEqual(live.capture().capturedAt.timeIntervalSince1970.isFinite, true)
    }

    func testMissingIsChargingIsNotMeasuredFalseOrTrusted() {
        let now = Date()
        var description = Self.basePowerSourceDescription(state: "AC Power", includeCharging: false)
        description.removeValue(forKey: "Is Charging")
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: now,
            watts: 12.0
        )
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertEqual(snapshot.isChargingAvailability, .deviceDidNotProvide)
        XCTAssertFalse(snapshot.mappedIsCharging)
        XCTAssertEqual(snapshot.drawingFrom, "电源适配器")
        XCTAssertTrue(snapshot.externalConnectedIsAvailable)
        XCTAssertTrue(snapshot.externalConnected)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: 10),
            .unavailable
        )
        XCTAssertFalse(DataTrustEvaluator.isConflicting(snapshot))
        // 缺充电键不得改写瓦数分类：+12W 仍是充电。
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .charging)
        XCTAssertEqual(snapshot.classifiedEnergyFlow().direction, .charging)
    }

    func testMissingPowerSourceStateIsNotBatteryPowerOrTrusted() {
        let now = Date()
        var description = Self.basePowerSourceDescription(state: "AC Power", charging: false)
        description.removeValue(forKey: "Power Source State")
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: now,
            watts: -8.5
        )
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.drawingFrom, "unknown")
        XCTAssertFalse(snapshot.drawingFromIsAvailable)
        XCTAssertFalse(snapshot.externalConnectedIsAvailable)
        XCTAssertFalse(snapshot.externalConnected)
        XCTAssertEqual(snapshot.externalConnectedAvailability, .deviceDidNotProvide)
        XCTAssertFalse(snapshot.mappedExternalConnected)
        XCTAssertTrue(snapshot.isChargingIsAvailable)
        XCTAssertFalse(snapshot.isCharging)
        XCTAssertFalse(snapshot.isCompleteForDataTrust)
        XCTAssertNotEqual(snapshot.drawingFrom, "电池供电")
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: 10),
            .unavailable
        )
        // 缺电源状态不得改写瓦数分类：−8.5W 仍是放电。
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .discharging)
        XCTAssertEqual(snapshot.classifiedEnergyFlow().direction, .discharging)
    }

    func testPresentBatteryPowerStillLabelsBatterySupply() {
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            Self.basePowerSourceDescription(state: "Battery Power", charging: false),
            capturedAt: Date(),
            watts: -6.0
        )
        XCTAssertEqual(snapshot.drawingFrom, "电池供电")
        XCTAssertTrue(snapshot.drawingFromIsAvailable)
        XCTAssertTrue(snapshot.externalConnectedIsAvailable)
        XCTAssertFalse(snapshot.externalConnected)
        XCTAssertTrue(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .discharging)
    }

    func testMockProviderInjectsMissingPowerSourceKeys() {
        let now = Date()
        var description = Self.basePowerSourceDescription(state: "AC Power", includeCharging: false)
        description.removeValue(forKey: "Is Charging")
        description.removeValue(forKey: "Power Source State")
        let injected = BatterySnapshot.fromPowerSourceDescription(
            description,
            capturedAt: now,
            watts: 0.2
        )
        let provider = MockBatteryProvider(snapshot: injected)
        let captured = provider.capture()
        XCTAssertEqual(captured, injected)
        XCTAssertFalse(captured.isChargingIsAvailable)
        XCTAssertFalse(captured.externalConnectedIsAvailable)
        XCTAssertEqual(captured.drawingFrom, "unknown")
        XCTAssertEqual(captured.percent, 80)
        XCTAssertEqual(captured.watts, 0.2)
        XCTAssertTrue(captured.wattsIsAvailable)
        XCTAssertEqual(EnergyFlow.classify(captured).direction, .idle)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: captured, now: now, interval: 10),
            .unavailable
        )
    }

    func testCompleteInjectedDescriptionCanBeTrusted() {
        let now = Date()
        let snapshot = BatterySnapshot.fromPowerSourceDescription(
            Self.basePowerSourceDescription(state: "AC Power", charging: true),
            capturedAt: now,
            watts: 18.0
        )
        XCTAssertTrue(snapshot.isChargingIsAvailable)
        XCTAssertTrue(snapshot.isCharging)
        XCTAssertTrue(snapshot.externalConnected)
        XCTAssertEqual(snapshot.drawingFrom, "电源适配器")
        XCTAssertTrue(snapshot.isCompleteForDataTrust)
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, now: now, interval: 10),
            .trusted
        )
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .charging)
    }

    private static func basePowerSourceDescription(
        state: String,
        charging: Bool = false,
        includeCharging: Bool = true
    ) -> [String: Any] {
        var description: [String: Any] = [
            "Current Capacity": 80,
            "Max Capacity": 100,
            "Power Source State": state
        ]
        if includeCharging {
            description["Is Charging"] = charging
        }
        return description
    }
}

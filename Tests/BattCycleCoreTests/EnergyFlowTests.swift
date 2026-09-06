import BattCycleCore
import XCTest

final class EnergyFlowTests: XCTestCase {
    func testChargingWhenWattsAboveThreshold() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 18.4,
            isCharging: false,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(flow.direction, .charging)
        XCTAssertEqual(flow.labelZH, "充电")
        XCTAssertEqual(flow.symbolName, "bolt.fill")
        XCTAssertTrue(flow.accessibilityLabel.contains("充电"))
        XCTAssertTrue(flow.accessibilityLabel.contains("适配器流向电池") || flow.accessibilityLabel.contains("从适配器流向电池"))
    }

    func testChargingWhenIsChargingEvenIfWattsSmall() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 0.2,
            isCharging: true,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(flow.direction, .charging)
    }

    func testDischargingWhenWattsBelowNegativeThreshold() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: -22.0,
            isCharging: false,
            drawingFrom: "电池供电",
            externalConnected: false
        )
        XCTAssertEqual(flow.direction, .discharging)
        XCTAssertEqual(flow.labelZH, "放电")
        XCTAssertTrue(flow.accessibilityLabel.contains("系统负载"))
        XCTAssertFalse(flow.accessibilityLabel.contains("插头"))
    }

    func testIdleWhenAvailableNearZeroAndNotCharging() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 0.4,
            isCharging: false,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(flow.direction, .idle)
        XCTAssertEqual(flow.labelZH, "待机")
        XCTAssertEqual(EnergyFlow.idlePowerThresholdWatts, 1.0)
    }

    func testUnknownWhenSnapshotUnavailable() {
        let flow = EnergyFlow.classify(.empty)
        XCTAssertEqual(flow.direction, .unknown)
        XCTAssertEqual(flow.labelZH, "未知")
    }

    func testUnknownWhenWattsMissingEvenIfChargingFlagSet() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: false,
            watts: 0,
            isCharging: true,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(flow.direction, .unknown)
    }

    func testConflictingChargingFlagAndNegativeWattsIsUnknown() {
        let snapshot = BatterySnapshot(
            percent: 70,
            drawingFrom: "电池供电",
            isCharging: true,
            externalConnected: false,
            watts: -12.5,
            summary: "冲突",
            capturedAt: Date(),
            isAvailable: true,
            wattsIsAvailable: true
        )
        let flow = EnergyFlow.classify(snapshot)
        XCTAssertEqual(flow.direction, .unknown)
        XCTAssertTrue(DataTrustEvaluator.isConflicting(snapshot))
        XCTAssertEqual(
            DataTrustEvaluator.evaluate(snapshot: snapshot, interval: 10),
            .conflicting
        )
    }

    func testTrueZeroWattsIsIdleNotUnknown() {
        let snapshot = BatterySnapshot(
            percent: 80,
            drawingFrom: "电源适配器",
            isCharging: false,
            externalConnected: true,
            watts: 0,
            summary: "真实 0W",
            capturedAt: Date(),
            isAvailable: true,
            wattsIsAvailable: true
        )
        XCTAssertTrue(snapshot.wattsIsTrueZero)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .idle)
        XCTAssertEqual(snapshot.classifiedEnergyFlow().direction, .idle)
    }

    func testCaptureFailureZeroIsUnknownNotIdle() {
        XCTAssertEqual(BatterySnapshot.empty.watts, 0)
        XCTAssertFalse(BatterySnapshot.empty.isAvailable)
        XCTAssertFalse(BatterySnapshot.empty.wattsIsAvailable)
        XCTAssertFalse(BatterySnapshot.empty.wattsIsTrueZero)
        XCTAssertEqual(EnergyFlow.classify(.empty).direction, .unknown)
        XCTAssertEqual(BatterySnapshot.empty.classifiedEnergyFlow().direction, .unknown)
    }

    /// 缺测瓦数（兼容字段仍为 0）与真实 0W 必须分开：前者 unknown，后者 idle。
    func testUnknownWattsAtZeroIsNotTrueZeroIdle() {
        let missing = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: false,
            watts: 0,
            isCharging: false,
            drawingFrom: "unknown",
            externalConnected: false
        )
        let trueZero = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 0,
            isCharging: false,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(missing.direction, .unknown)
        XCTAssertEqual(trueZero.direction, .idle)
        XCTAssertNotEqual(missing.direction, trueZero.direction)
    }

    /// 调用方把缺 `IsCharging` 映射成 false 传入 Bool API 时，正瓦数仍按瓦数判为充电。
    func testMappedMissingIsChargingDoesNotOverridePositiveWatts() {
        let viaBool = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 12.0,
            isCharging: false,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(viaBool.direction, .charging)

        let snapshot = BatterySnapshot(
            percent: 80,
            drawingFrom: "电源适配器",
            isCharging: false,
            externalConnected: true,
            watts: 12.0,
            summary: "缺充电键",
            capturedAt: Date(),
            isAvailable: true,
            wattsIsAvailable: true,
            isChargingIsAvailable: false
        )
        XCTAssertFalse(snapshot.mappedIsCharging)
        XCTAssertFalse(snapshot.isChargingIsAvailable)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .charging)
        XCTAssertEqual(snapshot.classifiedEnergyFlow().direction, .charging)
    }

    /// 映射缺省 false 不得把负瓦数改写成「未充电待机」；−8.5W 仍是放电。
    func testMappedMissingIsChargingDoesNotOverrideNegativeWatts() {
        let viaBool = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: -8.5,
            isCharging: false,
            drawingFrom: "unknown",
            externalConnected: false
        )
        XCTAssertEqual(viaBool.direction, .discharging)

        let snapshot = BatterySnapshot(
            percent: 64,
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: -8.5,
            summary: "缺充电键",
            capturedAt: Date(),
            isAvailable: true,
            wattsIsAvailable: true,
            isChargingIsAvailable: false,
            externalConnectedIsAvailable: false
        )
        XCTAssertFalse(snapshot.mappedIsCharging)
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .discharging)
        XCTAssertEqual(snapshot.classifiedEnergyFlow().direction, .discharging)
    }

    /// 近零瓦数 + 映射 false：按瓦数待机，而不是把缺键当成测到的「未充电」去改写流向。
    func testMappedMissingIsChargingNearZeroFollowsWattsAsIdle() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: 0.2,
            isCharging: false,
            drawingFrom: "unknown",
            externalConnected: false
        )
        XCTAssertEqual(flow.direction, .idle)
    }

    /// 阈值边界：±1W 必须是充/放电，不得落成 unknown。
    func testThresholdWattsAreChargingOrDischargingNotUnknown() {
        XCTAssertEqual(
            EnergyFlow.classify(
                isAvailable: true,
                wattsIsAvailable: true,
                watts: 1.0,
                isCharging: false,
                drawingFrom: "电源适配器",
                externalConnected: true
            ).direction,
            .charging
        )
        XCTAssertEqual(
            EnergyFlow.classify(
                isAvailable: true,
                wattsIsAvailable: true,
                watts: -1.0,
                isCharging: false,
                drawingFrom: "电池供电",
                externalConnected: false
            ).direction,
            .discharging
        )
        XCTAssertEqual(
            EnergyFlow.classify(
                isAvailable: true,
                wattsIsAvailable: true,
                watts: 0.99,
                isCharging: false,
                drawingFrom: "电源适配器",
                externalConnected: true
            ).direction,
            .idle
        )
        XCTAssertEqual(
            EnergyFlow.classify(
                isAvailable: true,
                wattsIsAvailable: true,
                watts: -0.99,
                isCharging: false,
                drawingFrom: "电池供电",
                externalConnected: false
            ).direction,
            .idle
        )
    }

    /// 即使系统显示正在用适配器，放电文案也只指向本机负载，绝不写成回馈插头。
    func testDischargingIsNotModeledAsFeedingThePlug() {
        let flow = EnergyFlow.classify(
            isAvailable: true,
            wattsIsAvailable: true,
            watts: -15.0,
            isCharging: false,
            drawingFrom: "电源适配器",
            externalConnected: true
        )
        XCTAssertEqual(flow.direction, .discharging)
        XCTAssertTrue(flow.accessibilityLabel.contains("系统负载"))
        XCTAssertTrue(flow.accessibilityLabel.contains("供给本机"))
        XCTAssertFalse(flow.accessibilityLabel.contains("插头"))
        XCTAssertFalse(flow.accessibilityLabel.contains("回馈"))
        XCTAssertFalse(flow.accessibilityLabel.contains("流向插头"))
        XCTAssertFalse(flow.symbolName.contains("plug"))
    }

    func testSnapshotClassifyMatchesMappedHelper() {
        let snapshot = BatterySnapshot(
            percent: 50,
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: 6.5,
            summary: "映射对齐",
            capturedAt: Date(),
            isAvailable: true,
            wattsIsAvailable: true,
            isChargingIsAvailable: false,
            externalConnectedIsAvailable: false
        )
        XCTAssertEqual(EnergyFlow.classify(snapshot), snapshot.classifiedEnergyFlow())
        XCTAssertEqual(EnergyFlow.classify(snapshot).direction, .charging)
    }
}

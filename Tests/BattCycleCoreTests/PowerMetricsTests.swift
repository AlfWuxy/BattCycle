import BattCycleCore
import XCTest

final class PowerMetricsTests: XCTestCase {
    func testDoesNotCopyBatteryWattsIntoAdapterWatts() {
        let snapshot = makeSnapshot(percent: 64, watts: 18.7)

        let metrics = PowerMetrics.assemble(snapshot: snapshot, adapterDetails: nil)

        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 18.7)
        XCTAssertEqual(metrics.batteryNetPowerWatts.availability, .available)
        XCTAssertEqual(metrics.batteryNetPowerWatts.displayNameZH, "电池净功率")
        XCTAssertEqual(metrics.batteryNetPowerWatts.source, .iokit)

        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertEqual(metrics.adapterOutputWatts.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.adapterRatedMaxWatts.value)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.adapterNegotiatedWatts.value)
        XCTAssertNil(metrics.systemPowerWatts.value)
        XCTAssertNotEqual(metrics.adapterOutputWatts.value, metrics.batteryNetPowerWatts.value)
        XCTAssertNotEqual(metrics.adapterRatedMaxWatts.value, metrics.batteryNetPowerWatts.value)
        XCTAssertNil(metrics.adapterCurrentMilliamps.value)
        XCTAssertEqual(metrics.adapterCurrentMilliamps.availability, .deviceDidNotProvide)
    }

    func testRatedAdapterWattsComeFromAdapterDetailsNotBattery() {
        let snapshot = makeSnapshot(percent: 50, watts: 12.3)

        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: ["Watts": 96],
            adapterPhysicallyConnected: true
        )

        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 12.3)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 96)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.source, .iokit)
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertEqual(metrics.adapterOutputWatts.availability, .deviceDidNotProvide)
        XCTAssertNotEqual(metrics.adapterRatedMaxWatts.value, metrics.batteryNetPowerWatts.value)
        XCTAssertEqual(metrics.adapterPhysicallyConnected.value, true)
        XCTAssertEqual(metrics.systemUsingAdapter.value, true)
        XCTAssertEqual(metrics.systemUsingAdapter.displayNameZH, "系统正在使用适配器")
        XCTAssertNil(metrics.adapterNegotiatedWatts.value)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.availability, .deviceDidNotProvide)
    }

    func testDoesNotFillAdapterPresenceFromIOPSACState() {
        let snapshot = makeSnapshot(
            percent: 40,
            isCharging: false,
            watts: 0.2
        )

        let metrics = PowerMetrics.assemble(snapshot: snapshot)

        XCTAssertEqual(metrics.systemUsingAdapter.value, true)
        XCTAssertNil(metrics.adapterPhysicallyConnected.value)
        XCTAssertEqual(metrics.adapterPhysicallyConnected.availability, .deviceDidNotProvide)
    }

    func testChargePercentLimitIsUnsupported() {
        let metrics = PowerMetrics.assemble(snapshot: .empty)
        XCTAssertNil(metrics.chargePercentLimit.value)
        XCTAssertEqual(metrics.chargePercentLimit.availability, .unsupported)
        XCTAssertEqual(metrics.chargePowerLimitWatts.availability, .unsupported)
        XCTAssertNil(metrics.chargePowerLimitWatts.value)
        XCTAssertEqual(metrics.chargePowerLimitWatts.source, .unavailable)
    }

    func testUnavailableSnapshotDoesNotPresentZeroAsLivePower() {
        let metrics = PowerMetrics.assemble(snapshot: .empty)
        XCTAssertEqual(BatterySnapshot.empty.watts, 0)
        XCTAssertNil(metrics.batteryPercent.value)
        XCTAssertNil(metrics.batteryNetPowerWatts.value)
        XCTAssertEqual(metrics.batteryNetPowerWatts.availability, .currentlyUnavailable)
        XCTAssertNil(metrics.systemUsingAdapter.value)
        XCTAssertEqual(metrics.systemUsingAdapter.availability, .currentlyUnavailable)
        XCTAssertNil(metrics.isCharging.value)
        XCTAssertEqual(metrics.isCharging.availability, .currentlyUnavailable)
        XCTAssertNotEqual(metrics.systemUsingAdapter.value, false)
        XCTAssertNotEqual(metrics.isCharging.value, false)
    }

    func testTrueZeroBatteryWattsStayOnBatteryMetricOnly() {
        let snapshot = makeSnapshot(
            percent: 80,
            isCharging: false,
            watts: 0
        )
        XCTAssertTrue(snapshot.wattsIsTrueZero)

        let metrics = PowerMetrics.assemble(snapshot: snapshot, adapterDetails: ["Watts": 70])
        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 0)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 70)
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertNil(metrics.adapterCurrentMilliamps.value)
    }

    func testMissingIOPSChargingAndACFlagsAreNotMeasuredFalse() {
        let snapshot = makeSnapshot(
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: 4.2,
            isChargingIsAvailable: false,
            externalConnectedIsAvailable: false
        )

        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: nil,
            capturedAt: snapshot.capturedAt
        )

        XCTAssertNil(metrics.systemUsingAdapter.value)
        XCTAssertEqual(metrics.systemUsingAdapter.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.isCharging.value)
        XCTAssertEqual(metrics.isCharging.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.systemUsingAdapter.displayNameZH, "系统正在使用适配器")
        XCTAssertEqual(metrics.isCharging.displayNameZH, "正在充电")
    }

    func testAssembleOverridesCanHideCompatFalseFlags() {
        let snapshot = makeSnapshot(isCharging: false, externalConnected: false, watts: 1.0)
        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: nil,
            capturedAt: snapshot.capturedAt,
            systemUsingAdapterIsAvailable: false,
            isChargingIsAvailable: false
        )
        XCTAssertNil(metrics.systemUsingAdapter.value)
        XCTAssertEqual(metrics.systemUsingAdapter.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.isCharging.value)
        XCTAssertEqual(metrics.isCharging.availability, .deviceDidNotProvide)
    }

    func testPresentChargingFalseIsMeasuredNotMissing() {
        let snapshot = makeSnapshot(isCharging: false, watts: 0.4)
        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: nil,
            capturedAt: snapshot.capturedAt
        )
        XCTAssertEqual(metrics.isCharging.value, false)
        XCTAssertEqual(metrics.isCharging.availability, .available)
        XCTAssertEqual(metrics.systemUsingAdapter.value, true)
        XCTAssertEqual(metrics.systemUsingAdapter.availability, .available)
    }

    func testAssembleUsesPassedSnapshotAndCapturedAtWithoutCallingProvider() {
        let first = makeSnapshot(percent: 11, watts: 3.3, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeSnapshot(percent: 99, watts: 30.0, capturedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let provider = SequencingBatteryProvider(snapshots: [first, second])
        let passedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let passed = provider.capture()
        XCTAssertEqual(passed.percent, 11)
        XCTAssertEqual(provider.captureCount, 1)

        let metrics = PowerMetrics.assemble(
            snapshot: passed,
            adapterDetails: ["Watts": 140],
            capturedAt: passedAt
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(metrics.batteryPercent.value, 11)
        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 3.3)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 140)
        XCTAssertEqual(metrics.batteryPercent.capturedAt, passedAt)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.capturedAt, passedAt)

        let later = provider.capture()
        XCTAssertEqual(later.percent, 99)
        XCTAssertEqual(provider.captureCount, 2)
        XCTAssertEqual(metrics.batteryPercent.value, 11)
        XCTAssertNotEqual(metrics.batteryPercent.value, later.percent)
    }

    func testCaptureCallsProviderOnceThenAssemblesThatSnapshot() {
        let first = makeSnapshot(percent: 22, watts: 5.5, capturedAt: Date(timeIntervalSince1970: 50))
        let second = makeSnapshot(percent: 88, watts: 19.0, capturedAt: Date(timeIntervalSince1970: 60))
        let provider = SequencingBatteryProvider(snapshots: [first, second])

        let metrics = PowerMetrics.capture(using: provider)

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(metrics.batteryPercent.value, 22)
        XCTAssertEqual(metrics.batteryNetPowerWatts.value, 5.5)
        XCTAssertEqual(metrics.batteryPercent.capturedAt, first.capturedAt)
        XCTAssertNotEqual(metrics.batteryPercent.value, 88)
    }

    func testAdapterDetailsIdentityAndCurrentDoNotCopyBatteryWatts() {
        let snapshot = makeSnapshot(watts: 18.7)
        let details: [String: Any] = [
            "Watts": 96,
            "Current": 2_500,
            "Name": "USB-C Power Adapter",
            "Manufacturer": "Apple",
            "Model": "A2304",
            "FamilyCode": 123,
            "AdapterProtocol": "USB PD",
            "PortType": "USB-C"
        ]

        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: details,
            capturedAt: snapshot.capturedAt
        )

        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 96)
        XCTAssertEqual(metrics.adapterCurrentMilliamps.value, 2_500)
        XCTAssertEqual(metrics.adapterCurrentMilliamps.unit, "mA")
        XCTAssertEqual(metrics.adapterCurrentMilliamps.displayNameZH, "适配器电流")
        XCTAssertEqual(metrics.adapterName.value, "USB-C Power Adapter")
        XCTAssertEqual(metrics.adapterManufacturer.value, "Apple")
        XCTAssertEqual(metrics.adapterModel.value, "A2304")
        XCTAssertEqual(metrics.adapterFamily.value, "123")
        XCTAssertEqual(metrics.adapterProtocol.value, "USB PD")
        XCTAssertEqual(metrics.adapterPortType.value, "USB-C")
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertEqual(metrics.adapterOutputWatts.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.adapterNegotiatedWatts.value)
        XCTAssertNotEqual(metrics.adapterCurrentMilliamps.value, 18.7)
        XCTAssertNotEqual(metrics.adapterOutputWatts.value, metrics.batteryNetPowerWatts.value)
    }

    func testDistinctAdapterPowerFillsNegotiatedWithoutCopyingRated() {
        let snapshot = makeSnapshot(watts: 9.9)
        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: ["Watts": 96, "AdapterPower": 67],
            capturedAt: snapshot.capturedAt
        )

        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 96)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.value, 67)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.availability, .available)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.displayNameZH, "适配器协商功率")
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertNotEqual(metrics.adapterNegotiatedWatts.value, metrics.batteryNetPowerWatts.value)
        XCTAssertNotEqual(metrics.adapterRatedMaxWatts.value, metrics.adapterNegotiatedWatts.value)
    }

    func testRatedWattsAreNotCopiedIntoNegotiatedOrOutput() {
        let snapshot = makeSnapshot(watts: 11)
        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: ["Watts": 70],
            capturedAt: snapshot.capturedAt
        )

        XCTAssertEqual(metrics.adapterRatedMaxWatts.value, 70)
        XCTAssertNil(metrics.adapterNegotiatedWatts.value)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.adapterOutputWatts.value)
        XCTAssertEqual(metrics.adapterOutputWatts.availability, .deviceDidNotProvide)
        XCTAssertNil(metrics.adapterName.value)
        XCTAssertEqual(metrics.adapterName.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterManufacturer.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterModel.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterFamily.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterProtocol.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterPortType.availability, .deviceDidNotProvide)
    }

    func testAdapterPowerAloneDoesNotFillRatedWatts() {
        let snapshot = makeSnapshot(watts: 8)
        let metrics = PowerMetrics.assemble(
            snapshot: snapshot,
            adapterDetails: ["AdapterPower": 45],
            capturedAt: snapshot.capturedAt
        )

        XCTAssertNil(metrics.adapterRatedMaxWatts.value)
        XCTAssertEqual(metrics.adapterRatedMaxWatts.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterNegotiatedWatts.value, 45)
        XCTAssertNil(metrics.adapterOutputWatts.value)
    }

    func testMissingAdapterIdentityShowsDeviceDidNotProvide() {
        let metrics = PowerMetrics.assemble(
            snapshot: makeSnapshot(),
            adapterDetails: nil,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(metrics.adapterName.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterManufacturer.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterModel.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterFamily.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterProtocol.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterPortType.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterCurrentMilliamps.availability, .deviceDidNotProvide)
        XCTAssertEqual(metrics.adapterName.displayNameZH, "适配器名称")
        XCTAssertEqual(metrics.adapterManufacturer.displayNameZH, "适配器厂商")
        XCTAssertEqual(metrics.adapterModel.displayNameZH, "适配器型号")
        XCTAssertEqual(metrics.adapterFamily.displayNameZH, "适配器系列")
        XCTAssertEqual(metrics.adapterProtocol.displayNameZH, "适配器协议")
        XCTAssertEqual(metrics.adapterPortType.displayNameZH, "适配器接口")
    }

    private func makeSnapshot(
        percent: Int = 50,
        drawingFrom: String = "电源适配器",
        isCharging: Bool = true,
        externalConnected: Bool = true,
        watts: Double = 10,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        isAvailable: Bool = true,
        wattsIsAvailable: Bool = true,
        isChargingIsAvailable: Bool? = nil,
        externalConnectedIsAvailable: Bool? = nil
    ) -> BatterySnapshot {
        BatterySnapshot(
            percent: percent,
            drawingFrom: drawingFrom,
            isCharging: isCharging,
            externalConnected: externalConnected,
            watts: watts,
            summary: "测试",
            capturedAt: capturedAt,
            isAvailable: isAvailable,
            wattsIsAvailable: wattsIsAvailable,
            isChargingIsAvailable: isChargingIsAvailable,
            externalConnectedIsAvailable: externalConnectedIsAvailable
        )
    }
}

/// 每次 `capture()` 返回队列中的下一个快照，用于证明 assemble 不再次读取 provider。
private final class SequencingBatteryProvider: BatteryProviding, @unchecked Sendable {
    private var remaining: [BatterySnapshot]
    private(set) var captureCount = 0

    init(snapshots: [BatterySnapshot]) {
        remaining = snapshots
    }

    func capture() -> BatterySnapshot {
        captureCount += 1
        guard !remaining.isEmpty else { return .empty }
        return remaining.removeFirst()
    }
}

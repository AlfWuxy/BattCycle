import BattCycleCore
import XCTest

/// P2.11：节拍只派生，不 capture、不读 IOKit。
final class SnapshotTickTests: XCTestCase {
    /// 调用方对 MockBatteryProvider 只 capture 一次；`derive` 不得再调 capture。
    func testDeriveDoesNotCallCaptureCallerCapturesOnce() {
        let snapshot = makeSnapshot(percent: 80, watts: 12.0, charging: true)
        let provider = CountingMockBatteryProvider(snapshot: snapshot)

        let captured = provider.capture()
        XCTAssertEqual(provider.captureCount, 1)

        let now = captured.capturedAt
        let tick = SnapshotTick.derive(
            snapshot: captured,
            now: now,
            heartbeatInterval: SamplingPolicy.heartbeatSeconds
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(tick.snapshot, captured)
        XCTAssertEqual(tick.metrics, PowerMetrics.assemble(snapshot: captured))
        XCTAssertEqual(tick.flow, EnergyFlow.classify(captured))
        XCTAssertEqual(
            tick.trust,
            DataTrustEvaluator.evaluate(
                snapshot: captured,
                now: now,
                interval: SamplingPolicy.heartbeatSeconds
            )
        )
        XCTAssertEqual(tick.flow.direction, .charging)
        XCTAssertEqual(tick.metrics.batteryNetPowerWatts.value, 12.0)
        XCTAssertEqual(tick.trust, .trusted)
    }

    /// 第一次 capture 得到 A 后把 Mock 换成 B：derive 仍用传入的 A，且不再 capture。
    func testDeriveUsesPassedSnapshotWhenMockWouldReturnB() {
        let first = makeSnapshot(percent: 64, watts: 9.5, charging: true)
        let second = makeSnapshot(percent: 63, watts: -22.0, charging: false)
        let provider = CountingMockBatteryProvider(snapshot: first)

        let captured = provider.capture()
        provider.mock.snapshot = second

        let tick = SnapshotTick.derive(
            snapshot: captured,
            now: captured.capturedAt,
            heartbeatInterval: 2
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(tick.snapshot.percent, 64)
        XCTAssertEqual(tick.snapshot.watts, 9.5)
        XCTAssertEqual(tick.metrics.batteryPercent.value, 64)
        XCTAssertEqual(tick.metrics.batteryNetPowerWatts.value, 9.5)
        XCTAssertEqual(tick.flow.direction, .charging)
        XCTAssertNotEqual(tick.metrics.batteryNetPowerWatts.value, -22.0)
        XCTAssertNotEqual(tick.flow.direction, EnergyFlow.classify(second).direction)
        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(EnergyFlow.classify(second).direction, .discharging)
    }

    /// `assemble(snapshot:)` 不得把电池瓦数填进适配器瓦数；Tick 也不读 IOKit。
    func testAssembleOnceDoesNotCopyBatteryWattsToAdapter() {
        let snapshot = makeSnapshot(percent: 55, watts: 21.5, charging: true)
        let provider = CountingMockBatteryProvider(snapshot: snapshot)
        let captured = provider.capture()

        let tick = SnapshotTick.derive(
            snapshot: captured,
            now: captured.capturedAt,
            heartbeatInterval: 2
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(tick.metrics.batteryNetPowerWatts.value, 21.5)
        XCTAssertNil(tick.metrics.adapterOutputWatts.value)
        XCTAssertNil(tick.metrics.adapterRatedMaxWatts.value)
        XCTAssertNil(tick.metrics.systemPowerWatts.value)
        XCTAssertNotEqual(tick.metrics.adapterRatedMaxWatts.value, tick.metrics.batteryNetPowerWatts.value)
    }

    /// `now - capturedAt > heartbeatInterval` 时信任度为过期。
    func testTrustStaleWhenNowExceedsHeartbeatInterval() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = makeSnapshot(
            percent: 80,
            watts: 0,
            charging: false,
            capturedAt: capturedAt
        )
        let provider = CountingMockBatteryProvider(snapshot: snapshot)
        let captured = provider.capture()
        let now = capturedAt.addingTimeInterval(SamplingPolicy.heartbeatSeconds + 0.01)

        let tick = SnapshotTick.derive(
            snapshot: captured,
            now: now,
            heartbeatInterval: SamplingPolicy.heartbeatSeconds
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(tick.trust, .stale)
        XCTAssertEqual(tick.flow.direction, .idle)
    }

    /// 建议回看窗口为 1 小时，不是 30 天。
    func testAdviceLookbackIsOneHourNotThirtyDays() {
        XCTAssertEqual(SnapshotTick.adviceLookbackRange, HistoryRange.hours1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = SnapshotTick.adviceLookbackRange.window(now: now)
        XCTAssertEqual(window.end.timeIntervalSince(window.start), 3_600, accuracy: 0.5)
        let month = HistoryRange.days30.window(now: now)
        XCTAssertGreaterThan(month.end.timeIntervalSince(month.start), 20 * 86_400)
    }

    /// 捕获失败快照派生为不可用，且仍不调用 capture。
    func testUnavailableSnapshotDoesNotCapture() {
        let provider = CountingMockBatteryProvider(snapshot: .empty)
        let captured = provider.capture()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let tick = SnapshotTick.derive(
            snapshot: captured,
            now: now,
            heartbeatInterval: 2
        )

        XCTAssertEqual(provider.captureCount, 1)
        XCTAssertEqual(tick.trust, .unavailable)
        XCTAssertEqual(tick.flow.direction, .unknown)
        XCTAssertNil(tick.metrics.batteryNetPowerWatts.value)
    }

    func testMetricsAndFlowUsesThePassedSnapshot() {
        let snapshot = makeSnapshot(percent: 70, watts: 8.0, charging: true)
        let pair = metricsAndFlow(from: snapshot)
        XCTAssertEqual(pair.metrics.batteryNetPowerWatts.value, 8.0)
        XCTAssertEqual(pair.flow.direction, .charging)
        XCTAssertEqual(pair.metrics, PowerMetrics.assemble(snapshot: snapshot))
    }

    private func makeSnapshot(
        percent: Int,
        watts: Double,
        charging: Bool,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> BatterySnapshot {
        BatterySnapshot(
            percent: percent,
            drawingFrom: charging ? "电源适配器" : "电池供电",
            isCharging: charging,
            externalConnected: charging,
            watts: watts,
            summary: "测试",
            capturedAt: capturedAt,
            isAvailable: true,
            wattsIsAvailable: true
        )
    }
}

/// 带计数器的 `MockBatteryProvider` 包装：证明 Tick 不会二次 capture。
private final class CountingMockBatteryProvider: BatteryProviding, @unchecked Sendable {
    var mock: MockBatteryProvider
    private(set) var captureCount = 0

    init(snapshot: BatterySnapshot) {
        mock = MockBatteryProvider(snapshot: snapshot)
    }

    func capture() -> BatterySnapshot {
        captureCount += 1
        return mock.capture()
    }
}

import BattCycleCore
import XCTest

final class EnergyEstimatesTests: XCTestCase {
    func testResultsAreAlwaysLabeledEstimates() {
        let estimate = EnergyEstimates.estimate(
            samples: consecutive(watts: [10, 10], interval: 10),
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertEqual(EnergyEstimates.estimateLabel, "估算")
    }

    func testTrapezoidIntegratesSignedWatts() {
        let samples = consecutive(watts: [10, 30], interval: 10)
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        let expected = (10.0 + 30.0) / 2.0 * (10.0 / 3600.0)
        XCTAssertEqual(estimate.energyInWh, expected, accuracy: 1e-9)
        XCTAssertEqual(estimate.energyOutWh, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.netWh, expected, accuracy: 1e-9)
        XCTAssertEqual(estimate.peakInW, 30)
        XCTAssertNil(estimate.peakOutW)
    }

    func testDischargeEnergyUsesAbsoluteTrapezoid() throws {
        let samples = consecutive(watts: [-8, -12], interval: 10)
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        let expected = (8.0 + 12.0) / 2.0 * (10.0 / 3600.0)
        XCTAssertEqual(estimate.energyOutWh, expected, accuracy: 1e-9)
        XCTAssertEqual(estimate.energyInWh, 0, accuracy: 1e-9)
        XCTAssertEqual(estimate.netWh, -expected, accuracy: 1e-9)
        XCTAssertEqual(estimate.peakOutW, 12)
        XCTAssertEqual(try XCTUnwrap(estimate.meanDischargeW), 10, accuracy: 1e-9)
    }

    func testZeroWattsIsIntegratedWhileMissingIsNotTreatedAsZero() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let zero = HistorySample(at: t0, watts: 0)
        let missing = HistorySample(at: t0.addingTimeInterval(10), watts: nil)
        let recovered = HistorySample(at: t0.addingTimeInterval(20), watts: 10)
        let withMissing = EnergyEstimates.estimate(
            samples: [zero, missing, recovered],
            from: t0,
            to: t0.addingTimeInterval(20),
            intervalSeconds: 10
        )
        XCTAssertEqual(withMissing.energyInWh, 0, accuracy: 1e-12)
        XCTAssertEqual(withMissing.energyOutWh, 0, accuracy: 1e-12)

        let asZero = HistorySample(at: t0.addingTimeInterval(10), watts: 0)
        let withZero = EnergyEstimates.estimate(
            samples: [zero, asZero, recovered],
            from: t0,
            to: t0.addingTimeInterval(20),
            intervalSeconds: 10
        )
        let expected = (0.0 + 10.0) / 2.0 * (10.0 / 3600.0)
        XCTAssertEqual(withZero.energyInWh, expected, accuracy: 1e-9)
    }

    func testLargeGapIsNotIntegrated() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(at: t0, watts: 20),
            HistorySample(at: t0.addingTimeInterval(3_600), watts: 20)
        ]
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: t0,
            to: t0.addingTimeInterval(3_600),
            intervalSeconds: 10
        )
        XCTAssertEqual(estimate.energyInWh, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.netWh, 0, accuracy: 1e-12)
        XCTAssertLessThan(estimate.completeness, 0.01)
    }

    func testUnavailableWattsSkipTheInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let available = HistorySample(at: t0, watts: 12)
        var unavailable = HistorySample(at: t0.addingTimeInterval(10), watts: 12)
        unavailable.wattsAvailable = false
        unavailable.watts = nil
        let estimate = EnergyEstimates.estimate(
            samples: [available, unavailable],
            from: t0,
            to: t0.addingTimeInterval(10),
            intervalSeconds: 10
        )
        XCTAssertEqual(estimate.energyInWh, 0, accuracy: 1e-12)
    }

    func testAdapterDurationsDoNotGuessUnknownFlags() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let unknown = [
            HistorySample(at: t0, watts: 5),
            HistorySample(at: t0.addingTimeInterval(10), watts: 5)
        ]
        let guessed = EnergyEstimates.estimate(
            samples: unknown,
            from: t0,
            to: t0.addingTimeInterval(10),
            intervalSeconds: 10
        )
        XCTAssertNil(guessed.durationUsingAdapter)
        XCTAssertNil(guessed.durationOnBattery)

        let known = [
            HistorySample(at: t0, watts: 5, pluggedIn: true, useAdapter: true),
            HistorySample(at: t0.addingTimeInterval(10), watts: 5, pluggedIn: true, useAdapter: true),
            HistorySample(at: t0.addingTimeInterval(20), watts: -5, pluggedIn: false, useAdapter: false),
            HistorySample(at: t0.addingTimeInterval(30), watts: -5, pluggedIn: false, useAdapter: false)
        ]
        let durations = EnergyEstimates.estimate(
            samples: known,
            from: t0,
            to: t0.addingTimeInterval(30),
            intervalSeconds: 10
        )
        XCTAssertEqual(try XCTUnwrap(durations.durationUsingAdapter), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(durations.durationOnBattery), 10, accuracy: 1e-9)
    }

    func testCompletenessUsesExpectedSamplesForTheRange() {
        let samples = consecutive(watts: Array(repeating: 1, count: 6), interval: 10)
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_100),
            intervalSeconds: 10
        )
        XCTAssertEqual(estimate.completeness, 0.6, accuracy: 1e-9)
    }

    /// 0 条样本：数据不足，completeness 为 0，不得崩溃。
    func testZeroSamplesAreInsufficientData() {
        let start = Date(timeIntervalSince1970: 1_000)
        let estimate = EnergyEstimates.estimate(
            samples: [],
            from: start,
            to: start.addingTimeInterval(60),
            intervalSeconds: 10
        )
        assertInsufficientData(estimate)
    }

    /// 1 条样本：数据不足，completeness 为 0，不用单点编造能量。
    func testOneSampleIsInsufficientData() {
        let start = Date(timeIntervalSince1970: 1_000)
        let estimate = EnergyEstimates.estimate(
            samples: [HistorySample(at: start, watts: 25)],
            from: start,
            to: start.addingTimeInterval(10),
            intervalSeconds: 10
        )
        assertInsufficientData(estimate)
    }

    /// 清空后的空数组与 0 条样本相同，视为数据不足。
    func testEmptyAfterClearIsInsufficientData() {
        var samples = consecutive(watts: [12, 18, 8], interval: 10)
        samples.removeAll()
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_020),
            intervalSeconds: 10
        )
        assertInsufficientData(estimate)
    }

    /// sleepGap == true 无条件切段，不跨间隙积分；其后新段可继续积分。
    func testSleepGapUnconditionallyBreaksIntegrationThenStartsNewSegment() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let beforeSleep = HistorySample(at: t0, watts: 20, intervalSeconds: 10)
        var afterSleep = HistorySample(at: t0.addingTimeInterval(10), watts: 20, intervalSeconds: 10)
        afterSleep.sleepGap = true
        let next = HistorySample(at: t0.addingTimeInterval(20), watts: 20, intervalSeconds: 10)

        let broken = EnergyEstimates.estimate(
            samples: [beforeSleep, afterSleep],
            from: t0,
            to: t0.addingTimeInterval(10),
            intervalSeconds: 10
        )
        XCTAssertEqual(broken.energyInWh, 0, accuracy: 1e-12)
        XCTAssertEqual(broken.energyOutWh, 0, accuracy: 1e-12)
        XCTAssertEqual(broken.netWh, 0, accuracy: 1e-12)

        let resumed = EnergyEstimates.estimate(
            samples: [beforeSleep, afterSleep, next],
            from: t0,
            to: t0.addingTimeInterval(20),
            intervalSeconds: 10
        )
        let expected = 20.0 * (10.0 / 3600.0)
        XCTAssertEqual(resumed.energyInWh, expected, accuracy: 1e-9)
        XCTAssertEqual(resumed.energyOutWh, 0, accuracy: 1e-12)
    }

    /// 样本上的 intervalSeconds 优先于当前传入间隔，避免改 UI 间隔重解释旧样本。
    func testRecordedSampleIntervalIsPreferredOverPassedInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let recorded = [
            HistorySample(at: t0, watts: 10, intervalSeconds: 10),
            HistorySample(at: t0.addingTimeInterval(20), watts: 10, intervalSeconds: 10)
        ]
        let keepOldSpacing = EnergyEstimates.estimate(
            samples: recorded,
            from: t0,
            to: t0.addingTimeInterval(20),
            intervalSeconds: 5
        )
        XCTAssertEqual(keepOldSpacing.energyInWh, 10.0 * (20.0 / 3600.0), accuracy: 1e-9)

        let wide = [
            HistorySample(at: t0, watts: 10, intervalSeconds: 10),
            HistorySample(at: t0.addingTimeInterval(100), watts: 10, intervalSeconds: 10)
        ]
        let ignoreNewerUIInterval = EnergyEstimates.estimate(
            samples: wide,
            from: t0,
            to: t0.addingTimeInterval(100),
            intervalSeconds: 60
        )
        XCTAssertEqual(ignoreNewerUIInterval.energyInWh, 0, accuracy: 1e-12)
        XCTAssertEqual(ignoreNewerUIInterval.netWh, 0, accuracy: 1e-12)
    }

    /// +10→-10：在过零点拆分，正负能量分别积分。
    func testZeroCrossingPositiveToNegativeSplitsEnergy() {
        assertZeroCrossing(
            from: 10,
            to: -10,
            expectedIn: 5.0 * (5.0 / 3600.0),
            expectedOut: 5.0 * (5.0 / 3600.0)
        )
    }

    /// -10→+10：在过零点拆分，正负能量分别积分。
    func testZeroCrossingNegativeToPositiveSplitsEnergy() {
        assertZeroCrossing(
            from: -10,
            to: 10,
            expectedIn: 5.0 * (5.0 / 3600.0),
            expectedOut: 5.0 * (5.0 / 3600.0)
        )
    }

    /// +30→-10：过零点在 75% 处，正负面积不相等。
    func testZeroCrossingAsymmetricPositiveToNegativeSplitsEnergy() {
        assertZeroCrossing(
            from: 30,
            to: -10,
            expectedIn: 15.0 * (7.5 / 3600.0),
            expectedOut: 5.0 * (2.5 / 3600.0)
        )
    }

    private func consecutive(watts: [Double], interval: TimeInterval) -> [HistorySample] {
        watts.enumerated().map { index, value in
            HistorySample(
                at: Date(timeIntervalSince1970: 1_000 + TimeInterval(index) * interval),
                watts: value
            )
        }
    }

    private func assertInsufficientData(_ estimate: EnergyEstimates) {
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertEqual(estimate.energyInWh, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.energyOutWh, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.netWh, 0, accuracy: 1e-12)
        XCTAssertNil(estimate.meanChargeW)
        XCTAssertNil(estimate.meanDischargeW)
        XCTAssertNil(estimate.peakInW)
        XCTAssertNil(estimate.peakOutW)
        XCTAssertEqual(estimate.completeness, 0, accuracy: 1e-12)
    }

    private func assertZeroCrossing(
        from w0: Double,
        to w1: Double,
        expectedIn: Double,
        expectedOut: Double
    ) {
        let samples = consecutive(watts: [w0, w1], interval: 10)
        let estimate = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        XCTAssertEqual(estimate.energyInWh, expectedIn, accuracy: 1e-9)
        XCTAssertEqual(estimate.energyOutWh, expectedOut, accuracy: 1e-9)
        XCTAssertEqual(estimate.netWh, expectedIn - expectedOut, accuracy: 1e-9)
    }
}

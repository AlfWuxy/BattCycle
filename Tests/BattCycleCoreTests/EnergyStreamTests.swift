import BattCycleCore
import XCTest

final class EnergyStreamTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testStreamingPreservesCrossingsGapsIntervalsAndUnknownAdapterDurations() throws {
        let samples = [
            sample(0, 30, using: true),
            sample(10, -10, using: true),
            sample(20, nil),
            sample(30, -20, using: false),
            sample(40, -20, using: false, gap: true),
            sample(60, -20, using: false),
            sample(160, 10, using: nil),
            sample(170, 10, using: nil),
        ]
        let result = try stream(samples, end: 170, interval: 5)
        XCTAssertEqual(result.energyInWh, (112.5 + 100) / 3600, accuracy: 1e-10)
        XCTAssertEqual(result.energyOutWh, (12.5 + 400) / 3600, accuracy: 1e-10)
        XCTAssertEqual(result.durationUsingAdapter, 10)
        XCTAssertEqual(result.durationOnBattery, 20)
        XCTAssertEqual(result.peakInW, 30)
        XCTAssertEqual(result.peakOutW, 20)
        XCTAssertEqual(result, EnergyEstimates.estimate(
            samples: Array(samples.reversed()), from: start, to: start.addingTimeInterval(170), intervalSeconds: 5
        ))
    }

    func testZeroAndOneStreamedSamplesRemainInsufficient() throws {
        for samples in [[], [sample(0, 25)]] {
            let result = try stream(samples, end: 10)
            XCTAssertEqual(result.energyInWh, 0)
            XCTAssertEqual(result.energyOutWh, 0)
            XCTAssertNil(result.meanChargeW)
            XCTAssertNil(result.peakInW)
            XCTAssertNil(result.durationUsingAdapter)
            XCTAssertEqual(result.completeness, 0)
        }
    }

    func testActualZeroWattsAndMissingWattsStayDistinct() throws {
        let zero = try stream([sample(0, 0), sample(10, 10)], end: 10)
        let missing = try stream([sample(0, nil), sample(10, 10)], end: 10)
        XCTAssertEqual(zero.energyInWh, 50 / 3600, accuracy: 1e-12)
        XCTAssertEqual(missing.energyInWh, 0)
    }

    func testNonfiniteWattsBreakIntegrationWithoutContaminatingTotals() throws {
        let result = try stream([sample(0, 10), sample(10, .infinity), sample(20, .nan), sample(30, 10)], end: 30)
        XCTAssertEqual(result.energyInWh, 0)
        XCTAssertEqual(result.peakInW, 10)
        XCTAssertEqual(result.meanChargeW, 10)
    }

    func testReverseTimestampThrowsInsteadOfIntegratingOverlappingIntervals() {
        XCTAssertThrowsError(try stream([sample(0, 10), sample(20, 10), sample(10, 10), sample(30, 10)], end: 30)) { error in
            XCTAssertEqual(error as? EnergyEstimationError, .outOfOrder(previousEpoch: 1_020, currentEpoch: 1_010))
        }
    }

    func testDuplicateTimestampHasNoAreaAndArrayStillAcceptsUnorderedInput() throws {
        let ordered = [sample(0, 10), sample(10, 10), sample(10, 30), sample(20, 30)]
        let result = try stream(ordered, end: 20)
        XCTAssertEqual(result.energyInWh, 400 / 3600, accuracy: 1e-12)
        let unordered = [sample(20, 30), sample(0, 10), sample(10, 20)]
        XCTAssertEqual(EnergyEstimates.estimate(samples: unordered, from: start, to: start.addingTimeInterval(20), intervalSeconds: 10).energyInWh, 400 / 3600, accuracy: 1e-12)
    }

    func testReadFailureCannotReturnPartialWindowAsCompleteEstimate() {
        enum ReadError: Error { case failed }
        XCTAssertThrowsError(try EnergyEstimates.estimateStream(from: start, to: start.addingTimeInterval(30), intervalSeconds: 10) { consume in
            try consume(sample(0, 10))
            try consume(sample(10, 10))
            throw ReadError.failed
        }) { XCTAssertTrue($0 is ReadError) }
    }

    func testRawHistoryEnergyRetainsASpikeBeyondChartPointBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BattCycle-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = HistoryStore(directory: directory, calendar: calendar)
        let file = directory.appendingPathComponent("samples-1970-01-01.jsonl")
        var contents = Data()
        let encoder = JSONEncoder()
        for index in 0...5_000 {
            var value = sample(TimeInterval(index), index == 1_501 ? 100 : 0)
            value.intervalSeconds = 1
            contents.append(try encoder.encode(value))
            contents.append(0x0A)
        }
        try contents.write(to: file)
        let range = HistoryRange.custom(from: start, to: start.addingTimeInterval(5_000))
        let chart = try HistoryQuery.load(store: store, range: range, intervalSeconds: 1)
        XCTAssertLessThanOrEqual(chart.samples.count, 1_500)
        let result = try EnergyEstimates.estimateHistory(store: store, range: range, intervalSeconds: 1)
        XCTAssertEqual(result.energyInWh, 100 / 3600, accuracy: 1e-12)
        XCTAssertEqual(result.peakInW, 100)
        XCTAssertEqual(result.completeness, 1)
    }

    private func sample(_ seconds: TimeInterval, _ watts: Double?, using: Bool? = nil, gap: Bool = false) -> HistorySample {
        HistorySample(at: start.addingTimeInterval(seconds), watts: watts, useAdapter: using, sleepGap: gap, intervalSeconds: 10)
    }

    private func stream(_ samples: [HistorySample], end: TimeInterval, interval: Int = 10) throws -> EnergyEstimates {
        try EnergyEstimates.estimateStream(from: start, to: start.addingTimeInterval(end), intervalSeconds: interval) { consume in
            for sample in samples { try consume(sample) }
        }
    }
}

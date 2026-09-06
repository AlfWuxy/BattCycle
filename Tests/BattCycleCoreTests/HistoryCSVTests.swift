import BattCycleCore
import XCTest

final class HistoryCSVTests: XCTestCase {
    func testSampleCSVHasHeaderWithUnitsAndEmptyMissingWatts() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let present = HistorySample(at: t0, percent: 80, watts: 0, direction: "idle")
        let missing = HistorySample(at: t0.addingTimeInterval(10), percent: nil, watts: nil, direction: "unknown")
        let csv = HistoryCSV.export(samples: [present, missing])
        let lines = csv.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("epoch (s)"))
        XCTAssertTrue(lines[0].contains("watts (W)"))
        XCTAssertTrue(lines[0].contains("percent (%)"))

        let zeroRow = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let missingRow = lines[2].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let wattsIndex = try XCTUnwrap(lines[0].split(separator: ",").firstIndex(where: { $0.contains("watts (W)") }))
        XCTAssertEqual(zeroRow[wattsIndex], "0")
        XCTAssertEqual(missingRow[wattsIndex], "")
        XCTAssertFalse(csv.contains("估算"))
    }

    func testEnergySummaryIncludesEstimateColumn() throws {
        let samples = [
            HistorySample(at: Date(timeIntervalSince1970: 1_000), watts: 10),
            HistorySample(at: Date(timeIntervalSince1970: 1_010), watts: 10)
        ]
        let energy = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        let csv = HistoryCSV.export(samples: samples, energy: energy)
        XCTAssertTrue(csv.contains("估算"))
        XCTAssertTrue(csv.contains("energyInWh"))
        XCTAssertTrue(csv.contains("Wh"))
        let sampleHeader = csv.split(whereSeparator: \.isNewline).map(String.init).first { $0.hasPrefix("epoch") }
        XCTAssertNotNil(sampleHeader)
        XCTAssertTrue(try XCTUnwrap(sampleHeader).contains("watts (W)"))
    }

    func testStreamingExportToTempFileMatchesInMemory() throws {
        let samples = [
            HistorySample(at: Date(timeIntervalSince1970: 1_700_000_000), percent: 80, watts: 0, direction: "idle"),
            HistorySample(at: Date(timeIntervalSince1970: 1_700_000_010), percent: nil, watts: nil, direction: "unknown")
        ]
        let energy = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_010),
            intervalSeconds: 10
        )
        let expected = HistoryCSV.export(samples: samples, energy: energy)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try HistoryCSV.export(to: url, samples: samples, energy: energy)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, expected)
        XCTAssertTrue(written.contains("估算"))
        XCTAssertTrue(written.contains("energyInWh"))
    }

    func testSequenceExportMatchesArrayExport() throws {
        let samples = [
            HistorySample(at: Date(timeIntervalSince1970: 1_700_000_000), percent: 80, watts: 0, direction: "idle"),
            HistorySample(at: Date(timeIntervalSince1970: 1_700_000_010), percent: nil, watts: nil, direction: "unknown")
        ]
        let energy = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_700_000_000),
            to: Date(timeIntervalSince1970: 1_700_000_010),
            intervalSeconds: 10
        )
        let expected = HistoryCSV.export(samples: samples, energy: energy)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-seq-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try HistoryCSV.export(to: url, samples: AnySequence(samples), energy: energy)

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, expected)
        XCTAssertTrue(written.contains("估算"))
    }

    func testProducerExportDoesNotRequireCollectedRows() throws {
        let samples = [
            HistorySample(at: Date(timeIntervalSince1970: 1_000), watts: 10),
            HistorySample(at: Date(timeIntervalSince1970: 1_010), watts: 12)
        ]
        let energy = EnergyEstimates.estimate(
            samples: samples,
            from: Date(timeIntervalSince1970: 1_000),
            to: Date(timeIntervalSince1970: 1_010),
            intervalSeconds: 10
        )
        let expected = HistoryCSV.export(samples: samples, energy: energy)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-producer-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try HistoryCSV.export(to: url, energy: energy) { writeSample in
            for sample in samples {
                try writeSample(sample)
            }
        }

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, expected)
        XCTAssertTrue(written.contains("估算"))
        XCTAssertTrue(written.contains("energyInWh"))
    }

    func testEmptyProducerExportIsSafe() throws {
        let expected = HistoryCSV.export(samples: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-producer-empty-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try "STALE-OVERWRITE-MARKER".write(to: url, atomically: true, encoding: .utf8)

        try HistoryCSV.export(to: url) { _ in }

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, expected)
        XCTAssertFalse(written.contains("STALE-OVERWRITE-MARKER"))
        XCTAssertTrue(written.contains("epoch (s)"))
        XCTAssertFalse(written.contains("估算"))
    }

    func testProducerExportFromQueryForEachSample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = HistoryStore(directory: directory, calendar: calendar)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            HistorySample(at: t0.addingTimeInterval(-60), watts: 4),
            HistorySample(at: t0, watts: 6)
        ]
        for sample in samples {
            switch store.append(sample) {
            case .written:
                break
            case .skippedPaused:
                XCTFail("append skipped because recording is paused")
            case .failed(let error):
                XCTFail("append failed: \(error)")
            }
        }

        var streamed: [HistorySample] = []
        try HistoryQuery.forEachSample(
            store: store,
            from: t0.addingTimeInterval(-90),
            to: t0
        ) { sample in
            streamed.append(sample)
        }
        XCTAssertEqual(streamed.map(\.watts), [4, 6])

        let energy = EnergyEstimates.estimate(
            samples: streamed,
            from: t0.addingTimeInterval(-90),
            to: t0,
            intervalSeconds: 60
        )
        let expected = HistoryCSV.export(samples: streamed, energy: energy)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-foreach-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        try HistoryCSV.export(to: url, energy: energy) { writeSample in
            try HistoryQuery.forEachSample(
                store: store,
                from: t0.addingTimeInterval(-90),
                to: t0
            ) { sample in
                try writeSample(sample)
            }
        }

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, expected)
        XCTAssertTrue(written.contains("估算"))
    }

    func testEmptySamplesExportIsSafe() throws {
        let inMemory = HistoryCSV.export(samples: [])
        XCTAssertTrue(inMemory.contains("epoch (s)"))
        XCTAssertTrue(inMemory.hasSuffix("\n"))
        XCTAssertFalse(inMemory.contains("估算"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "battcycle-csv-empty-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try "STALE-OVERWRITE-MARKER".write(to: url, atomically: true, encoding: .utf8)

        try HistoryCSV.export(to: url, samples: [])

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, inMemory)
        XCTAssertFalse(written.contains("STALE-OVERWRITE-MARKER"))
        XCTAssertFalse(written.isEmpty)
    }
}

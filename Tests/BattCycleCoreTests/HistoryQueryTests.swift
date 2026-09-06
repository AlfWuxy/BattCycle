import BattCycleCore
import XCTest

final class HistoryQueryTests: XCTestCase {
    func testNamedRangesUseFixedWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(HistoryRange.minutes15.window(now: now).start, now.addingTimeInterval(-15 * 60))
        XCTAssertEqual(HistoryRange.hours1.window(now: now).start, now.addingTimeInterval(-3_600))
        XCTAssertEqual(HistoryRange.hours6.window(now: now).start, now.addingTimeInterval(-6 * 3_600))
        XCTAssertEqual(HistoryRange.hours24.window(now: now).start, now.addingTimeInterval(-24 * 3_600))
        XCTAssertEqual(HistoryRange.days7.window(now: now).start, now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(HistoryRange.days30.window(now: now).start, now.addingTimeInterval(-30 * 86_400))
        let custom = HistoryRange.custom(from: now.addingTimeInterval(-90), to: now)
        XCTAssertEqual(custom.window(now: now).start, now.addingTimeInterval(-90))
        XCTAssertEqual(custom.window(now: now).end, now)
    }

    func testGapMarkerUsesNilWattsAndDoesNotInterpolate() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(at: t0, watts: 10),
            HistorySample(at: t0.addingTimeInterval(20), watts: 10),
            HistorySample(at: t0.addingTimeInterval(80), watts: 40)
        ]
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 10)
        let watts = points.map(\.watts)
        XCTAssertEqual(watts.first, 10)
        XCTAssertEqual(watts.last, 40)
        XCTAssertTrue(points.contains(where: { $0.isGap && $0.watts == nil }))
        XCTAssertFalse(points.contains(where: { $0.isGap && $0.watts == 0 }))
        XCTAssertFalse(points.contains(where: { $0.watts == 25 }))
    }

    func testSmallDeltaDoesNotInsertGap() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(at: t0, watts: 4),
            HistorySample(at: t0.addingTimeInterval(20), watts: 6)
        ]
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 10)
        XCTAssertEqual(points.count, 2)
        XCTAssertFalse(points.contains(where: \.isGap))
        XCTAssertEqual(points.map(\.watts), [4, 6])
    }

    func testSleepOmissionAppearsAsDtGap() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let samples = [
            HistorySample(at: t0, watts: -9),
            HistorySample(at: t0.addingTimeInterval(3_600), watts: -9)
        ]
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 10)
        XCTAssertEqual(points.filter(\.isGap).count, 1)
        XCTAssertNil(points.first(where: \.isGap)?.watts)
    }

    func testSleepGapBreaksUnconditionallyIndependentOfQueryInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // dt=20，按 10 秒间隔阈值 25 本不应切段；sleepGap 必须仍打断。
        let samples = [
            HistorySample(at: t0, watts: 8, intervalSeconds: 10),
            HistorySample(at: t0.addingTimeInterval(20), watts: 9, sleepGap: true, intervalSeconds: 10)
        ]
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 60)
        XCTAssertTrue(points.contains(where: { $0.isGap && $0.watts == nil }))
        XCTAssertEqual(points.first?.watts, 8)
        XCTAssertEqual(points.last?.watts, 9)
        XCTAssertFalse(points.contains(where: { $0.isGap && $0.watts == 0 }))
    }

    func testGapUsesSampleIntervalNotCurrentQueryInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // 样本写入间隔 10s → 阈值 25；dt=30 应切段。当前 UI 间隔 60s 阈值 150，不得掩盖切段。
        let samples = [
            HistorySample(at: t0, watts: 5, intervalSeconds: 10),
            HistorySample(at: t0.addingTimeInterval(30), watts: 7, intervalSeconds: 10)
        ]
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 60)
        XCTAssertEqual(points.filter(\.isGap).count, 1)
        XCTAssertNil(points.first(where: \.isGap)?.watts)
        XCTAssertEqual(points.first?.watts, 5)
        XCTAssertEqual(points.last?.watts, 7)
    }

    func testDownsampleCapsHundredThousandPoints() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples: [HistorySample] = (0..<100_000).map { index in
            HistorySample(
                at: start.addingTimeInterval(TimeInterval(index) * 2),
                watts: Double(index % 40)
            )
        }
        let points = HistoryQuery.chartPoints(from: samples, intervalSeconds: 2, maxPoints: 1_500)
        XCTAssertLessThanOrEqual(points.count, 1_500)
        XCTAssertGreaterThan(points.count, 100)
        XCTAssertEqual(points.first?.epoch, samples.first?.epoch)
        XCTAssertEqual(points.last?.epoch, samples.last?.epoch)
        XCTAssertFalse(points.contains(where: \.isGap))
    }

    func testLoadFromStoreRespectsCustomRange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = HistoryStore(directory: directory, calendar: calendar)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        append(store, HistorySample(at: t0.addingTimeInterval(-3_600), watts: 1))
        append(store, HistorySample(at: t0.addingTimeInterval(-60), watts: 2))
        append(store, HistorySample(at: t0, watts: 3))
        let result = try HistoryQuery.load(
            store: store,
            range: .minutes15,
            now: t0,
            intervalSeconds: 60
        )
        XCTAssertEqual(result.samples.map(\.watts), [2, 3])
        XCTAssertEqual(result.chartPoints.map(\.watts), [2, 3])

        let custom = try HistoryQuery.load(
            store: store,
            range: .custom(from: t0.addingTimeInterval(-90), to: t0),
            now: t0,
            intervalSeconds: 60
        )
        XCTAssertEqual(custom.samples.map(\.watts), [2, 3])
        XCTAssertEqual(custom.chartPoints.map(\.watts), [2, 3])
        XCTAssertEqual(HistoryQueryResult.empty.samples, [])
        XCTAssertEqual(HistoryQueryResult.empty.chartPoints, [])
    }

    func testLoadDownsamplesHundredThousandTempFilesToDefaultMaxPoints() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let count = 100_000
        let step: TimeInterval = 0.5
        var payload = Data()
        payload.reserveCapacity(count * 140)
        for index in 0..<count {
            let epoch = dayStart.timeIntervalSince1970 + Double(index) * step
            payload.append(
                contentsOf: "{\"direction\":\"unknown\",\"epoch\":\(epoch),\"iso8601\":\"2027-01-14T00:00:00Z\",\"recordingPaused\":false,\"watts\":\(index % 40),\"wattsAvailable\":true}\n".utf8
            )
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let fileName = String(format: "samples-%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        try payload.write(to: directory.appendingPathComponent(fileName))

        let outsiderStart = calendar.date(byAdding: .day, value: -2, to: dayStart)!
        let outsiderParts = calendar.dateComponents([.year, .month, .day], from: outsiderStart)
        let outsiderName = String(
            format: "samples-%04d-%02d-%02d.jsonl",
            outsiderParts.year ?? 0,
            outsiderParts.month ?? 0,
            outsiderParts.day ?? 0
        )
        try Data("{\"direction\":\"unknown\",\"epoch\":\(outsiderStart.timeIntervalSince1970),\"iso8601\":\"2027-01-12T00:00:00Z\",\"recordingPaused\":false,\"watts\":999,\"wattsAvailable\":true}\n".utf8)
            .write(to: directory.appendingPathComponent(outsiderName))

        let end = dayStart.addingTimeInterval(Double(count - 1) * step)
        let store = HistoryStore(directory: directory, calendar: calendar)
        let result = try HistoryQuery.load(
            store: store,
            range: .custom(from: dayStart, to: end),
            now: end,
            intervalSeconds: 60,
            maxPoints: HistoryQuery.defaultMaxPoints
        )
        XCTAssertLessThanOrEqual(result.chartPoints.count, HistoryQuery.defaultMaxPoints)
        XCTAssertLessThanOrEqual(result.samples.count, HistoryQuery.defaultMaxPoints)
        XCTAssertGreaterThan(result.chartPoints.count, 100)
        XCTAssertEqual(result.chartPoints.first?.epoch, dayStart.timeIntervalSince1970)
        XCTAssertEqual(result.chartPoints.last?.epoch, end.timeIntervalSince1970)
        XCTAssertFalse(result.chartPoints.contains(where: \.isGap))
        XCTAssertFalse(result.chartPoints.contains(where: { $0.watts == 999 }))
        XCTAssertFalse(result.samples.contains(where: { $0.watts == 999 }))
    }

    func testForEachSampleStreamsFullRangeWithoutDownsample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let count = 2_000
        var payload = Data()
        payload.reserveCapacity(count * 140)
        for index in 0..<count {
            let epoch = start.timeIntervalSince1970 + Double(index)
            payload.append(
                contentsOf: "{\"direction\":\"unknown\",\"epoch\":\(epoch),\"iso8601\":\"2027-01-15T08:00:00Z\",\"recordingPaused\":false,\"watts\":\(index),\"wattsAvailable\":true}\n".utf8
            )
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: start)
        let fileName = String(format: "samples-%04d-%02d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        try payload.write(to: directory.appendingPathComponent(fileName))

        let end = start.addingTimeInterval(TimeInterval(count - 1))
        let store = HistoryStore(directory: directory, calendar: calendar)

        var streamed = 0
        var firstWatts: Double?
        var lastWatts: Double?
        try HistoryQuery.forEachSample(store: store, from: start, to: end) { sample in
            streamed += 1
            if firstWatts == nil {
                firstWatts = sample.watts
            }
            lastWatts = sample.watts
        }
        XCTAssertEqual(streamed, count)
        XCTAssertEqual(firstWatts, 0)
        XCTAssertEqual(lastWatts, Double(count - 1))

        let downsampled = try HistoryQuery.load(
            store: store,
            range: .custom(from: start, to: end),
            now: end,
            intervalSeconds: 1,
            maxPoints: HistoryQuery.defaultMaxPoints
        )
        XCTAssertLessThanOrEqual(downsampled.samples.count, HistoryQuery.defaultMaxPoints)
        XCTAssertLessThan(downsampled.samples.count, streamed)
    }

    func testForEachSampleEmptyRangeIsSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = HistoryStore(directory: directory, calendar: calendar)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var calls = 0
        try HistoryQuery.forEachSample(store: store, from: now, to: now.addingTimeInterval(60)) { _ in
            calls += 1
        }
        XCTAssertEqual(calls, 0)

        try HistoryQuery.forEachSample(
            store: store,
            range: .custom(from: now.addingTimeInterval(90), to: now),
            now: now
        ) { _ in
            calls += 1
        }
        XCTAssertEqual(calls, 0)
    }

    func testForEachSampleRespectsWindowAndInvertedDates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let store = HistoryStore(directory: directory, calendar: calendar)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        append(store, HistorySample(at: t0.addingTimeInterval(-3_600), watts: 1))
        append(store, HistorySample(at: t0.addingTimeInterval(-60), watts: 2))
        append(store, HistorySample(at: t0, watts: 3))

        var watts: [Double] = []
        try HistoryQuery.forEachSample(
            store: store,
            from: t0,
            to: t0.addingTimeInterval(-90)
        ) { sample in
            if let value = sample.watts {
                watts.append(value)
            }
        }
        XCTAssertEqual(watts, [2, 3])

        var ranged: [Double] = []
        try HistoryQuery.forEachSample(
            store: store,
            range: .minutes15,
            now: t0
        ) { sample in
            if let value = sample.watts {
                ranged.append(value)
            }
        }
        XCTAssertEqual(ranged, [2, 3])
    }

    func testNearestPointBinarySearch() {
        XCTAssertNil(HistoryQuery.nearestPoint(in: [], epoch: 10))

        let only = HistoryChartPoint(epoch: 5, iso8601: "t", watts: 1, percent: 2, isGap: false)
        XCTAssertEqual(HistoryQuery.nearestPoint(in: [only], epoch: 100), only)

        let points = [
            HistoryChartPoint(epoch: 0, iso8601: "a", watts: 1, percent: 10, isGap: false),
            HistoryChartPoint(epoch: 10, iso8601: "b", watts: 2, percent: 20, isGap: false),
            HistoryChartPoint(epoch: 20, iso8601: "c", watts: 3, percent: 30, isGap: false)
        ]
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 0)?.iso8601, "a")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 10)?.iso8601, "b")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 20)?.iso8601, "c")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 3)?.iso8601, "a")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 6)?.iso8601, "b")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 14)?.iso8601, "b")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 16)?.iso8601, "c")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: -50)?.iso8601, "a")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: points, epoch: 50)?.iso8601, "c")

        let dense: [HistoryChartPoint] = (0..<1_500).map { index in
            HistoryChartPoint(
                epoch: TimeInterval(index) * 2,
                iso8601: "\(index)",
                watts: Double(index),
                percent: nil,
                isGap: false
            )
        }
        XCTAssertEqual(HistoryQuery.nearestPoint(in: dense, epoch: 100)?.iso8601, "50")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: dense, epoch: 101)?.iso8601, "50")
        XCTAssertEqual(HistoryQuery.nearestPoint(in: dense, epoch: 103)?.iso8601, "51")
    }

    @discardableResult
    private func append(_ store: HistoryStore, _ sample: HistorySample) -> Bool {
        switch store.append(sample) {
        case .written:
            return true
        case .skippedPaused:
            XCTFail("append skipped because recording is paused")
            return false
        case .failed(let error):
            XCTFail("append failed: \(error)")
            return false
        }
    }
}

import BattCycleCore
import Darwin
import XCTest

/// P1.6：在临时目录生成约 100 万条合成 JSONL，测量写入、`HistoryStore.sampleCount`、以及 24h / 30d `HistoryQuery.load`。
///
/// 公开 API 以当前模块为准：`HistoryQuery.load(store:range:now:intervalSeconds:maxPoints:)`。
/// `nearestPoint` 与内部流式下采样已存在，本文件不修改 `HistoryQuery.swift`。
///
/// 写出只用 Swift：`FileHandle` + `String(format:)` + `Data` 缓冲。禁止 `snprintf` / C `fwrite`。
///
/// - `BATTCYCLE_SKIP_PERF=1`：跳过（CI / 快速门禁）。
/// - `BATTCYCLE_PERF_LINES`：覆盖行数（须 ≥ 2）；默认 `1_000_000`。
final class HistoryPerformanceTests: XCTestCase {
    /// 合成样本量：默认 1_000_000；可用环境变量缩小以便本机冒烟。
    private static var lineCount: Int {
        if let raw = ProcessInfo.processInfo.environment["BATTCYCLE_PERF_LINES"],
           let parsed = Int(raw), parsed >= 2 {
            return parsed
        }
        return 1_000_000
    }

    /// 覆盖 31 天，使 30d 窗口接近全量、24h 只打开 1–2 个日文件。
    private static let spanDays = 31
    /// 与 `MonitorSettings` 默认采样间隔一致，仅作查询参数。
    private static let queryIntervalSeconds = 10
    /// 写入样本上的 intervalSeconds，贴近均匀步长（约 2.68s），避免查询把连续点当成间隙。
    private static let sampleIntervalSeconds = 3

    override func setUp() {
        super.setUp()
        // 生成 + 两次全量解码可能较慢；命令行 `swift test` 通常不强制该上限。
        executionTimeAllowance = 900
    }

    /// 每次只生成一条记录；在回调仍进行时采样堆用量，避免只看结束后的释放量。
    /// 不受 BATTCYCLE_SKIP_PERF 影响：百万条标量积分属于快速核心回归，不生成 JSONL。
    func testOneMillionGeneratedSamplesKeepEnergyMemoryBounded() throws {
        let count = 1_000_000
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(TimeInterval(count - 1))
        var sample = HistorySample(
            epoch: start.timeIntervalSince1970, iso8601: "unused-in-energy",
            watts: 24, wattsAvailable: true, direction: "charge",
            pluggedIn: true, useAdapter: true, intervalSeconds: 1
        )
        let before = try XCTUnwrap(MemoryProbe.capture())
        var peakAllocated = before.sizeInUse
        let result = try EnergyEstimates.estimateStream(from: start, to: end, intervalSeconds: 1) { consume in
            for index in 0..<count {
                sample.epoch = start.timeIntervalSince1970 + TimeInterval(index)
                try consume(sample)
                if index.isMultiple(of: 100_000) || index == count - 1 {
                    peakAllocated = max(peakAllocated, try XCTUnwrap(MemoryProbe.capture()).sizeInUse)
                }
            }
        }
        let growth = max(0, peakAllocated - before.sizeInUse)
        XCTAssertLessThan(growth, 8 * 1_048_576, "流式能量积分不应保留百万条样本；堆增长 \(growth) bytes")
        XCTAssertEqual(result.energyInWh, 24 * Double(count - 1) / 3_600, accuracy: 1e-6)
        XCTAssertEqual(result.energyOutWh, 0)
        XCTAssertEqual(result.peakInW, 24)
        XCTAssertEqual(result.durationUsingAdapter, Double(count - 1))
        XCTAssertEqual(result.completeness, 1)
        print("ENERGY STREAM samples=\(count) observedHeapGrowthBytes=\(growth) accumulatorBytes=\(MemoryLayout<EnergyAccumulator>.size)")
    }

    func testLoadOneMillionSyntheticSamplesFor24hAnd30d() throws {
        if ProcessInfo.processInfo.environment["BATTCYCLE_SKIP_PERF"] == "1" {
            throw XCTSkip("BATTCYCLE_SKIP_PERF=1，跳过 100 万行历史性能测试")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BattCycle-perf-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // 固定锚点，避免测试随墙上时钟漂移。
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-TimeInterval(Self.spanDays) * 86_400)
        let expectedLines = Self.lineCount

        let generate = try measure {
            try writeMillionJSONL(
                directory: directory,
                calendar: calendar,
                start: start,
                now: now,
                lineCount: expectedLines
            )
        }
        XCTAssertEqual(generate.value, expectedLines)

        let store = HistoryStore(directory: directory, calendar: calendar)

        // 未写 meta.json：第一次走 rebuild（扫全部 JSONL 行数）；第二次读侧车增量。
        let coldCount = try measure { try store.sampleCount() }
        let warmCount = try measure { try store.sampleCount() }

        let load24h = try measureLoad(
            store: store,
            range: .hours24,
            now: now,
            intervalSeconds: Self.queryIntervalSeconds
        )
        let load30d = try measureLoad(
            store: store,
            range: .days30,
            now: now,
            intervalSeconds: Self.queryIntervalSeconds
        )

        XCTAssertLessThanOrEqual(load24h.result.chartPoints.count, HistoryQuery.defaultMaxPoints)
        XCTAssertLessThanOrEqual(load30d.result.chartPoints.count, HistoryQuery.defaultMaxPoints)
        XCTAssertLessThanOrEqual(load24h.result.chartPoints.count, 1_500)
        XCTAssertLessThanOrEqual(load30d.result.chartPoints.count, 1_500)
        XCTAssertGreaterThan(load24h.result.chartPoints.count, 0)
        XCTAssertGreaterThan(load30d.result.chartPoints.count, 0)
        XCTAssertGreaterThanOrEqual(coldCount.value, expectedLines)
        XCTAssertEqual(warmCount.value, coldCount.value)

        let report = [
            "P1.6 PERF generate elapsed=\(fmt(generate.seconds))s lines=\(generate.value)",
            "P1.6 PERF sampleCount cold elapsed=\(fmt(coldCount.seconds))s count=\(coldCount.value) (无 meta，扫 JSONL 重建)",
            "P1.6 PERF sampleCount warm elapsed=\(fmt(warmCount.seconds))s count=\(warmCount.value) (侧车增量)",
            formatLoad("hours24", load24h),
            formatLoad("days30", load30d)
        ].joined(separator: "\n")
        print(report)
        if let payload = (report + "\n").data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: payload)
        }
        // 把数字挂到断言消息上，便于 `swift test` 失败时仍能看到。
        XCTAssertTrue(true, report)
    }

    // MARK: - 测量

    private struct Timed<T> {
        var value: T
        var seconds: TimeInterval
    }

    private struct LoadMeasurement {
        var result: HistoryQueryResult
        var seconds: TimeInterval
        var memory: String
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> Timed<T> {
        let start = DispatchTime.now()
        let value = try body()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return Timed(value: value, seconds: seconds)
    }

    private func measureLoad(
        store: HistoryStore,
        range: HistoryRange,
        now: Date,
        intervalSeconds: Int
    ) throws -> LoadMeasurement {
        let before = MemoryProbe.capture()
        let timed = try measure {
            try HistoryQuery.load(
                store: store,
                range: range,
                now: now,
                intervalSeconds: intervalSeconds,
                maxPoints: HistoryQuery.defaultMaxPoints
            )
        }
        let after = MemoryProbe.capture()
        return LoadMeasurement(
            result: timed.value,
            seconds: timed.seconds,
            memory: MemoryProbe.describe(before: before, after: after)
        )
    }

    private func formatLoad(_ label: String, _ measured: LoadMeasurement) -> String {
        "P1.6 PERF load \(label) elapsed=\(fmt(measured.seconds))s chartPoints=\(measured.result.chartPoints.count) samples=\(measured.result.samples.count) \(measured.memory)"
    }

    private func fmt(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    // MARK: - 合成 JSONL

    /// 按 UTC 日切分 `samples-YYYY-MM-DD.jsonl`，与 `HistoryStore` / `HistoryQuery` 日文件约定一致。
    /// 预分配 1MB `Data` 缓冲，满了再经 `FileHandle` 写出。
    @discardableResult
    private func writeMillionJSONL(
        directory: URL,
        calendar: Calendar,
        start: Date,
        now: Date,
        lineCount: Int
    ) throws -> Int {
        let startEpoch = start.timeIntervalSince1970
        let endEpoch = now.timeIntervalSince1970
        let step = (endEpoch - startEpoch) / Double(lineCount - 1)
        let dayLength: TimeInterval = 86_400

        var currentDayStart = floor(startEpoch / dayLength) * dayLength
        var nextDayEpoch = currentDayStart + dayLength
        var writer = try JSONLChunkWriter(url: dailyURL(directory: directory, dayStart: currentDayStart, calendar: calendar))
        defer { writer.close() }

        var written = 0
        for index in 0..<lineCount {
            let epoch = startEpoch + Double(index) * step
            if epoch >= nextDayEpoch {
                try writer.finish()
                currentDayStart = floor(epoch / dayLength) * dayLength
                nextDayEpoch = currentDayStart + dayLength
                writer = try JSONLChunkWriter(
                    url: dailyURL(directory: directory, dayStart: currentDayStart, calendar: calendar)
                )
            }
            try writer.writeSample(epoch: epoch, watts: index % 40, intervalSeconds: Self.sampleIntervalSeconds)
            written += 1
        }
        try writer.finish()
        return written
    }

    private func dailyURL(directory: URL, dayStart: TimeInterval, calendar: Calendar) -> URL {
        let date = Date(timeIntervalSince1970: dayStart)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(
            format: "samples-%04d-%02d-%02d.jsonl",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
        return directory.appendingPathComponent(name)
    }
}

/// 预分配 1MB `Data` 缓冲，满了再经 `FileHandle` 写出。行文本用 `String(format:)`，不调用 C `snprintf` / `fwrite`。
private final class JSONLChunkWriter {
    static let chunkBytes = 1_048_576
    /// POSIX 区域，保证 epoch 小数点为 `.`。
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let lineFormat =
        "{\"direction\":\"unknown\",\"epoch\":%.6f,\"intervalSeconds\":%d,\"iso8601\":\"2027-01-15T08:00:00Z\",\"recordingPaused\":false,\"watts\":%d,\"wattsAvailable\":true}\n"

    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false

    init(url: URL) throws {
        let path = url.path
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw HistoryPerformanceError.openFailed(path)
        }
        handle = try FileHandle(forWritingTo: url)
        buffer.reserveCapacity(Self.chunkBytes)
    }

    func writeSample(epoch: TimeInterval, watts: Int, intervalSeconds: Int) throws {
        let line = String(
            format: Self.lineFormat,
            locale: Self.posix,
            epoch,
            intervalSeconds,
            watts
        )
        let utf8 = line.utf8
        if buffer.count + utf8.count > Self.chunkBytes {
            try flush()
        }
        buffer.append(contentsOf: utf8)
    }

    /// 测试路径上的显式收尾：冲刷缓冲并关闭句柄；失败则抛出。
    func finish() throws {
        guard !closed else { return }
        closed = true
        try flush()
        try handle.close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? flush()
        try? handle.close()
    }

    deinit {
        close()
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

private enum HistoryPerformanceError: Error {
    case openFailed(String)
}

/// 进程级 malloc / RSS。`max_size_in_use` 是进程生命周期峰值，不是单次 `load` 的隔离峰值。
private struct MemoryProbe {
    var sizeInUse: Int
    var maxSizeInUse: Int
    var resident: UInt64

    static func capture() -> MemoryProbe? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return MemoryProbe(
            sizeInUse: Int(stats.size_in_use),
            maxSizeInUse: Int(stats.max_size_in_use),
            resident: residentBytes() ?? 0
        )
    }

    static func describe(before: MemoryProbe?, after: MemoryProbe?) -> String {
        guard let before, let after else {
            return "memory=unavailable"
        }
        return "mallocSizeInUse=\(mb(before.sizeInUse))->\(mb(after.sizeInUse)) mallocMax=\(mb(after.maxSizeInUse)) rss=\(mb(Int(before.resident)))->\(mb(Int(after.resident)))"
    }

    private static func mb(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}

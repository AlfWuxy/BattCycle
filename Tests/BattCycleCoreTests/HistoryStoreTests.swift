import BattCycleCore
import XCTest

final class HistoryStoreTests: XCTestCase {
    private var root: URL!
    private var history: URL!
    private var calendar: Calendar!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BattCycle-history-\(UUID().uuidString)", isDirectory: true)
        history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = utc
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testAppendWritesOneJSONLLineWithoutRewriting() throws {
        let store = makeStore()
        let first = sample(at: date("2026-09-02T00:00:00Z"), watts: -12.5)
        let second = sample(at: date("2026-09-02T00:00:10Z"), watts: -13)
        XCTAssertEqual(kind(store.append(first)), .written)
        XCTAssertEqual(kind(store.append(second)), .written)

        let files = try jsonlFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].lastPathComponent, "samples-2026-09-02.jsonl")

        let text = try String(contentsOf: files[0], encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try store.sampleCount(), 2)
        XCTAssertGreaterThan(try store.estimatedBytes(), 0)

        let decoded = try JSONDecoder().decode(HistorySample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(decoded.watts, -12.5)
        XCTAssertTrue(decoded.wattsAvailable)
        XCTAssertNil(decoded.sleepGap)
    }

    func testDailyFilesSplitAcrossUTCDays() throws {
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T23:59:50Z"), watts: 1))), .written)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-03T00:00:10Z"), watts: 2))), .written)
        let names = try jsonlFiles().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["samples-2026-09-02.jsonl", "samples-2026-09-03.jsonl"])
    }

    func testPausedRecordingWritesNothing() throws {
        var settings = MonitorSettings.default
        settings.recordingPaused = true
        let store = makeStore(settings: settings)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 5))), .skippedPaused)
        XCTAssertEqual(try store.sampleCount(), 0)
        XCTAssertEqual(try store.estimatedBytes(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
    }

    func testPauseSkipVersusWrite() throws {
        let store = makeStore()
        let written = store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 5))
        XCTAssertEqual(kind(written), .written)
        XCTAssertEqual(try store.sampleCount(), 1)

        store.settings.recordingPaused = true
        let skipped = store.append(sample(at: date("2026-09-02T00:00:10Z"), watts: 6))
        XCTAssertEqual(kind(skipped), .skippedPaused)
        XCTAssertEqual(try store.sampleCount(), 1)
        XCTAssertEqual(try jsonlFiles().count, 1)

        let bestEffort = store.bestEffortAppend(sample(at: date("2026-09-02T00:00:20Z"), watts: 7))
        XCTAssertEqual(kind(bestEffort), .skippedPaused)
        XCTAssertEqual(try store.sampleCount(), 1)

        store.settings.recordingPaused = false
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:30Z"), watts: 8))), .written)
        XCTAssertEqual(try store.sampleCount(), 2)
    }

    func testPauseCanBeToggledWithoutTouchingSiblingState() throws {
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 5))), .written)
        store.settings.recordingPaused = true
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:10Z"), watts: 6))), .skippedPaused)
        XCTAssertEqual(try store.sampleCount(), 1)
        XCTAssertEqual(kind(store.bestEffortAppend(sample(at: date("2026-09-02T00:00:20Z"), watts: 7))), .skippedPaused)
        XCTAssertEqual(try store.sampleCount(), 1)
    }

    func testPruneDeletesFilesOlderThanRetention() throws {
        var settings = MonitorSettings.default
        settings.retentionDays = 7
        let store = makeStore(settings: settings)
        let now = date("2026-09-02T12:00:00Z")
        XCTAssertEqual(kind(store.append(sample(at: now.addingTimeInterval(-10 * 86_400), watts: 1))), .written)
        XCTAssertEqual(kind(store.append(sample(at: now.addingTimeInterval(-2 * 86_400), watts: 2))), .written)
        try store.prune(now: now)

        let names = try jsonlFiles().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["samples-2026-08-31.jsonl"])
    }

    func testPruneUpdatesMetaSidecar() throws {
        var settings = MonitorSettings.default
        settings.retentionDays = 7
        let store = makeStore(settings: settings)
        let now = date("2026-09-02T12:00:00Z")
        XCTAssertEqual(kind(store.append(sample(at: now.addingTimeInterval(-10 * 86_400), watts: 1))), .written)
        XCTAssertEqual(kind(store.append(sample(at: now.addingTimeInterval(-2 * 86_400), watts: 2))), .written)
        XCTAssertEqual(kind(store.append(sample(at: now.addingTimeInterval(-2 * 86_400 + 10), watts: 3))), .written)

        try store.prune(now: now)

        XCTAssertEqual(try store.sampleCount(), 2)
        let meta = try loadMeta()
        XCTAssertEqual(meta.sampleCount, 2)
        XCTAssertEqual(meta.lineCounts["samples-2026-08-23.jsonl"], nil)
        XCTAssertEqual(meta.lineCounts["samples-2026-08-31.jsonl"], 2)
        XCTAssertEqual(meta.estimatedBytes, try fileBytes(named: "samples-2026-08-31.jsonl"))
        XCTAssertEqual(try store.estimatedBytes(), meta.estimatedBytes)
    }

    func testClearHistoryDeletesOnlyJSONLAndKeepsSupportSiblings() throws {
        let config = root.appendingPathComponent("config.json")
        let lock = root.appendingPathComponent("run.lock")
        let log = root.appendingPathComponent("latest.log")
        let venv = root.appendingPathComponent("venv", isDirectory: true)
        try Data("{\"upperLimit\":80}".utf8).write(to: config)
        try Data("lock".utf8).write(to: lock)
        try Data("log".utf8).write(to: log)
        try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
        try Data("python".utf8).write(to: venv.appendingPathComponent("pyvenv.cfg"))

        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 3))), .written)
        try Data("notes".utf8).write(to: history.appendingPathComponent("readme.txt"))
        try store.clearHistory()

        XCTAssertEqual(try store.sampleCount(), 0)
        XCTAssertEqual(try store.estimatedBytes(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{\"upperLimit\":80}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: venv.appendingPathComponent("pyvenv.cfg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("readme.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path), "clear 只重置 meta，不删 sidecar 文件本身")
        let meta = try loadMeta()
        XCTAssertEqual(meta.sampleCount, 0)
        XCTAssertEqual(meta.estimatedBytes, 0)
        XCTAssertEqual(meta.lineCounts, [:])
    }

    func testClearHistoryDoesNotDeleteSiblingConfigJSON() throws {
        let config = root.appendingPathComponent("config.json")
        try Data("{\"upperLimit\":80}".utf8).write(to: config)
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 3))), .written)
        try store.clearHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{\"upperLimit\":80}")
        XCTAssertEqual(try jsonlFiles().count, 0)
        XCTAssertEqual(try store.sampleCount(), 0)
    }

    func testQueryRangeReadsOnlyMatchingDays() throws {
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-01T23:00:00Z"), watts: 1))), .written)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:10:00Z"), watts: 2))), .written)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:20:00Z"), watts: 3))), .written)
        let loaded = try store.samples(from: date("2026-09-02T00:00:00Z"), to: date("2026-09-02T00:15:00Z"))
        XCTAssertEqual(loaded.map(\.watts), [2])
    }

    func testIncrementalCountMatchesFileLinesAndRebuildsMissingMeta() throws {
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-01T12:00:00Z"), watts: 1))), .written)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T12:00:00Z"), watts: 2))), .written)
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T12:00:10Z"), watts: 3))), .written)

        XCTAssertEqual(try store.sampleCount(), 3)
        let meta = try loadMeta()
        XCTAssertEqual(meta.sampleCount, 3)
        XCTAssertEqual(meta.lineCounts["samples-2026-09-01.jsonl"], 1)
        XCTAssertEqual(meta.lineCounts["samples-2026-09-02.jsonl"], 2)
        XCTAssertEqual(meta.estimatedBytes, try jsonlFiles().reduce(0) { $0 + (try fileBytes(at: $1)) })
        XCTAssertEqual(try store.estimatedBytes(), meta.estimatedBytes)
        XCTAssertEqual(try store.sampleCount(), try countedJSONLLines())

        try FileManager.default.removeItem(at: metaURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
        XCTAssertEqual(try store.sampleCount(), 3)
        XCTAssertEqual(try store.estimatedBytes(), meta.estimatedBytes)
        let rebuilt = try loadMeta()
        XCTAssertEqual(rebuilt.sampleCount, 3)
        XCTAssertEqual(rebuilt.lineCounts["samples-2026-09-01.jsonl"], 1)
        XCTAssertEqual(rebuilt.lineCounts["samples-2026-09-02.jsonl"], 2)
        XCTAssertEqual(rebuilt.estimatedBytes, meta.estimatedBytes)
    }

    func testAppendPersistsOptionalKeysWithoutTouchingEngineConfig() throws {
        let config = root.appendingPathComponent("config.json")
        let original = "{\"cpuJobs\":4,\"gpuSize\":2048,\"lowerLimit\":30,\"pollSeconds\":10,\"stopAtEpoch\":1,\"upperLimit\":80}"
        try Data(original.utf8).write(to: config)

        let store = makeStore()
        let written = HistorySample(
            at: date("2026-09-02T00:00:00Z"),
            percent: 80,
            watts: -8.5,
            direction: EnergyFlowDirection.discharge.rawValue,
            pluggedIn: false,
            useAdapter: false,
            thermal: "nominal",
            enginePhase: "idle",
            sleepGap: true,
            intervalSeconds: 30,
            segmentId: "seg-after-wake"
        )
        XCTAssertEqual(kind(store.append(written)), .written)

        let loaded = try store.samples(from: date("2026-09-02T00:00:00Z"), to: date("2026-09-02T00:00:01Z"))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].intervalSeconds, 30)
        XCTAssertEqual(loaded[0].segmentId, "seg-after-wake")
        XCTAssertEqual(loaded[0].sleepGap, true)

        let files = try jsonlFiles()
        XCTAssertEqual(files.count, 1)
        let rawLine = try String(contentsOf: files[0], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try JSONSerialization.jsonObject(with: Data(rawLine.utf8))
        guard let dictionary = object as? [String: Any] else {
            XCTFail("JSONL 行必须是对象")
            return
        }
        XCTAssertTrue(Set(dictionary.keys).isDisjoint(with: Self.engineConfigKeys), "历史行不得混入引擎 config.json 的六键")

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("config.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
    }

    func testAppendDoesNotCreateEngineConfigWhenAbsent() throws {
        let config = root.appendingPathComponent("config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 4))), .written)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path), "HistoryStore 不得创建引擎 config.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("config.json").path))
    }

    func testAppendReturnsFailedWhenHistoryPathIsSymbolicLink() throws {
        let real = root.appendingPathComponent("real-history", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: history, withDestinationURL: real)
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 1))), .failed)
        // 枚举走符号链接会 ENOTDIR；直接看真实目录，确认没有偷偷落盘。
        let destJSONL = try FileManager.default.contentsOfDirectory(at: real, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
        XCTAssertEqual(destJSONL.count, 0)
    }

    func testAppendReturnsFailedWhenHistoryPathIsRegularFile() throws {
        try Data("not-a-directory".utf8).write(to: history)
        let store = makeStore()
        XCTAssertEqual(kind(store.append(sample(at: date("2026-09-02T00:00:00Z"), watts: 1))), .failed)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), "not-a-directory")
    }

    func testLegacyJSONLWithoutNewKeysDecodesThroughStore() throws {
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let line = "{\"direction\":\"unknown\",\"epoch\":1700000000,\"iso8601\":\"2023-11-14T22:13:20Z\",\"recordingPaused\":false,\"wattsAvailable\":false}\n"
        try Data(line.utf8).write(to: history.appendingPathComponent("samples-2023-11-14.jsonl"))
        let store = makeStore()
        let loaded = try store.samples(from: date("2023-11-14T00:00:00Z"), to: date("2023-11-15T00:00:00Z"))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].intervalSeconds)
        XCTAssertNil(loaded[0].segmentId)
        XCTAssertNil(loaded[0].sleepGap)
        XCTAssertEqual(try store.sampleCount(), 1)
    }

    func testConcurrentAppendAndCountFromMultipleThreads() throws {
        let store = makeStore()
        let box = StoreBox(store)
        let tally = LockedCounter()
        let threadCount = 8
        let perThread = 40

        DispatchQueue.concurrentPerform(iterations: threadCount) { threadIndex in
            for sampleIndex in 0..<perThread {
                let epoch = TimeInterval(threadIndex * perThread + sampleIndex)
                let sample = HistorySample(
                    at: Date(timeIntervalSince1970: 1_000_000 + epoch),
                    percent: 80,
                    watts: Double(sampleIndex),
                    direction: EnergyFlowDirection.discharge.rawValue,
                    pluggedIn: false,
                    useAdapter: false,
                    thermal: "nominal",
                    enginePhase: "idle"
                )
                switch box.store.append(sample) {
                case .written:
                    tally.addWritten()
                case .skippedPaused:
                    break
                case .failed:
                    tally.addFailed()
                }
                if sampleIndex % 7 == 0 {
                    _ = try? box.store.sampleCount()
                    _ = try? box.store.estimatedBytes()
                }
            }
        }

        XCTAssertEqual(tally.failed, 0)
        XCTAssertEqual(tally.written, threadCount * perThread)
        XCTAssertEqual(try store.sampleCount(), threadCount * perThread)
        XCTAssertEqual(try store.sampleCount(), try countedJSONLLines())
        let meta = try loadMeta()
        XCTAssertEqual(meta.sampleCount, threadCount * perThread)
        XCTAssertEqual(try store.estimatedBytes(), meta.estimatedBytes)
    }

    private static let engineConfigKeys: Set<String> = [
        "upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"
    ]

    private func makeStore(settings: MonitorSettings = .default) -> HistoryStore {
        HistoryStore(directory: history, settings: settings, calendar: calendar)
    }

    private var metaURL: URL {
        history.appendingPathComponent("meta.json")
    }

    private func jsonlFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: history.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func countedJSONLLines() throws -> Int {
        var total = 0
        for url in try jsonlFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            text.enumerateLines { line, _ in
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    total += 1
                }
            }
        }
        return total
    }

    private func fileBytes(named name: String) throws -> Int {
        try fileBytes(at: history.appendingPathComponent(name))
    }

    private func fileBytes(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private func loadMeta() throws -> (sampleCount: Int, estimatedBytes: Int, lineCounts: [String: Int]) {
        let data = try Data(contentsOf: metaURL)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            XCTFail("meta.json 顶层必须是对象")
            return (0, 0, [:])
        }
        let sampleCount = (object["sampleCount"] as? NSNumber)?.intValue ?? -1
        let estimatedBytes = (object["estimatedBytes"] as? NSNumber)?.intValue ?? -1
        var lineCounts: [String: Int] = [:]
        if let rawCounts = object["lineCounts"] as? [String: Any] {
            for (key, value) in rawCounts {
                lineCounts[key] = (value as? NSNumber)?.intValue
            }
        }
        return (sampleCount, estimatedBytes, lineCounts)
    }

    private enum AppendKind: Equatable {
        case written
        case skippedPaused
        case failed
    }

    private func kind(_ result: HistoryStoreAppendResult) -> AppendKind {
        switch result {
        case .written: return .written
        case .skippedPaused: return .skippedPaused
        case .failed: return .failed
        }
    }

    private func sample(at date: Date, watts: Double?) -> HistorySample {
        HistorySample(
            at: date,
            percent: 80,
            watts: watts,
            direction: EnergyFlowDirection.discharge.rawValue,
            pluggedIn: false,
            useAdapter: false,
            thermal: "nominal",
            enginePhase: "idle"
        )
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }
}

/// 测试夹具：HistoryStore 用 NSLock 保护可变状态，此处仅用于跨线程捕获。
private final class StoreBox: @unchecked Sendable {
    let store: HistoryStore
    init(_ store: HistoryStore) { self.store = store }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var writtenValue = 0
    private var failedValue = 0

    func addWritten() {
        lock.lock()
        writtenValue += 1
        lock.unlock()
    }

    func addFailed() {
        lock.lock()
        failedValue += 1
        lock.unlock()
    }

    var written: Int {
        lock.lock()
        defer { lock.unlock() }
        return writtenValue
    }

    var failed: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedValue
    }
}

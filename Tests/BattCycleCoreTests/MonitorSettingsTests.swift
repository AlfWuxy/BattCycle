import BattCycleCore
import XCTest

final class MonitorSettingsTests: XCTestCase {
    func testDefaultsMatchProductPolicy() {
        let settings = MonitorSettings.default
        XCTAssertEqual(settings.historyIntervalSeconds, 10)
        XCTAssertFalse(settings.recordingPaused)
        XCTAssertEqual(settings.retentionDays, 30)
        XCTAssertEqual(MonitorSettings.presetIntervals, [2, 5, 10, 30, 60, 300])
        XCTAssertEqual(MonitorSettings.allowedRetentionDays, [7, 30, 90])
        XCTAssertEqual(MonitorSettings.intervalRange, 2...3600)
        XCTAssertTrue(MonitorSettings.jsonKeys.isDisjoint(with: MonitorSettings.engineConfigJSONKeys))
        XCTAssertEqual(MonitorSettings.engineConfigJSONKeys.count, 6)
    }

    func testEncodedSchemaHasExactlyFourKeys() throws {
        let url = try temporaryFile()
        try MonitorSettings.default.save(to: url)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            MonitorSettings.jsonKeys
        )
        XCTAssertTrue(MonitorSettings.jsonKeys.isDisjoint(with: MonitorSettings.engineConfigJSONKeys))
        for engineKey in MonitorSettings.engineConfigJSONKeys {
            XCTAssertNil(json[engineKey], "历史键不得写入 config.json 的字段 \(engineKey)")
        }
    }

    func testHistoryKeysStayOutOfEngineConfigSchema() {
        XCTAssertEqual(
            MonitorSettings.jsonKeys,
            Set(["historyIntervalSeconds", "recordingPaused", "retentionDays", "lastModified"])
        )
        XCTAssertEqual(
            MonitorSettings.engineConfigJSONKeys,
            Set(["upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"])
        )
        XCTAssertFalse(MonitorSettings.jsonKeys.contains("pollSeconds"))
        XCTAssertFalse(MonitorSettings.engineConfigJSONKeys.contains("historyIntervalSeconds"))
        XCTAssertFalse(MonitorSettings.engineConfigJSONKeys.contains("recordingPaused"))
    }

    func testPresetAndCustomIntervalsAreAccepted() throws {
        for interval in [2, 5, 7, 10, 15, 30, 60, 90, 300, 3600] {
            var settings = MonitorSettings.default
            settings.historyIntervalSeconds = interval
            XCTAssertNoThrow(try settings.validated(), "interval \(interval)")
        }
    }

    func testIntervalValidationRejectsOutOfRange() {
        for interval in [0, 1, 3601, -2, 86_400] {
            var settings = MonitorSettings.default
            settings.historyIntervalSeconds = interval
            XCTAssertThrowsError(try settings.validated(), "interval \(interval)")
        }
    }

    func testRetentionOnlyAllowsSevenThirtyNinety() throws {
        for days in [7, 30, 90] {
            var settings = MonitorSettings.default
            settings.retentionDays = days
            XCTAssertNoThrow(try settings.validated())
        }
        for days in [1, 14, 31, 365] {
            var settings = MonitorSettings.default
            settings.retentionDays = days
            XCTAssertThrowsError(try settings.validated(), "retention \(days)")
        }
    }

    func testUnknownAndMissingKeysAreRejected() throws {
        let url = try temporaryFile()
        try Data("{\"historyIntervalSeconds\":10,\"recordingPaused\":false,\"retentionDays\":30,\"lastModified\":\"2026-09-02T00:00:00Z\",\"pollSeconds\":10}".utf8)
            .write(to: url)
        XCTAssertThrowsError(try MonitorSettings.load(from: url)) { error in
            guard case MonitorSettingsError.unknownKeys(let keys) = error else {
                return XCTFail("expected unknownKeys, got \(error)")
            }
            XCTAssertTrue(keys.contains("pollSeconds"))
        }

        try Data("{\"historyIntervalSeconds\":10,\"recordingPaused\":false,\"lastModified\":\"2026-09-02T00:00:00Z\"}".utf8)
            .write(to: url)
        XCTAssertThrowsError(try MonitorSettings.load(from: url))
    }

    func testWrongTypesAreRejected() throws {
        let url = try temporaryFile()
        try Data("{\"historyIntervalSeconds\":10.5,\"recordingPaused\":false,\"retentionDays\":30,\"lastModified\":\"2026-09-02T00:00:00Z\"}".utf8)
            .write(to: url)
        XCTAssertThrowsError(try MonitorSettings.load(from: url))

        try Data("{\"historyIntervalSeconds\":10,\"recordingPaused\":1,\"retentionDays\":30,\"lastModified\":\"2026-09-02T00:00:00Z\"}".utf8)
            .write(to: url)
        XCTAssertThrowsError(try MonitorSettings.load(from: url))
    }

    func testRoundTripSaveIsAtomicAndPrivate() throws {
        let url = try temporaryFile()
        var settings = MonitorSettings.default
        settings.historyIntervalSeconds = 30
        settings.recordingPaused = true
        settings.retentionDays = 90
        try settings.save(to: url)

        let loaded = try MonitorSettings.load(from: url)
        XCTAssertEqual(loaded.historyIntervalSeconds, 30)
        XCTAssertTrue(loaded.recordingPaused)
        XCTAssertEqual(loaded.retentionDays, 90)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(Int(truncating: try XCTUnwrap(mode)) & 0o777, 0o600)
    }

    func testPauseFlagDoesNotCarryAdapterOrEngineSemantics() {
        var settings = MonitorSettings.default
        settings.recordingPaused = true
        XCTAssertTrue(settings.recordingPaused)
        XCTAssertEqual(settings.historyIntervalSeconds, MonitorSettings.default.historyIntervalSeconds)
        XCTAssertEqual(settings.retentionDays, MonitorSettings.default.retentionDays)
        XCTAssertFalse(MonitorSettings.jsonKeys.contains("pollSeconds"))
    }

    func testSupportPathsExposeMonitorAndHistoryURLs() {
        let monitor = SupportPaths.monitor.path
        let history = SupportPaths.historyDirectory.path
        XCTAssertTrue(monitor.hasSuffix("/BattCycle/monitor.json"))
        XCTAssertTrue(history.hasSuffix("/BattCycle/history"))
        XCTAssertFalse(monitor.contains("/Documents"))
        XCTAssertFalse(history.contains("/Desktop"))
        XCTAssertNotEqual(SupportPaths.monitor, SupportPaths.config)
        XCTAssertNotEqual(SupportPaths.historyDirectory, SupportPaths.applicationSupport)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("monitor.json")
    }
}

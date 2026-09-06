import BattCycleCore
import XCTest

final class CycleConfigTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testDefaultsUseConservativeLimits() throws {
        let config = CycleConfig.default
        XCTAssertEqual(config.upperLimit, 80)
        XCTAssertEqual(config.lowerLimit, 30)
        XCTAssertEqual(config.gpuSize, 2048)
        XCTAssertEqual(config.cpuJobs, 4)
        XCTAssertEqual(config.pollSeconds, 10)
        XCTAssertGreaterThan(config.stopAtEpoch, Int(Date().timeIntervalSince1970))
        XCTAssertLessThanOrEqual(config.stopAtEpoch, Int(Date().addingTimeInterval(86_400).timeIntervalSince1970))
    }

    func testAllowedJSONKeysRemainExactlySix() {
        XCTAssertEqual(CycleConfig.allowedJSONKeys.count, 6)
        XCTAssertEqual(
            CycleConfig.allowedJSONKeys,
            Set(["upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"])
        )
        XCTAssertTrue(CycleConfig.allowedJSONKeys.isDisjoint(with: CycleConfig.forbiddenMonitorKeys))
    }

    func testEncodedSchemaHasExactlySixKeys() throws {
        let data = try JSONEncoder().encode(validConfig())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), CycleConfig.allowedJSONKeys)
        XCTAssertFalse(json.keys.contains("historyIntervalSeconds"))
        XCTAssertFalse(json.keys.contains("recordingPaused"))
        XCTAssertFalse(json.keys.contains("retentionDays"))
        XCTAssertFalse(json.keys.contains("lastModified"))
    }

    func testParseAcceptsBoundaryValues() throws {
        let data = try jsonData(
            upperLimit: 100,
            lowerLimit: 20,
            gpuSize: 8192,
            cpuJobs: 16,
            pollSeconds: 60,
            stopAtEpoch: Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        )
        let config = try CycleConfig.parse(data, now: now)
        XCTAssertEqual(config.pollSeconds, 60)
        XCTAssertEqual(config.upperLimit, 100)
        XCTAssertEqual(config.lowerLimit, 20)
    }

    func testParseAcceptsPollSecondsFive() throws {
        let data = try jsonData(pollSeconds: 5)
        XCTAssertEqual(try CycleConfig.parse(data, now: now).pollSeconds, 5)
    }

    func testParseRejectsPollSecondsOutOfRange() throws {
        assertParseRejected(pollSeconds: 4, expected: .pollSecondsOutOfRange)
        assertParseRejected(pollSeconds: 61, expected: .pollSecondsOutOfRange)
        assertParseRejected(pollSeconds: 0, expected: .pollSecondsOutOfRange)
    }

    func testParseRejectsCyclePercentBounds() throws {
        assertParseRejected(lowerLimit: 19, expected: .lowerLimitOutOfRange)
        assertParseRejected(upperLimit: 49, expected: .upperLimitOutOfRange)
        assertParseRejected(upperLimit: 101, expected: .upperLimitOutOfRange)
        assertParseRejected(upperLimit: 80, lowerLimit: 76, expected: .insufficientHysteresis)
        assertParseRejected(upperLimit: 80, lowerLimit: 80, expected: .insufficientHysteresis)
    }

    func testParseRejectsMonitorAndHistoryKeys() throws {
        for key in ["historyIntervalSeconds", "recordingPaused", "retentionDays", "lastModified"] {
            var object = try validJSONObject()
            object[key] = key == "recordingPaused" ? true : 10
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try CycleConfig.parse(data, now: now), key) { error in
                guard case CycleConfig.ConfigError.monitorKeysNotAllowed(let keys) = error else {
                    XCTFail("\(key): \(error)")
                    return
                }
                XCTAssertEqual(keys, [key])
            }
        }
    }

    func testParseRejectsUnknownAndMissingKeys() throws {
        var extra = try validJSONObject()
        extra["futureFlag"] = 1
        XCTAssertThrowsError(try CycleConfig.parse(try JSONSerialization.data(withJSONObject: extra), now: now)) { error in
            guard case CycleConfig.ConfigError.unknownKeys(let keys) = error else {
                XCTFail("\(error)")
                return
            }
            XCTAssertEqual(keys, ["futureFlag"])
        }

        var missing = try validJSONObject()
        missing.removeValue(forKey: "pollSeconds")
        XCTAssertThrowsError(try CycleConfig.parse(try JSONSerialization.data(withJSONObject: missing), now: now)) { error in
            guard case CycleConfig.ConfigError.missingKeys(let keys) = error else {
                XCTFail("\(error)")
                return
            }
            XCTAssertEqual(keys, ["pollSeconds"])
        }
    }

    func testJSONDecoderAlsoRejectsMonitorKeys() throws {
        var object = try validJSONObject()
        object["historyIntervalSeconds"] = 10
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(CycleConfig.self, from: data))
    }

    func testAcceptsBoundaryValues() throws {
        var config = validConfig()
        config.upperLimit = 100
        config.lowerLimit = 20
        config.cpuJobs = 16
        config.gpuSize = 8192
        config.pollSeconds = 60
        config.stopAtEpoch = Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        XCTAssertNoThrow(try config.validated(now: now))
    }

    func testRejectsUnsafeChargeLimits() {
        assertRejected(\.lowerLimit, value: 19)
        assertRejected(\.lowerLimit, value: 80, upper: 80)
        assertRejected(\.lowerLimit, value: 76, upper: 80)
        assertRejected(\.upperLimit, value: 49)
        assertRejected(\.upperLimit, value: 101)
    }

    func testRejectsUnsupportedStressSettings() {
        assertRejected(\.cpuJobs, value: 0)
        assertRejected(\.cpuJobs, value: 17)
        assertRejected(\.gpuSize, value: 10240)
        assertRejected(\.pollSeconds, value: 4)
        assertRejected(\.pollSeconds, value: 61)
    }

    func testRejectsPastAndOverlongStopTimes() {
        var past = validConfig()
        past.stopAtEpoch = Int(now.timeIntervalSince1970)
        XCTAssertThrowsError(try past.validated(now: now))

        var tooFar = validConfig()
        tooFar.stopAtEpoch = Int(now.addingTimeInterval(86_401).timeIntervalSince1970)
        XCTAssertThrowsError(try tooFar.validated(now: now))
    }

    func testNextSevenAMIsInTheFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let next = CycleConfig.nextOccurrence(hour: 7, minute: 0, now: fixedNow, calendar: calendar)
        XCTAssertGreaterThan(next, fixedNow)
        XCTAssertEqual(calendar.component(.hour, from: next), 7)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)
    }

    func testApplyDefaultStopReplacesPastValue() {
        var config = CycleConfig(stopAtEpoch: 1)
        config.applyDefaultStopIfNeeded(now: now)
        XCTAssertGreaterThan(config.stopAtEpoch, Int(now.timeIntervalSince1970))
        XCTAssertLessThanOrEqual(config.stopAtEpoch, Int(now.addingTimeInterval(86_400).timeIntervalSince1970))
    }

    func testSupportPathsStayOutOfICloudFolders() {
        let support = SupportPaths.applicationSupport.path
        let logs = SupportPaths.logs.path
        XCTAssertFalse(support.contains("/Desktop"))
        XCTAssertFalse(support.contains("/Documents"))
        XCTAssertFalse(logs.contains("/Desktop"))
        XCTAssertFalse(logs.contains("/Documents"))
        XCTAssertTrue(support.contains("Library/Application Support/BattCycle"))
        XCTAssertTrue(logs.contains("Library/Logs/BattCycle"))
    }

    private func validConfig() -> CycleConfig {
        CycleConfig(stopAtEpoch: Int(now.addingTimeInterval(3_600).timeIntervalSince1970))
    }

    private func validJSONObject(
        upperLimit: Int = 80,
        lowerLimit: Int = 30,
        gpuSize: Int = 2048,
        cpuJobs: Int = 4,
        pollSeconds: Int = 10,
        stopAtEpoch: Int? = nil
    ) throws -> [String: Any] {
        [
            "upperLimit": upperLimit,
            "lowerLimit": lowerLimit,
            "gpuSize": gpuSize,
            "cpuJobs": cpuJobs,
            "pollSeconds": pollSeconds,
            "stopAtEpoch": stopAtEpoch ?? Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
        ]
    }

    private func jsonData(
        upperLimit: Int = 80,
        lowerLimit: Int = 30,
        gpuSize: Int = 2048,
        cpuJobs: Int = 4,
        pollSeconds: Int = 10,
        stopAtEpoch: Int? = nil
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: try validJSONObject(
                upperLimit: upperLimit,
                lowerLimit: lowerLimit,
                gpuSize: gpuSize,
                cpuJobs: cpuJobs,
                pollSeconds: pollSeconds,
                stopAtEpoch: stopAtEpoch
            )
        )
    }

    private func assertParseRejected(
        upperLimit: Int = 80,
        lowerLimit: Int = 30,
        pollSeconds: Int = 10,
        expected: CycleConfig.ConfigError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let data = try jsonData(
                upperLimit: upperLimit,
                lowerLimit: lowerLimit,
                pollSeconds: pollSeconds
            )
            _ = try CycleConfig.parse(data, now: now)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CycleConfig.ConfigError {
            XCTAssertEqual(error.errorDescription, expected.errorDescription, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    private func assertRejected(
        _ keyPath: WritableKeyPath<CycleConfig, Int>,
        value: Int,
        upper: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var config = validConfig()
        if let upper { config.upperLimit = upper }
        config[keyPath: keyPath] = value
        XCTAssertThrowsError(try config.validated(now: now), file: file, line: line)
    }
}

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

    func testEncodedSchemaHasExactlySixKeys() throws {
        let data = try JSONEncoder().encode(validConfig())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(json.keys),
            Set(["upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"])
        )
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

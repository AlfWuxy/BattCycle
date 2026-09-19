import BattCycleCore
import XCTest

final class TimedDisableHelpTests: XCTestCase {
    func testForceOnlyIsNotTimedDisable() {
        XCTAssertFalse(TimedDisableHelp.supportsTimedDisable("--force"))
        XCTAssertFalse(
            TimedDisableHelp.supportsTimedDisable(
                """
                Usage:
                  batt adapter disable --force
                """
            )
        )
        XCTAssertFalse(
            CapabilityInventory.timedDisableSupported(fromHelp: "batt adapter disable --force")
        )
    }

    func testBareForIsTimedDisable() {
        XCTAssertTrue(TimedDisableHelp.supportsTimedDisable("--for"))
        XCTAssertTrue(
            TimedDisableHelp.supportsTimedDisable("batt adapter disable --for DURATION")
        )
        XCTAssertTrue(CapabilityInventory.timedDisableSupported(fromHelp: "--for"))
    }

    func testForEqualsDurationIsTimedDisable() {
        XCTAssertTrue(TimedDisableHelp.supportsTimedDisable("--for=DURATION"))
        XCTAssertTrue(TimedDisableHelp.supportsTimedDisable("--for=5s"))
        XCTAssertTrue(
            TimedDisableHelp.supportsTimedDisable("batt adapter disable --for=<duration>")
        )
        XCTAssertTrue(
            CapabilityInventory.timedDisableSupported(fromHelp: "--for=DURATION")
        )
    }

    func testForceMustNotBeConfusedWithFor() {
        XCTAssertFalse(TimedDisableHelp.supportsTimedDisable("--forward"))
        XCTAssertFalse(TimedDisableHelp.supportsTimedDisable("--forage"))
        XCTAssertFalse(TimedDisableHelp.supportsTimedDisable("--force --format"))
        XCTAssertTrue(TimedDisableHelp.supportsTimedDisable("--force --for"))
        XCTAssertTrue(TimedDisableHelp.supportsTimedDisable("--for --force"))
        XCTAssertEqual(
            TimedDisableHelp.optionTokens(in: "disable --force --for=5s"),
            ["--force", "--for=5s"]
        )
        // 子串 contains("--for") 会把 --force 判真；选项词匹配必须为假。
        XCTAssertTrue("--force".contains("--for"))
        XCTAssertFalse(TimedDisableHelp.supportsTimedDisable("Usage: batt adapter disable --force"))
    }
}

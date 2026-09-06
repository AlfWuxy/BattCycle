import BattCycleCore
import XCTest

final class BattStatusSnapshotTests: XCTestCase {
    func testParsesCompleteFixture() throws {
        let snapshot = try BattStatusSnapshot.parse(Self.completeFixture)

        XCTAssertEqual(snapshot.pluggedIn, true)
        XCTAssertEqual(snapshot.useAdapter, true)
        XCTAssertEqual(snapshot.allowCharging, true)
        XCTAssertEqual(snapshot.allowNonRootAccess, true)
        XCTAssertEqual(snapshot.adapterControl, true)
        XCTAssertEqual(snapshot.currentChargePercent, 72)
        XCTAssertEqual(snapshot.batteryState, "charging")
        XCTAssertEqual(snapshot.chargeRateWatts, 28.5)
        XCTAssertEqual(snapshot.upperLimitPercent, 80)
        XCTAssertEqual(snapshot.timeToLimitMinutes, 34)
        XCTAssertEqual(snapshot.fullCapacityMah, 5103)
        XCTAssertEqual(snapshot.voltageVolts, 12.84)
        XCTAssertEqual(snapshot.lowerLimitPercent, 70)
        XCTAssertEqual(snapshot.configurationEnabled, true)
        XCTAssertEqual(snapshot.preventIdleSleep, false)
        XCTAssertEqual(snapshot.disableChargingPreSleep, true)
        XCTAssertEqual(snapshot.preventSystemSleep, false)
        XCTAssertEqual(snapshot.maxChargePowerWatts, nil)
    }

    func testMissingKeysAreNilNotZeroOrFalse() throws {
        let snapshot = try BattStatusSnapshot.parse("{}")

        XCTAssertNil(snapshot.pluggedIn)
        XCTAssertNil(snapshot.useAdapter)
        XCTAssertNil(snapshot.allowCharging)
        XCTAssertNil(snapshot.allowNonRootAccess)
        XCTAssertNil(snapshot.adapterControl)
        XCTAssertNil(snapshot.configurationEnabled)
        XCTAssertNil(snapshot.preventIdleSleep)
        XCTAssertNil(snapshot.disableChargingPreSleep)
        XCTAssertNil(snapshot.preventSystemSleep)
        XCTAssertNil(snapshot.currentChargePercent)
        XCTAssertNil(snapshot.batteryState)
        XCTAssertNil(snapshot.chargeRateWatts)
        XCTAssertNil(snapshot.upperLimitPercent)
        XCTAssertNil(snapshot.lowerLimitPercent)
        XCTAssertNil(snapshot.maxChargePowerWatts)

        XCTAssertNotEqual(snapshot.pluggedIn, false)
        XCTAssertNotEqual(snapshot.useAdapter, false)
        XCTAssertNotEqual(snapshot.allowCharging, false)
        XCTAssertNotEqual(snapshot.adapterControl, false)
        XCTAssertNotEqual(snapshot.configurationEnabled, false)
        XCTAssertNotEqual(snapshot.currentChargePercent, 0)
        XCTAssertNotEqual(snapshot.chargeRateWatts, 0)
        XCTAssertNotEqual(snapshot.upperLimitPercent, 0)
    }

    func testEmptyNestedObjectsLeaveBooleansUnavailable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"charging":{},"configuration":{},"compatibility":{}}"#
        )
        XCTAssertNil(snapshot.pluggedIn)
        XCTAssertNil(snapshot.useAdapter)
        XCTAssertNil(snapshot.allowCharging)
        XCTAssertNil(snapshot.allowNonRootAccess)
        XCTAssertNil(snapshot.upperLimitPercent)
        XCTAssertNil(snapshot.adapterControl)
        XCTAssertNotEqual(snapshot.pluggedIn, false)
        XCTAssertNotEqual(snapshot.allowCharging, false)
        XCTAssertNotEqual(snapshot.upperLimitPercent, 0)
    }

    func testExplicitFalseIsDistinctFromMissing() throws {
        let explicit = try BattStatusSnapshot.parse(
            #"{"charging":{"pluggedIn":false,"useAdapter":false,"allowCharging":false}}"#
        )
        XCTAssertEqual(explicit.pluggedIn, false)
        XCTAssertEqual(explicit.useAdapter, false)
        XCTAssertEqual(explicit.allowCharging, false)
        XCTAssertNil(explicit.adapterControl)

        let missing = try BattStatusSnapshot.parse(#"{"charging":{"pluggedIn":false}}"#)
        XCTAssertEqual(missing.pluggedIn, false)
        XCTAssertNil(missing.useAdapter)
        XCTAssertNotEqual(missing.useAdapter, false)
    }

    func testUpperLimitPercentIsReadOnlyObservation() throws {
        let present = try BattStatusSnapshot.parse(
            #"{"configuration":{"upperLimitPercent":80}}"#
        )
        XCTAssertEqual(present.upperLimitPercent, 80)

        let missing = try BattStatusSnapshot.parse(#"{"configuration":{"enabled":true}}"#)
        XCTAssertNil(missing.upperLimitPercent)
        XCTAssertEqual(missing.configurationEnabled, true)
        XCTAssertNotEqual(missing.upperLimitPercent, 0)
    }

    func testChargeRateWattsZeroIsDistinctFromMissing() throws {
        let zero = try BattStatusSnapshot.parse(
            #"{"battery":{"chargeRateWatts":0}}"#
        )
        XCTAssertEqual(zero.chargeRateWatts, 0)

        let missing = try BattStatusSnapshot.parse(
            #"{"battery":{"currentChargePercent":50}}"#
        )
        XCTAssertNil(missing.chargeRateWatts)
        XCTAssertEqual(missing.currentChargePercent, 50)
    }

    func testNullChargeRateWattsIsMissing() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"battery":{"chargeRateWatts":null,"currentChargePercent":10}}"#
        )
        XCTAssertNil(snapshot.chargeRateWatts)
        XCTAssertEqual(snapshot.currentChargePercent, 10)
    }

    func testExtraKeysDoNotCrashDecoder() throws {
        let json = """
        {
          "charging": {"pluggedIn": false, "futureFlag": "x"},
          "battery": {"state": "full", "mystery": 1},
          "configuration": {"upperLimitPercent": 60, "brandNew": true},
          "compatibility": {"adapterControl": false, "other": []},
          "calibration": {"phase": "Idle"},
          "futureSection": {"nested": {"ok": true}}
        }
        """
        let snapshot = try BattStatusSnapshot.parse(json)
        XCTAssertEqual(snapshot.pluggedIn, false)
        XCTAssertEqual(snapshot.batteryState, "full")
        XCTAssertEqual(snapshot.upperLimitPercent, 60)
        XCTAssertEqual(snapshot.adapterControl, false)
        XCTAssertNil(snapshot.chargeRateWatts)
        XCTAssertNil(snapshot.useAdapter)
        XCTAssertNotEqual(snapshot.useAdapter, false)
    }

    func testMapsMaxChargePowerWhenJSONKeyPresent() throws {
        let fromBattery = try BattStatusSnapshot.parse(
            #"{"battery":{"maxChargePowerWatts":96}}"#
        )
        XCTAssertEqual(fromBattery.maxChargePowerWatts, 96)

        let fromAlias = try BattStatusSnapshot.parse(
            #"{"battery":{"maxChargeRateWatts":70.5}}"#
        )
        XCTAssertEqual(fromAlias.maxChargePowerWatts, 70.5)

        let fromCompatibility = try BattStatusSnapshot.parse(
            #"{"compatibility":{"maxChargePowerWatts":140}}"#
        )
        XCTAssertEqual(fromCompatibility.maxChargePowerWatts, 140)
    }

    func testIntegerChargeRateDecodesAsDouble() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"battery":{"chargeRateWatts":12}}"#
        )
        XCTAssertEqual(snapshot.chargeRateWatts, 12)
    }

    /// batt 官方 JSON 示例，含 compatibility.adapterControl。
    static let completeFixture = """
    {
      "charging": {
        "allowCharging": true,
        "useAdapter": true,
        "pluggedIn": true
      },
      "battery": {
        "currentChargePercent": 72,
        "state": "charging",
        "timeToLimitMinutes": 34,
        "fullCapacityMah": 5103,
        "chargeRateWatts": 28.5,
        "voltageVolts": 12.84
      },
      "configuration": {
        "enabled": true,
        "upperLimitPercent": 80,
        "lowerLimitPercent": 70,
        "preventIdleSleep": false,
        "disableChargingPreSleep": true,
        "preventSystemSleep": false,
        "allowNonRootAccess": true,
        "controlMagSafeLed": {
          "enabled": false,
          "mode": "disabled"
        }
      },
      "calibration": {
        "phase": "Idle"
      },
      "compatibility": {
        "adapterControl": true
      }
    }
    """
}

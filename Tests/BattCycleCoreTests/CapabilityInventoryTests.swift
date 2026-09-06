import BattCycleCore
import XCTest

final class CapabilityInventoryTests: XCTestCase {
    func testAdapterControlFalseMakesAdapterDisableNotWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "charging": {"useAdapter": true, "pluggedIn": true},
              "compatibility": {"adapterControl": false},
              "configuration": {"upperLimitPercent": 80, "allowNonRootAccess": true}
            }
            """
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        XCTAssertFalse(disable.writable)
        XCTAssertNotEqual(disable.controlState, .writable)
        XCTAssertNotNil(disable.unavailableReasonZH)

        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(enable.writable)
        XCTAssertNotEqual(enable.controlState, .writable)
    }

    func testMissingForInHelpMakesTimedDisableUnsupported() {
        let helpWithoutFor = """
        Usage:
          batt adapter disable
          batt adapter enable
        """
        XCTAssertFalse(CapabilityInventory.timedDisableSupported(fromHelp: helpWithoutFor))
        XCTAssertTrue(
            CapabilityInventory.timedDisableSupported(
                fromHelp: "batt adapter disable --for=<duration>"
            )
        )
        XCTAssertFalse(
            CapabilityInventory.timedDisableSupported(fromHelp: "batt adapter disable --force")
        )
        XCTAssertTrue(
            CapabilityInventory.timedDisableSupported(fromHelp: "batt adapter disable --for")
        )
        XCTAssertTrue(
            CapabilityInventory.timedDisableSupported(fromHelp: "batt adapter disable --for=DURATION")
        )

        let snapshot = try? BattStatusSnapshot.parse(
            #"{"compatibility":{"adapterControl":true},"charging":{"useAdapter":true}}"#
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: false,
            timedDisableSupported: CapabilityInventory.timedDisableSupported(fromHelp: helpWithoutFor),
            daemonReachable: true
        )
        let disable = inventory.capability(id: CapabilityID.adapterDisable)
        XCTAssertEqual(disable?.writable, false)
        XCTAssertNotEqual(disable?.controlState, .writable)
        XCTAssertTrue(disable?.unavailableReasonZH?.contains("--for") == true)
    }

    func testMaxChargePowerUnsupportedWhenNoKey() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"battery":{"chargeRateWatts":28.5},"compatibility":{"adapterControl":true}}"#
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let power = try XCTUnwrap(inventory.capability(id: CapabilityID.maxChargePowerWatts))
        XCTAssertFalse(power.writable)
        XCTAssertFalse(power.readable)
        XCTAssertEqual(power.controlState, .unsupported)
        XCTAssertNotNil(power.unavailableReasonZH)
    }

    func testMaxChargePowerReadOnlyWhenJSONKeyPresent() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"battery":{"maxChargePowerWatts":96,"chargeRateWatts":20}}"#
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let power = try XCTUnwrap(inventory.capability(id: CapabilityID.maxChargePowerWatts))
        XCTAssertTrue(power.readable)
        XCTAssertFalse(power.writable)
        XCTAssertEqual(power.controlState, .readable)
        XCTAssertEqual(power.currentValue, .number(96))
        XCTAssertEqual(power.unit, "W")
    }

    func testMaxChargePowerReadOnlyWhenIOKitValuePresent() {
        let inventory = CapabilityInventory.build(
            snapshot: nil,
            battVersionOk: false,
            timedDisableSupported: false,
            daemonReachable: false,
            iokitMaxChargePowerWatts: 140
        )
        let power = inventory.capability(id: CapabilityID.maxChargePowerWatts)
        XCTAssertEqual(power?.readable, true)
        XCTAssertEqual(power?.writable, false)
        XCTAssertEqual(power?.controlState, .readable)
        XCTAssertEqual(power?.source, .iokit)
        XCTAssertEqual(power?.currentValue, .number(140))
    }

    func testUpperLimitPercentPresentIsReadableNotWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"configuration":{"upperLimitPercent":80}}"#
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let limit = try XCTUnwrap(inventory.capability(id: CapabilityID.chargePercentLimitBatt))
        XCTAssertTrue(limit.readable)
        XCTAssertFalse(limit.writable)
        XCTAssertEqual(limit.controlState, .readable)
        XCTAssertEqual(limit.currentValue, .number(80))
        XCTAssertEqual(limit.unit, "%")
    }

    func testUpperLimitPercentMissingIsNotReadable() throws {
        let snapshot = try BattStatusSnapshot.parse("{}")
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let limit = try XCTUnwrap(inventory.capability(id: CapabilityID.chargePercentLimitBatt))
        XCTAssertFalse(limit.readable)
        XCTAssertFalse(limit.writable)
        XCTAssertEqual(limit.controlState, .unsupported)
    }

    func testCycleThresholdsAreLocalWritableNotBattLimit() {
        let inventory = CapabilityInventory.build(
            snapshot: nil,
            battVersionOk: false,
            timedDisableSupported: false,
            daemonReachable: false,
            cycleUpperPercent: 80,
            cycleLowerPercent: 30
        )
        let upper = inventory.capability(id: CapabilityID.cycleUpper)
        let lower = inventory.capability(id: CapabilityID.cycleLower)
        XCTAssertEqual(upper?.writable, true)
        XCTAssertEqual(lower?.writable, true)
        XCTAssertEqual(upper?.readable, true)
        XCTAssertEqual(lower?.readable, true)
        XCTAssertEqual(upper?.controlState, .writable)
        XCTAssertEqual(lower?.controlState, .writable)
        XCTAssertEqual(upper?.source, .cycleConfig)
        XCTAssertEqual(lower?.source, .cycleConfig)
        XCTAssertEqual(upper?.supportedRange, 50...100)
        XCTAssertEqual(lower?.supportedRange, 20...80)
        XCTAssertTrue(upper?.noteZH?.contains("local BattCycle config, not batt limit") == true)
        XCTAssertTrue(lower?.noteZH?.contains("local BattCycle config, not batt limit") == true)
        XCTAssertEqual(upper?.currentValue, .number(80))
        XCTAssertEqual(lower?.currentValue, .number(30))
    }

    func testAdapterDisableWritableOnlyWithTimedDisableAdapterControlAndDaemon() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "compatibility": {"adapterControl": true},
              "charging": {"useAdapter": true, "pluggedIn": true},
              "configuration": {"allowNonRootAccess": true}
            }
            """
        )
        let ready = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(ready.capability(id: CapabilityID.adapterDisable))
        XCTAssertTrue(disable.writable)
        XCTAssertTrue(disable.readable)
        XCTAssertEqual(disable.controlState, .writable)
        XCTAssertEqual(disable.supportedRange, 1...600)
        XCTAssertTrue(disable.requiresConfirmation)
        XCTAssertEqual(disable.risk, .high)

        let enable = try XCTUnwrap(ready.capability(id: CapabilityID.adapterEnable))
        XCTAssertTrue(enable.writable)
        XCTAssertEqual(enable.controlState, .writable)
    }

    func testAllowNonRootAccessFalseMakesAdapterControlsNotWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "charging": {"useAdapter": true, "pluggedIn": true},
              "compatibility": {"adapterControl": true},
              "configuration": {"allowNonRootAccess": false}
            }
            """
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(disable.writable)
        XCTAssertFalse(enable.writable)
        XCTAssertNotEqual(disable.controlState, .writable)
        XCTAssertNotEqual(enable.controlState, .writable)
        XCTAssertTrue(disable.unavailableReasonZH?.contains("allowNonRootAccess") == true)
        XCTAssertTrue(enable.unavailableReasonZH?.contains("allowNonRootAccess") == true)
    }

    func testMissingAllowNonRootAccessMakesAdapterControlsNotWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            #"{"compatibility":{"adapterControl":true},"charging":{"useAdapter":true,"pluggedIn":true}}"#
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(disable.writable)
        XCTAssertFalse(enable.writable)
        XCTAssertTrue(disable.unavailableReasonZH?.contains("allowNonRootAccess") == true)
        XCTAssertTrue(enable.unavailableReasonZH?.contains("allowNonRootAccess") == true)
    }

    func testBatt07WithAdapterControlTrueStillNotWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "charging": {"useAdapter": true, "pluggedIn": true},
              "compatibility": {"adapterControl": true},
              "configuration": {"allowNonRootAccess": true}
            }
            """
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: false,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(disable.writable)
        XCTAssertFalse(enable.writable)
        XCTAssertNotEqual(disable.controlState, .writable)
        XCTAssertNotEqual(enable.controlState, .writable)
        XCTAssertTrue(disable.unavailableReasonZH?.contains("0.8.0") == true)
        XCTAssertTrue(enable.unavailableReasonZH?.contains("0.8.0") == true)
        XCTAssertTrue(disable.unavailableReasonZH?.contains("Client") == true)
        XCTAssertTrue(disable.unavailableReasonZH?.contains("Daemon") == true)
        XCTAssertTrue(enable.unavailableReasonZH?.contains("Client") == true)
        XCTAssertTrue(enable.unavailableReasonZH?.contains("Daemon") == true)
    }

    func testUnpluggedMakesDisableNotWritableButEnableRemainsWritable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "charging": {"useAdapter": true, "pluggedIn": false},
              "compatibility": {"adapterControl": true},
              "configuration": {"allowNonRootAccess": true}
            }
            """
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: true,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(disable.writable)
        XCTAssertNotEqual(disable.controlState, .writable)
        XCTAssertEqual(disable.unavailableReasonZH, "适配器未连接")
        XCTAssertTrue(enable.writable)
        XCTAssertEqual(enable.controlState, .writable)
        XCTAssertNil(enable.unavailableReasonZH)
    }

    func testAdapterEnableDoesNotRequireTimedDisable() throws {
        let snapshot = try BattStatusSnapshot.parse(
            """
            {
              "charging": {"useAdapter": true, "pluggedIn": true},
              "compatibility": {"adapterControl": true},
              "configuration": {"allowNonRootAccess": true}
            }
            """
        )
        let inventory = CapabilityInventory.build(
            snapshot: snapshot,
            battVersionOk: true,
            timedDisableSupported: false,
            daemonReachable: true
        )
        let disable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterDisable))
        let enable = try XCTUnwrap(inventory.capability(id: CapabilityID.adapterEnable))
        XCTAssertFalse(disable.writable)
        XCTAssertTrue(enable.writable)
        XCTAssertEqual(enable.controlState, .writable)
    }

    func testBatt073DaemonDownIsUnavailableWithReasons() {
        let inventory = CapabilityInventory.build(
            snapshot: nil,
            battVersionOk: false,
            timedDisableSupported: false,
            daemonReachable: false
        )
        let disable = inventory.capability(id: CapabilityID.adapterDisable)
        let enable = inventory.capability(id: CapabilityID.adapterEnable)
        let limit = inventory.capability(id: CapabilityID.chargePercentLimitBatt)
        let power = inventory.capability(id: CapabilityID.maxChargePowerWatts)

        XCTAssertEqual(disable?.writable, false)
        XCTAssertEqual(enable?.writable, false)
        XCTAssertEqual(disable?.controlState, .unsupported)
        XCTAssertEqual(enable?.controlState, .unsupported)
        XCTAssertEqual(limit?.controlState, .unsupported)
        XCTAssertEqual(power?.controlState, .unsupported)
        XCTAssertTrue(disable?.unavailableReasonZH?.isEmpty == false)
        XCTAssertTrue(enable?.unavailableReasonZH?.isEmpty == false)
        XCTAssertEqual(inventory.controlState(for: CapabilityID.cycleUpper), .writable)
        XCTAssertEqual(inventory.controlState(for: CapabilityID.cycleLower), .writable)
    }

    func testControlStatePrefersWritableThenReadableThenUnsupported() {
        XCTAssertEqual(
            controlState(
                Capability(
                    id: "x",
                    nameZH: "x",
                    currentValue: .none,
                    unit: "",
                    source: .none,
                    readable: true,
                    writable: true,
                    supportedRange: nil,
                    requiresConfirmation: false,
                    risk: .low,
                    unavailableReasonZH: nil
                )
            ),
            .writable
        )
        XCTAssertEqual(
            controlState(
                Capability(
                    id: "x",
                    nameZH: "x",
                    currentValue: .none,
                    unit: "",
                    source: .none,
                    readable: true,
                    writable: false,
                    supportedRange: nil,
                    requiresConfirmation: false,
                    risk: .low,
                    unavailableReasonZH: nil
                )
            ),
            .readable
        )
        XCTAssertEqual(
            controlState(
                Capability(
                    id: "x",
                    nameZH: "x",
                    currentValue: .none,
                    unit: "",
                    source: .none,
                    readable: false,
                    writable: false,
                    supportedRange: nil,
                    requiresConfirmation: false,
                    risk: .low,
                    unavailableReasonZH: nil
                )
            ),
            .unsupported
        )
    }

    func testUnknownCapabilityIdIsUnsupported() {
        let inventory = CapabilityInventory.build(
            snapshot: nil,
            battVersionOk: false,
            timedDisableSupported: false,
            daemonReachable: false
        )
        XCTAssertEqual(inventory.controlState(for: "doesNotExist"), .unsupported)
    }
}

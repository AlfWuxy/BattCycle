import BattCycleCore
import XCTest

final class CapabilityTests: XCTestCase {
    func testModelFieldsRoundTrip() {
        let capability = Capability(
            id: CapabilityID.cycleUpper,
            nameZH: "循环充电上限",
            currentValue: .number(80),
            unit: "%",
            source: .cycleConfig,
            readable: true,
            writable: true,
            supportedRange: 50...100,
            requiresConfirmation: false,
            risk: .medium,
            unavailableReasonZH: nil,
            noteZH: "local"
        )
        XCTAssertEqual(capability.id, CapabilityID.cycleUpper)
        XCTAssertEqual(capability.nameZH, "循环充电上限")
        XCTAssertEqual(capability.currentValue, .number(80))
        XCTAssertEqual(capability.unit, "%")
        XCTAssertEqual(capability.source, .cycleConfig)
        XCTAssertTrue(capability.readable)
        XCTAssertTrue(capability.writable)
        XCTAssertEqual(capability.supportedRange, 50...100)
        XCTAssertFalse(capability.requiresConfirmation)
        XCTAssertEqual(capability.risk, .medium)
        XCTAssertNil(capability.unavailableReasonZH)
        XCTAssertEqual(capability.noteZH, "local")
        XCTAssertTrue(capability.allowsWritableSlider)
        XCTAssertEqual(capability.controlState, .writable)
    }

    func testMissingValueIsNoneNotZero() {
        let capability = makeCapability(currentValue: .none)
        XCTAssertEqual(capability.currentValue, .none)
        XCTAssertNotEqual(capability.currentValue, .number(0))
    }

    func testControlStatePrefersWritableThenReadableThenUnsupported() {
        XCTAssertEqual(
            makeCapability(readable: true, writable: true).controlState,
            .writable
        )
        XCTAssertEqual(
            controlState(makeCapability(readable: true, writable: true)),
            .writable
        )
        XCTAssertEqual(
            makeCapability(readable: true, writable: false).controlState,
            .readable
        )
        XCTAssertEqual(
            makeCapability(readable: false, writable: false).controlState,
            .unsupported
        )
        XCTAssertFalse(CapabilityID.forbidsWritableControl("x"))
    }

    func testMaxChargePowerNeverWritableSliderEvenWhenRequested() {
        XCTAssertTrue(CapabilityID.forbidsWritableControl(CapabilityID.maxChargePowerWatts))

        let requestedWrite = makeCapability(
            id: CapabilityID.maxChargePowerWatts,
            nameZH: "最大充电功率",
            currentValue: .number(96),
            unit: "W",
            source: .battStatusJSON,
            readable: true,
            writable: true,
            supportedRange: 0...200,
            risk: .low
        )
        XCTAssertTrue(requestedWrite.readable)
        XCTAssertFalse(requestedWrite.writable)
        XCTAssertFalse(requestedWrite.allowsWritableSlider)
        XCTAssertEqual(requestedWrite.controlState, .readable)
        XCTAssertNotEqual(requestedWrite.controlState, .writable)
        XCTAssertEqual(controlState(requestedWrite), .readable)
    }

    func testMaxChargePowerReadOnlyWhenValuePresent() {
        let fromJSON = makeCapability(
            id: CapabilityID.maxChargePowerWatts,
            nameZH: "最大充电功率",
            currentValue: .number(96),
            unit: "W",
            source: .battStatusJSON,
            readable: true,
            writable: false
        )
        XCTAssertEqual(fromJSON.controlState, .readable)
        XCTAssertEqual(fromJSON.currentValue, .number(96))
        XCTAssertEqual(fromJSON.source, .battStatusJSON)
        XCTAssertFalse(fromJSON.allowsWritableSlider)

        let fromIOKit = makeCapability(
            id: CapabilityID.maxChargePowerWatts,
            nameZH: "最大充电功率",
            currentValue: .number(140),
            unit: "W",
            source: .iokit,
            readable: true,
            writable: false
        )
        XCTAssertEqual(fromIOKit.controlState, .readable)
        XCTAssertEqual(fromIOKit.source, .iokit)
        XCTAssertFalse(fromIOKit.writable)
    }

    func testMaxChargePowerUnsupportedWhenMissing() {
        let missing = makeCapability(
            id: CapabilityID.maxChargePowerWatts,
            nameZH: "最大充电功率",
            currentValue: .none,
            unit: "W",
            source: .none,
            readable: false,
            writable: true,
            unavailableReasonZH: "无最大充电功率键"
        )
        XCTAssertFalse(missing.readable)
        XCTAssertFalse(missing.writable)
        XCTAssertFalse(missing.allowsWritableSlider)
        XCTAssertEqual(missing.controlState, .unsupported)
        XCTAssertEqual(missing.currentValue, .none)
        XCTAssertNotNil(missing.unavailableReasonZH)
    }

    func testMaxChargePowerMutationCannotEnableWritableSlider() {
        var capability = makeCapability(
            id: CapabilityID.maxChargePowerWatts,
            readable: true,
            writable: false
        )
        capability.writable = true
        XCTAssertFalse(capability.writable)
        XCTAssertFalse(capability.allowsWritableSlider)
        XCTAssertEqual(capability.controlState, .readable)
    }

    func testBattUpperLimitPercentIsReadOnlyWhenPresent() {
        XCTAssertTrue(CapabilityID.forbidsWritableControl(CapabilityID.chargePercentLimitBatt))

        let limit = makeCapability(
            id: CapabilityID.chargePercentLimitBatt,
            nameZH: "batt 充电上限",
            currentValue: .number(80),
            unit: "%",
            source: .battStatusJSON,
            readable: true,
            writable: true,
            supportedRange: 50...100
        )
        XCTAssertTrue(limit.readable)
        XCTAssertFalse(limit.writable)
        XCTAssertFalse(limit.allowsWritableSlider)
        XCTAssertEqual(limit.controlState, .readable)
        XCTAssertEqual(limit.currentValue, .number(80))
        XCTAssertEqual(limit.source, .battStatusJSON)
        XCTAssertNotEqual(limit.controlState, .writable)
    }

    func testBattUpperLimitPercentUnsupportedWhenMissing() {
        let missing = makeCapability(
            id: CapabilityID.chargePercentLimitBatt,
            nameZH: "batt 充电上限",
            currentValue: .none,
            unit: "%",
            source: .none,
            readable: false,
            writable: true
        )
        XCTAssertFalse(missing.readable)
        XCTAssertFalse(missing.writable)
        XCTAssertEqual(missing.controlState, .unsupported)
        XCTAssertEqual(missing.currentValue, .none)
    }

    func testBattUpperLimitPercentMutationCannotEnableWrite() {
        var capability = makeCapability(
            id: CapabilityID.chargePercentLimitBatt,
            readable: true,
            writable: false
        )
        capability.writable = true
        capability.id = CapabilityID.chargePercentLimitBatt
        XCTAssertFalse(capability.writable)
        XCTAssertFalse(capability.allowsWritableSlider)
        XCTAssertEqual(capability.controlState, .readable)
    }

    func testIdChangeToForbiddenCapabilityDropsWritableSlider() {
        var capability = makeCapability(
            id: CapabilityID.cycleUpper,
            readable: true,
            writable: true,
            supportedRange: 50...100
        )
        XCTAssertTrue(capability.allowsWritableSlider)
        capability.id = CapabilityID.maxChargePowerWatts
        XCTAssertFalse(capability.writable)
        XCTAssertFalse(capability.allowsWritableSlider)
        XCTAssertEqual(capability.controlState, .readable)
    }

    func testCycleThresholdsRemainWritableSliders() {
        let upper = makeCapability(
            id: CapabilityID.cycleUpper,
            readable: true,
            writable: true,
            supportedRange: 50...100,
            risk: .medium
        )
        let lower = makeCapability(
            id: CapabilityID.cycleLower,
            readable: true,
            writable: true,
            supportedRange: 20...80,
            risk: .medium
        )
        XCTAssertFalse(CapabilityID.forbidsWritableControl(CapabilityID.cycleUpper))
        XCTAssertFalse(CapabilityID.forbidsWritableControl(CapabilityID.cycleLower))
        XCTAssertTrue(upper.writable)
        XCTAssertTrue(lower.writable)
        XCTAssertTrue(upper.allowsWritableSlider)
        XCTAssertTrue(lower.allowsWritableSlider)
        XCTAssertEqual(upper.controlState, .writable)
        XCTAssertEqual(lower.controlState, .writable)
        XCTAssertEqual(upper.source, .none)
    }

    func testAdapterDisableCanBeWritableWithConfirmation() {
        let disable = makeCapability(
            id: CapabilityID.adapterDisable,
            nameZH: "限时关闭电源适配器",
            currentValue: .text("true"),
            unit: "s",
            source: .battStatusJSON,
            readable: true,
            writable: true,
            supportedRange: 1...600,
            requiresConfirmation: true,
            risk: .high
        )
        XCTAssertTrue(disable.writable)
        XCTAssertTrue(disable.requiresConfirmation)
        XCTAssertEqual(disable.risk, .high)
        XCTAssertEqual(disable.supportedRange, 1...600)
        XCTAssertEqual(disable.controlState, .writable)
    }

    private func makeCapability(
        id: String = "x",
        nameZH: String = "测试",
        currentValue: CapabilityCurrentValue = .none,
        unit: String = "",
        source: CapabilitySource = .none,
        readable: Bool = false,
        writable: Bool = false,
        supportedRange: ClosedRange<Double>? = nil,
        requiresConfirmation: Bool = false,
        risk: CapabilityRisk = .low,
        unavailableReasonZH: String? = nil,
        noteZH: String? = nil
    ) -> Capability {
        Capability(
            id: id,
            nameZH: nameZH,
            currentValue: currentValue,
            unit: unit,
            source: source,
            readable: readable,
            writable: writable,
            supportedRange: supportedRange,
            requiresConfirmation: requiresConfirmation,
            risk: risk,
            unavailableReasonZH: unavailableReasonZH,
            noteZH: noteZH
        )
    }
}

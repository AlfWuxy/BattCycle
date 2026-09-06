import Foundation

/// 运行时能力清单。只根据快照与 doctor 探针组装，绝不把未验证写入标成可写。
public struct CapabilityInventory: Equatable, Sendable {
    public var capabilities: [Capability]

    public init(capabilities: [Capability]) {
        self.capabilities = capabilities
    }

    public func capability(id: String) -> Capability? {
        capabilities.first { $0.id == id }
    }

    public func controlState(for id: String) -> ControlState {
        guard let capability = capability(id: id) else {
            return .unsupported
        }
        return capability.controlState
    }

    /// 从帮助文本按选项词判断限时关闭：精确 `--for` / `--for=`，不含 `--force`。不执行写入。
    public static func timedDisableSupported(fromHelp helpText: String) -> Bool {
        TimedDisableHelp.supportsTimedDisable(helpText)
    }

    /// - Parameters:
    ///   - snapshot: `batt status --json` 解析结果；daemon 不可达时传 nil。
    ///   - battVersionOk: doctor 确认 Client 与 Daemon 都是 batt 0.8.0+；任一低于 0.8 则为 false。
    ///   - timedDisableSupported: 帮助文本按选项词含 `--for` / `--for=`（不含 `--force`）。
    ///   - daemonReachable: 能读到 daemon 状态。
    ///   - cycleUpperPercent / cycleLowerPercent: 本地 CycleConfig 当前值，本模块不解析 config.json。
    ///   - iokitMaxChargePowerWatts: 仅当调用方已从 IOKit 读到明确最大充电功率键时传入。
    public static func build(
        snapshot: BattStatusSnapshot?,
        battVersionOk: Bool,
        timedDisableSupported: Bool,
        daemonReachable: Bool,
        cycleUpperPercent: Int? = nil,
        cycleLowerPercent: Int? = nil,
        iokitMaxChargePowerWatts: Double? = nil
    ) -> CapabilityInventory {
        let defaults = CycleConfig()
        let cycleUpper = cycleUpperPercent ?? defaults.upperLimit
        let cycleLower = cycleLowerPercent ?? defaults.lowerLimit
        let adapterControl = snapshot?.adapterControl == true
        let allowNonRootAccess = snapshot?.allowNonRootAccess == true
        let localNote = "local BattCycle config, not batt limit"

        let capabilities: [Capability] = [
            cycleThreshold(
                id: CapabilityID.cycleUpper,
                nameZH: "循环充电上限",
                value: cycleUpper,
                range: 50...100,
                noteZH: localNote
            ),
            cycleThreshold(
                id: CapabilityID.cycleLower,
                nameZH: "循环放电下限",
                value: cycleLower,
                range: 20...80,
                noteZH: localNote
            ),
            chargePercentLimitBatt(snapshot: snapshot),
            maxChargePower(
                snapshot: snapshot,
                iokitMaxChargePowerWatts: iokitMaxChargePowerWatts
            ),
            adapterDisable(
                snapshot: snapshot,
                battVersionOk: battVersionOk,
                timedDisableSupported: timedDisableSupported,
                daemonReachable: daemonReachable,
                allowNonRootAccess: allowNonRootAccess,
                adapterControl: adapterControl
            ),
            adapterEnable(
                snapshot: snapshot,
                battVersionOk: battVersionOk,
                daemonReachable: daemonReachable,
                allowNonRootAccess: allowNonRootAccess,
                adapterControl: adapterControl
            )
        ]

        return CapabilityInventory(capabilities: capabilities)
    }

    private static func cycleThreshold(
        id: String,
        nameZH: String,
        value: Int,
        range: ClosedRange<Double>,
        noteZH: String
    ) -> Capability {
        Capability(
            id: id,
            nameZH: nameZH,
            currentValue: .number(Double(value)),
            unit: "%",
            source: .cycleConfig,
            readable: true,
            writable: true,
            supportedRange: range,
            requiresConfirmation: false,
            risk: .medium,
            unavailableReasonZH: nil,
            noteZH: noteZH
        )
    }

    private static func chargePercentLimitBatt(snapshot: BattStatusSnapshot?) -> Capability {
        let percent = snapshot?.upperLimitPercent
        let readable = percent != nil
        return Capability(
            id: CapabilityID.chargePercentLimitBatt,
            nameZH: "batt 充电上限",
            currentValue: percent.map { .number(Double($0)) } ?? .none,
            unit: "%",
            source: readable ? .battStatusJSON : .none,
            readable: readable,
            writable: false,
            supportedRange: nil,
            requiresConfirmation: false,
            risk: .low,
            unavailableReasonZH: readable
                ? nil
                : "batt JSON 无 configuration.upperLimitPercent（daemon 不可达或键缺失）",
            noteZH: "configuration.upperLimitPercent 只读，BattCycle 禁止写入 batt limit"
        )
    }

    private static func maxChargePower(
        snapshot: BattStatusSnapshot?,
        iokitMaxChargePowerWatts: Double?
    ) -> Capability {
        // batt CLI 无瓦数 setter：无论是否读到数值，writable 必须为 false。
        if let watts = snapshot?.maxChargePowerWatts {
            return Capability(
                id: CapabilityID.maxChargePowerWatts,
                nameZH: "最大充电功率",
                currentValue: .number(watts),
                unit: "W",
                source: .battStatusJSON,
                readable: true,
                writable: false,
                supportedRange: nil,
                requiresConfirmation: false,
                risk: .low,
                unavailableReasonZH: nil,
                noteZH: "只读；batt 无经验证的瓦数写入命令"
            )
        }
        if let watts = iokitMaxChargePowerWatts {
            return Capability(
                id: CapabilityID.maxChargePowerWatts,
                nameZH: "最大充电功率",
                currentValue: .number(watts),
                unit: "W",
                source: .iokit,
                readable: true,
                writable: false,
                supportedRange: nil,
                requiresConfirmation: false,
                risk: .low,
                unavailableReasonZH: nil,
                noteZH: "只读 IOKit 读数；batt 无瓦数 setter"
            )
        }
        return Capability(
            id: CapabilityID.maxChargePowerWatts,
            nameZH: "最大充电功率",
            currentValue: .none,
            unit: "W",
            source: .none,
            readable: false,
            writable: false,
            supportedRange: nil,
            requiresConfirmation: false,
            risk: .low,
            unavailableReasonZH: "batt CLI 无瓦数上限写入命令，且 JSON/IOKit 中无最大充电功率键",
            noteZH: nil
        )
    }

    /// 适配器写入公共门槛：版本、daemon、非 root 访问、adapterControl 必须全真。
    private static func adapterWritesAllowed(
        battVersionOk: Bool,
        daemonReachable: Bool,
        allowNonRootAccess: Bool,
        adapterControl: Bool
    ) -> Bool {
        battVersionOk && daemonReachable && allowNonRootAccess && adapterControl
    }

    private static func adapterDisable(
        snapshot: BattStatusSnapshot?,
        battVersionOk: Bool,
        timedDisableSupported: Bool,
        daemonReachable: Bool,
        allowNonRootAccess: Bool,
        adapterControl: Bool
    ) -> Capability {
        // 未接入时关闭无意义；enable/Restore 仍可能需要，故不在此拦截。
        let adapterUnplugged = snapshot?.pluggedIn == false
        let writable = adapterWritesAllowed(
            battVersionOk: battVersionOk,
            daemonReachable: daemonReachable,
            allowNonRootAccess: allowNonRootAccess,
            adapterControl: adapterControl
        ) && timedDisableSupported && !adapterUnplugged
        let readable = writable || snapshot?.useAdapter != nil
        let reasons = joinedReasons([
            daemonReachable ? nil : "batt daemon 不可达",
            allowNonRootAccess ? nil : "configuration.allowNonRootAccess 未确认为 true，非 root 无法确认适配器控制",
            adapterControl ? nil : "compatibility.adapterControl 未确认为 true，本机不支持或无法确认适配器控制",
            timedDisableSupported ? nil : "batt 帮助不含 --for，无法使用限时（1...600 秒）适配器关闭",
            battVersionOk ? nil : "batt Client 与 Daemon 版本未通过预检（需要 0.8.0+）",
            adapterUnplugged ? "适配器未连接" : nil
        ])
        return Capability(
            id: CapabilityID.adapterDisable,
            nameZH: "限时关闭电源适配器",
            currentValue: boolText(snapshot?.useAdapter),
            unit: "s",
            source: timedDisableSupported ? .battStatusJSON : .battHelp,
            readable: readable,
            writable: writable,
            supportedRange: 1...600,
            requiresConfirmation: true,
            risk: .high,
            unavailableReasonZH: writable ? nil : reasons,
            noteZH: "仅允许 timed --for（1...600 秒），禁止永久关闭"
        )
    }

    private static func adapterEnable(
        snapshot: BattStatusSnapshot?,
        battVersionOk: Bool,
        daemonReachable: Bool,
        allowNonRootAccess: Bool,
        adapterControl: Bool
    ) -> Capability {
        // 恢复/enable 不要求已接入：未插电时仍可能需要 enable 做恢复。
        let writable = adapterWritesAllowed(
            battVersionOk: battVersionOk,
            daemonReachable: daemonReachable,
            allowNonRootAccess: allowNonRootAccess,
            adapterControl: adapterControl
        )
        let readable = writable || snapshot?.useAdapter != nil
        let reasons = joinedReasons([
            daemonReachable ? nil : "batt daemon 不可达",
            allowNonRootAccess ? nil : "configuration.allowNonRootAccess 未确认为 true，非 root 无法确认适配器控制",
            adapterControl ? nil : "compatibility.adapterControl 未确认为 true，本机不支持或无法确认适配器控制",
            battVersionOk ? nil : "batt Client 与 Daemon 版本未通过预检（需要 0.8.0+）"
        ])
        return Capability(
            id: CapabilityID.adapterEnable,
            nameZH: "启用电源适配器",
            currentValue: boolText(snapshot?.useAdapter),
            unit: "",
            source: .battStatusJSON,
            readable: readable,
            writable: writable,
            supportedRange: nil,
            requiresConfirmation: false,
            risk: .medium,
            unavailableReasonZH: writable ? nil : reasons,
            noteZH: nil
        )
    }

    private static func boolText(_ value: Bool?) -> CapabilityCurrentValue {
        guard let value else { return .none }
        return .text(value ? "true" : "false")
    }

    private static func joinedReasons(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: "；")
    }
}

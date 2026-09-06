import Foundation

/// 单项运行时能力。
/// 字段：名称、当前值、范围、风险、确认、读写、来源。
/// writable 必须来自已验证命令；禁止把只读或缺失能力画成可操作控件。
/// 最大充电功率与 batt `upperLimitPercent` 只允许只读或不支持，永不可写滑块。
public struct Capability: Equatable, Sendable, Identifiable {
    public var id: String
    /// 名称（zh-Hans）。
    public var nameZH: String
    /// 当前值；缺失必须是 `.none`，禁止把缺失填成 0。
    public var currentValue: CapabilityCurrentValue
    public var unit: String
    /// 读数来源。
    public var source: CapabilitySource
    /// 是否可读。
    public var readable: Bool
    /// 写入许可。禁止写入的 id 永远为 false，即使调用方传入 true 或事后赋值。
    public var writable: Bool {
        get {
            allowsWritableSlider
        }
        set {
            writableRequested = CapabilityID.forbidsWritableControl(id) ? false : newValue
        }
    }
    /// 支持范围；无范围则为 nil。
    public var supportedRange: ClosedRange<Double>?
    /// 写入前是否需要确认。
    public var requiresConfirmation: Bool
    /// 风险等级。
    public var risk: CapabilityRisk
    public var unavailableReasonZH: String?
    /// 补充说明（例如循环上下限属于本地 CycleConfig，不是 batt limit）。
    public var noteZH: String?

    /// 调用方请求的写入标志；禁止写入的 id 在读写时被强制为 false。
    private var writableRequested: Bool

    public init(
        id: String,
        nameZH: String,
        currentValue: CapabilityCurrentValue,
        unit: String,
        source: CapabilitySource,
        readable: Bool,
        writable: Bool,
        supportedRange: ClosedRange<Double>?,
        requiresConfirmation: Bool,
        risk: CapabilityRisk,
        unavailableReasonZH: String?,
        noteZH: String? = nil
    ) {
        self.id = id
        self.nameZH = nameZH
        self.currentValue = currentValue
        self.unit = unit
        self.source = source
        self.readable = readable
        self.writableRequested = CapabilityID.forbidsWritableControl(id) ? false : writable
        self.supportedRange = supportedRange
        self.requiresConfirmation = requiresConfirmation
        self.risk = risk
        self.unavailableReasonZH = unavailableReasonZH
        self.noteZH = noteZH
    }

    /// 是否允许画成可写滑块/开关。最大充电功率与 batt 上限永远 false。
    public var allowsWritableSlider: Bool {
        !CapabilityID.forbidsWritableControl(id) && writableRequested
    }

    /// UI 控件状态：可写优先，其次只读，否则不支持。可写才允许启用滑块/开关。
    public var controlState: ControlState {
        BattCycleCore.controlState(self)
    }
}

/// 当前值：字符串或可选数字；缺失用 none，禁止把缺失填成 0。
public enum CapabilityCurrentValue: Equatable, Sendable {
    case none
    case text(String)
    case number(Double)
}

public enum CapabilitySource: String, Equatable, Sendable {
    case battStatusJSON
    case iokit
    case cycleConfig
    case battHelp
    case none
}

public enum CapabilityRisk: String, Equatable, Sendable {
    case low
    case medium
    case high
}

public enum ControlState: String, Equatable, Sendable {
    case readable
    case writable
    case unsupported
}

public enum CapabilityID {
    /// 最大充电功率：只读或 unsupported，禁止可写滑块。
    public static let maxChargePowerWatts = "maxChargePowerWatts"
    public static let adapterDisable = "adapterDisable"
    public static let adapterEnable = "adapterEnable"
    /// batt `configuration.upperLimitPercent`：只读，BattCycle 禁止写入 batt limit。
    public static let chargePercentLimitBatt = "chargePercentLimitBatt"
    public static let cycleUpper = "cycleUpper"
    public static let cycleLower = "cycleLower"

    /// 最大充电功率与 batt 充电上限禁止可写控件。
    public static func forbidsWritableControl(_ id: String) -> Bool {
        id == maxChargePowerWatts || id == chargePercentLimitBatt
    }
}

/// 供 UI 判断控件形态：writable → 可操作；readable → 只展示；否则隐藏或禁用并显示原因。
/// 禁止写入的能力即使 writable 请求为 true 也不得返回 `.writable`。
public func controlState(_ capability: Capability) -> ControlState {
    if capability.allowsWritableSlider {
        return .writable
    }
    if capability.readable {
        return .readable
    }
    return .unsupported
}

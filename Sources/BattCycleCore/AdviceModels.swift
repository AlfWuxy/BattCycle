import Foundation

/// 建议严重程度。仅用于只读展示，不触发任何硬件或引擎动作。
public enum AdviceSeverity: String, Equatable, Sendable {
    case info
    case warning
    case high
}

/// 建议规则标识。字符串稳定，便于去重与测试对照。
public enum AdviceRuleID: String, Equatable, Sendable, CaseIterable {
    case sustainedHighDischarge
    case dischargingWhileAdapterConnected
    case chargePowerWellBelowAdapterCapability
    case rapidDirectionChatter
    case thermalTooHigh
    case staleData
    case shortIntervalLongRetention
    case cycleLoadPlusHeat
    case adapterStateConflictsBatteryDirection
    case insufficientWattsSamples

    /// 面向 UI 的中文名称，避免直接展示 camelCase 的 `ruleId`。
    public var displayNameZH: String {
        switch self {
        case .sustainedHighDischarge:
            return "持续高放电"
        case .dischargingWhileAdapterConnected:
            return "接入适配器仍在放电"
        case .chargePowerWellBelowAdapterCapability:
            return "充电功率明显低于适配器能力"
        case .rapidDirectionChatter:
            return "充放电方向频繁翻转"
        case .thermalTooHigh:
            return "热状态偏高"
        case .staleData:
            return "数据过期"
        case .shortIntervalLongRetention:
            return "采样过密且保留过长"
        case .cycleLoadPlusHeat:
            return "放电负载叠加发热"
        case .adapterStateConflictsBatteryDirection:
            return "适配器状态与电池方向冲突"
        case .insufficientWattsSamples:
            return "有效功率样本不足"
        }
    }
}

/// 一条只读建议。所有中文文本必须可追溯到事实与规则，禁止声称修复健康或延长寿命。
public struct Advice: Equatable, Sendable, Identifiable {
    public var id: String
    public var severity: AdviceSeverity
    public var observedFactsZH: [String]
    public var timeRangeDescriptionZH: String
    /// 内部规则标识，仅供本模块去重与测试对照。UI 必须使用 `displayNameZH`，不得展示 camelCase。
    /// 测试通过 `@testable import BattCycleCore` 读取，不把本字段公开给 UI。
    internal var ruleId: String
    /// 面向 UI 的中文规则名。这是公开建议条目上必须存在的展示字段。
    public var displayNameZH: String
    public var ruleDescriptionZH: String
    /// 内部置信度，闭合区间 0...1。数据不足时引擎写入占位 0.2，UI 必须走 `displayedConfidence`。
    public var confidence: Double
    public var suggestedActionZH: String
    public var generatedAt: Date
    /// 为 true 时表示证据不足，文本应明确「数据不足」，不得编造结论。
    public var dataInsufficient: Bool

    /// 给 UI 的置信度。`dataInsufficient` 时为 `nil`（即使内部 `confidence` 是 0.2），其余返回 0...1。
    public var displayedConfidence: Double? {
        dataInsufficient ? nil : confidence
    }

    /// `displayNameZH` 为必填展示名。空字符串时按 `ruleId` 回填中文，避免漏传导致编译失败或画出 camelCase。
    public init(
        id: String,
        severity: AdviceSeverity,
        observedFactsZH: [String],
        timeRangeDescriptionZH: String,
        ruleId: String,
        ruleDescriptionZH: String,
        confidence: Double,
        suggestedActionZH: String,
        generatedAt: Date,
        dataInsufficient: Bool = false,
        displayNameZH: String
    ) {
        self.id = id
        self.severity = severity
        self.observedFactsZH = observedFactsZH
        self.timeRangeDescriptionZH = timeRangeDescriptionZH
        self.ruleId = ruleId
        self.ruleDescriptionZH = ruleDescriptionZH
        self.confidence = min(1, max(0, confidence))
        self.suggestedActionZH = suggestedActionZH
        self.generatedAt = generatedAt
        self.dataInsufficient = dataInsufficient
        if !displayNameZH.isEmpty {
            self.displayNameZH = displayNameZH
        } else if let rule = AdviceRuleID(rawValue: ruleId) {
            self.displayNameZH = rule.displayNameZH
        } else {
            // 未知规则也不回填 camelCase，避免 UI 把内部标识画出来。
            self.displayNameZH = "未知规则"
        }
    }
}

/// 一次评估：当前为真的建议，与仅用于去重记账的冷却抑制列表。
/// UI 只展示 `current`；冷却不会把仍为真的规则从 `current` 中拿掉。
public struct AdviceEvaluation: Equatable, Sendable {
    /// 条件此刻为真的建议。条件结束即从本数组消失，不做粘滞展示。
    public var current: [Advice]
    /// 当前仍为真、但处于冷却中、因此未记为一次新发出的 `ruleId`。
    public var suppressedByCooldown: [String]

    public init(current: [Advice], suppressedByCooldown: [String] = []) {
        self.current = current
        self.suppressedByCooldown = suppressedByCooldown
    }
}

/// 引擎自有的历史样本。刻意不依赖 HistoryStore，避免与并行实现抢类型。
public struct AdviceSample: Equatable, Sendable {
    /// Unix 时间戳（秒）。
    public var epoch: TimeInterval
    /// 功率（瓦）。负值放电，正值充电；缺失表示该点无功率读数。
    public var watts: Double?
    public var percent: Double?
    /// 充放电方向标签，例如 charging / discharging。
    public var direction: String
    public var pluggedIn: Bool?
    /// 调用方观测到的适配器使用标志；缺失表示未知，不得臆造。
    public var useAdapter: Bool?
    /// 热状态，例如 nominal / fair / serious / critical。
    public var thermal: String?
    /// 引擎阶段，例如 charging / discharging / idle。
    public var enginePhase: String?
    /// 睡眠唤醒后的显式间隙标记。为 true 时打断「持续」片段。
    public var sleepGap: Bool?

    public init(
        epoch: TimeInterval,
        watts: Double? = nil,
        percent: Double? = nil,
        direction: String,
        pluggedIn: Bool? = nil,
        useAdapter: Bool? = nil,
        thermal: String? = nil,
        enginePhase: String? = nil,
        sleepGap: Bool? = nil
    ) {
        self.epoch = epoch
        self.watts = watts
        self.percent = percent
        self.direction = direction
        self.pluggedIn = pluggedIn
        self.useAdapter = useAdapter
        self.thermal = thermal
        self.enginePhase = enginePhase
        self.sleepGap = sleepGap
    }
}

/// 一次评估的输入窗口。`adapterRatedMaxWatts` 为 nil 时跳过额定功率对比，不编造数值。
public struct AdviceContext: Equatable, Sendable {
    public var samples: [AdviceSample]
    public var historyIntervalSeconds: TimeInterval
    public var recordingPaused: Bool
    /// 声明的样本总量，可能大于本次窗口 `samples.count`。
    public var sampleCount: Int
    public var retentionDays: Int
    public var adapterRatedMaxWatts: Double?

    public init(
        samples: [AdviceSample],
        historyIntervalSeconds: TimeInterval,
        recordingPaused: Bool = false,
        sampleCount: Int? = nil,
        retentionDays: Int = 30,
        adapterRatedMaxWatts: Double? = nil
    ) {
        self.samples = samples
        self.historyIntervalSeconds = historyIntervalSeconds
        self.recordingPaused = recordingPaused
        self.sampleCount = sampleCount ?? samples.count
        self.retentionDays = retentionDays
        self.adapterRatedMaxWatts = adapterRatedMaxWatts
    }
}

/// 内存中的规则发出记账。`lastEmitAtByRuleId` 只抑制重复「发出」记录，不决定条件是否仍为真。
public struct AdviceDeduper: Equatable, Sendable {
    /// 各 `ruleId` 最近一次记为新发出的时刻。
    public var lastEmitAtByRuleId: [String: Date]

    public init(lastEmitAtByRuleId: [String: Date] = [:]) {
        self.lastEmitAtByRuleId = lastEmitAtByRuleId
    }

    public init(previous: [Advice]) {
        var map: [String: Date] = [:]
        for item in previous {
            if let existing = map[item.ruleId] {
                map[item.ruleId] = max(existing, item.generatedAt)
            } else {
                map[item.ruleId] = item.generatedAt
            }
        }
        self.lastEmitAtByRuleId = map
    }

    public func isCoolingDown(ruleId: String, now: Date, cooldown: TimeInterval) -> Bool {
        guard cooldown > 0, let last = lastEmitAtByRuleId[ruleId] else { return false }
        return now.timeIntervalSince(last) < cooldown
    }

    public mutating func record(_ advice: Advice) {
        lastEmitAtByRuleId[advice.ruleId] = advice.generatedAt
    }
}

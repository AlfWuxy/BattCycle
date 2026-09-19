import BattCycleCore
import SwiftUI

/// 指标展示文案。缺测只显示「设备未提供」或「当前不可用」，禁止用 0 / 「否」冒充已测量。
enum MetricDisplay {
    static func sourceZH(_ source: MetricSource) -> String {
        switch source {
        case .iokit: return "IOKit"
        case .batt: return "batt"
        case .processInfo: return "系统"
        case .derived: return "推导"
        case .unavailable: return "—"
        }
    }

    /// 缺测占位。`.available` 返回空串，由 `unavailableText` 再落到「当前不可用」，以免把空值当成已测。
    static func placeholder(_ availability: MetricAvailability) -> String {
        switch availability {
        case .available:
            return ""
        case .deviceDidNotProvide:
            return "设备未提供"
        case .currentlyUnavailable, .unsupported:
            return "当前不可用"
        }
    }

    /// 界面缺测文案：设备未提供该键 → 「设备未提供」，其余不可用情况 → 「当前不可用」。
    static func unavailableText(_ availability: MetricAvailability) -> String {
        let text = placeholder(availability)
        return text.isEmpty ? "当前不可用" : text
    }

    /// 缺测占位文案。已测「否」不在此列。
    static func isMissingPlaceholder(_ text: String) -> Bool {
        text == "设备未提供" || text == "当前不可用"
    }

    /// 已测布尔才用「是 / 否」。缺测不得调用本函数，否则 false 会被写成「否」。
    static func boolZH(_ value: Bool) -> String {
        value ? "是" : "否"
    }

    /// 布尔缺测（nil / 非 available）返回占位，绝不把兼容字段的 false 显示成「否」。
    static func boolZH(_ value: Bool?, availability: MetricAvailability) -> String {
        displayedValue(value, availability: availability, format: boolZH)
    }

    static func wattsZH(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static func numberZH(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }

    static func capabilityValueZH(_ value: CapabilityCurrentValue) -> String {
        switch value {
        case .none:
            return "当前不可用"
        case .text(let text):
            return text.isEmpty ? "当前不可用" : text
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return numberZH(number)
        }
    }

    static func sourceZH(_ source: CapabilitySource) -> String {
        switch source {
        case .battStatusJSON: return "batt"
        case .iokit: return "IOKit"
        case .cycleConfig: return "循环配置"
        case .battHelp: return "batt 帮助"
        case .none: return "—"
        }
    }

    /// 只有 `.trusted` 显示「可信」；过期 / 不可用 / 冲突 / 未知一律不得写成可信。
    static func trustZH(_ trust: DataTrust) -> String {
        switch trust {
        case .trusted:
            return "可信"
        case .stale:
            return "过期"
        case .conflicting:
            return "冲突"
        case .unavailable:
            return "不可用"
        @unknown default:
            return "不可用"
        }
    }

    static func bytesZH(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        if bytes < 1_024 * 1_024 {
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        }
        return String(format: "%.1f MB", Double(bytes) / 1_024 / 1_024)
    }

    static func durationZH(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分钟"
        }
        return "\(total) 秒"
    }

    /// 已测且 format 非空才展示数值；否则占位，不填 0、不把缺布尔显示成「否」。
    static func displayedValue<Value>(
        _ value: Value?,
        availability: MetricAvailability,
        format: (Value) -> String
    ) -> String {
        if isMeasured(value, availability: availability), let value {
            let text = format(value)
            if !text.isEmpty, !isMissingPlaceholder(text) {
                return text
            }
        }
        return unavailableText(availability)
    }

    static func isMeasured<Value>(_ value: Value?, availability: MetricAvailability) -> Bool {
        availability == .available && value != nil
    }
}

/// 只读指标行。`availability != .available` 或 value 为 nil 时只显示缺测占位。
struct MetricRow: View {
    let name: String
    let valueText: String?
    let unit: String
    let sourceText: String
    let availability: MetricAvailability

    /// 已测才展示 format 结果；缺测或占位文案不得当成已测（避免「否」冒充未提供的布尔）。
    private var hasMeasuredValue: Bool {
        guard availability == .available, let valueText, !valueText.isEmpty else {
            return false
        }
        return !MetricDisplay.isMissingPlaceholder(valueText)
    }

    private var shownValue: String {
        if hasMeasuredValue, let valueText {
            return valueText
        }
        return MetricDisplay.unavailableText(availability)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text("来源 \(sourceText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(shownValue)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(hasMeasuredValue ? Color.primary : Color.secondary)
                if hasMeasuredValue, !unit.isEmpty {
                    Text(unit)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [name, shownValue]
        if hasMeasuredValue, !unit.isEmpty {
            parts.append(unit)
        }
        parts.append("来源 \(sourceText)")
        return parts.joined(separator: "，")
    }
}

extension MetricRow {
    /// 仅在 availability == .available 且 value 非 nil 时格式化；缺测不调用 format，因此缺布尔不会变成「否」。
    init<Value>(
        metric: MetricValue<Value>,
        name nameOverride: String? = nil,
        availability availabilityOverride: MetricAvailability? = nil,
        format: (Value) -> String
    ) {
        let availability = availabilityOverride ?? metric.availability
        let text: String?
        if MetricDisplay.isMeasured(metric.value, availability: availability), let value = metric.value {
            let formatted = format(value)
            text = (formatted.isEmpty || MetricDisplay.isMissingPlaceholder(formatted)) ? nil : formatted
        } else {
            text = nil
        }
        self.init(
            name: nameOverride ?? metric.displayNameZH,
            valueText: text,
            unit: metric.unit,
            sourceText: MetricDisplay.sourceZH(metric.source),
            availability: availability
        )
    }

    /// 布尔专用入口。缺测（nil / 非 available）只显示「设备未提供」或「当前不可用」，绝不显示「否」。
    init(
        boolMetric metric: MetricValue<Bool>,
        name nameOverride: String? = nil,
        availability availabilityOverride: MetricAvailability? = nil
    ) {
        self.init(
            metric: metric,
            name: nameOverride,
            availability: availabilityOverride,
            format: MetricDisplay.boolZH
        )
    }
}

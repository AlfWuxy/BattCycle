import BattCycleCore
import SwiftUI

/// P3.17 建议页：只读展示 `AdviceEngine.evaluate` 的 `current`。
/// 不展示 raw `ruleId`，数据不足走 `displayedConfidence == nil`，且绝不下发适配器命令。
struct AdviceView: View {
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        DashboardForm {
            // 只读声明：本页根据本地历史触发文案，不得暗示会改硬件或引擎状态。
            DashboardSection {
                Text("建议只根据本地历史观测生成，不会操作适配器、不会启动或停止循环，也不会改写 batt 上限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("以下为当前上下文命中的规则；条件结束后从本页消失，不会粘滞保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if currentAdvice.isEmpty {
                // 空列表：无历史为「数据不足」，有历史但当前无命中为「暂无建议」。
                DashboardSection {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(currentAdvice) { item in
                    DashboardSection(severityTitle(item.severity)) {
                        ruleBlock(item)
                        descriptionBlock(item)
                        confidenceBlock(item)
                        LabeledContent("时间范围") {
                            Text(item.timeRangeDescriptionZH)
                        }
                        LabeledContent("评估时间") {
                            Text(AdviceView.timeFormatter.string(from: item.generatedAt))
                                .monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("事实")
                            if item.observedFactsZH.isEmpty {
                                Text("暂无已观测事实")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array(item.observedFactsZH.enumerated()), id: \.offset) { _, fact in
                                    Text("• \(fact)")
                                }
                            }
                        }
                        Text(item.suggestedActionZH)
                        if item.dataInsufficient {
                            Text("数据不足，未编造功率结论。")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    /// 当前建议 = `f(context)`。视图不缓存、不合并历史条目，只读引擎最近一次 `evaluate` 的 `current`。
    private var currentAdvice: [Advice] {
        engine.advice
    }

    /// 规则标题只用 `displayNameZH`；空名或 camelCase 标识符一律显示「未知规则」。
    private func ruleBlock(_ item: Advice) -> some View {
        let text = ruleDisplayName(item)
        return VStack(alignment: .leading, spacing: 4) {
            Text("规则")
                .foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("规则，\(text)")
    }

    /// 规则说明是中文描述，不是 camelCase 标识符。
    @ViewBuilder
    private func descriptionBlock(_ item: Advice) -> some View {
        let description = item.ruleDescriptionZH.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = ruleDisplayName(item)
        if !description.isEmpty, description != title {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// `displayedConfidence == nil`（含 dataInsufficient）时不画百分比，避免把占位值显示成 100%。
    @ViewBuilder
    private func confidenceBlock(_ item: Advice) -> some View {
        if let confidence = item.displayedConfidence {
            LabeledContent("置信度") {
                Text(String(format: "%.0f%%", confidence * 100))
                    .monospacedDigit()
            }
        } else {
            LabeledContent("置信度") {
                Text("数据不足")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("置信度，数据不足")
        }
    }

    private var emptyText: String {
        if engine.historySampleCount == 0 {
            return "数据不足"
        }
        return "暂无建议"
    }

    /// 面向用户的规则名。只读 `displayNameZH`，不访问、不比对内部 ruleId。
    private func ruleDisplayName(_ item: Advice) -> String {
        let name = item.displayNameZH.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || looksLikeCamelCaseId(name) {
            return "未知规则"
        }
        return name
    }

    /// 识别 `insufficientWattsSamples` 这类 camelCase 标识符，避免当标题画出。
    private func looksLikeCamelCaseId(_ text: String) -> Bool {
        let pattern = #"^[a-z]+(?:[A-Z][A-Za-z0-9]*)+$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func severityTitle(_ severity: AdviceSeverity) -> String {
        switch severity {
        case .info: return "信息"
        case .warning: return "警告"
        case .high: return "高"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

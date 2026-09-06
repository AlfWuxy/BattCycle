import BattCycleCore
import SwiftUI

/// 概览中心的能量流向。减弱动态效果时只用静态图标，不用粒子。
/// 充电：插头 → 电池。放电：电池 → Mac，绝不指向墙上插头（不是回馈电网）。
/// 缺测或不可用必须显示 unknown，禁止把捕获失败的 0W 画成放电。
/// 本视图不标注适配器瓦数；电池侧功率由概览的「电池净功率」行负责。
struct EnergyFlowView: View {
    /// 显式快照优先；否则用引擎当前快照做 Core 分类。
    private let incomingSnapshot: BatterySnapshot?

    @EnvironmentObject private var engine: EngineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardSnapshotPreview) private var snapshotPreview

    /// `flow` 仅保持 `EnergyFlowView(flow:)` 调用点兼容；展示以快照分类为准。
    init(flow: EnergyFlow, snapshot: BatterySnapshot? = nil) {
        incomingSnapshot = snapshot
        _ = flow
    }

    /// 仅有快照时由 `classifiedEnergyFlow()` / `EnergyFlow.classify` 决定方向。
    init(snapshot: BatterySnapshot) {
        incomingSnapshot = snapshot
    }

    /// 有快照则走 `classifiedEnergyFlow()`（内部仍是 `EnergyFlow.classify`）。
    /// empty / 缺瓦数的分类是 unknown，不会把假放电画出来。
    private var flow: EnergyFlow {
        Self.classified(incomingSnapshot ?? engine.snapshot)
    }

    var body: some View {
        Group {
            if usesMotion {
                TimelineView(.animation(minimumInterval: 0.12, paused: false)) { timeline in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6)
                    layout(phase: cycle / 1.6)
                }
            } else {
                layout(phase: 0)
            }
        }
        .frame(minHeight: 88)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flow.accessibilityLabel)
    }

    /// 仅充放电画廉价位移；待机/未知或减弱动态效果时保持静态。
    private var usesMotion: Bool {
        !snapshotPreview && !reduceMotion && (flow.direction == .charging || flow.direction == .discharging)
    }

    private func layout(phase: Double) -> some View {
        HStack(spacing: 16) {
            diagram(phase: phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(flow.labelZH)
                    .font(.headline)
                    .foregroundStyle(flowColor)
                Text(directionCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func diagram(phase: Double) -> some View {
        HStack(spacing: 12) {
            switch flow.direction {
            case .charging:
                // 适配器/插头 → 电池
                node("powerplug.fill")
                flowingArrow(phase: phase)
                node("battery.100", prominent: true)
            case .discharging:
                // 电池 → Mac/系统负载；布局里不出现插头，避免看起来像回馈墙插
                node("battery.100", prominent: true)
                flowingArrow(phase: phase)
                node("laptopcomputer", prominent: true)
            case .idle:
                // 明确暂停，不画方向箭头
                node(flow.symbolName, prominent: true)
            case .unknown:
                // 不声称任何流向，也不用放电图冒充
                node(flow.symbolName, prominent: true)
            }
        }
    }

    private func node(_ systemName: String, prominent: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(prominent ? .largeTitle : .title2)
            .foregroundStyle(prominent ? flowColor : Color.secondary)
            .frame(width: 64, height: 64)
            .background(flowColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityHidden(true)
    }

    /// 箭头始终向右指向当前布局的终点：充电指向电池，放电指向笔记本。
    private func flowingArrow(phase: Double) -> some View {
        let offset = reduceMotion ? 0 : CGFloat((phase - 0.5) * 8)
        let opacity = reduceMotion ? 1 : 0.45 + 0.55 * abs(phase - 0.5) * 2
        return Image(systemName: "arrow.right")
            .font(.title2.weight(.semibold))
            .foregroundStyle(flowColor)
            .offset(x: offset)
            .opacity(opacity)
            .accessibilityHidden(true)
    }

    private var flowColor: Color {
        switch flow.direction {
        case .charging: return .green
        case .discharging: return .orange
        case .idle, .unknown: return .secondary
        }
    }

    /// 只描述方向，不写适配器瓦数或电池瓦数。
    private var directionCaption: String {
        switch flow.direction {
        case .charging: return "适配器流向电池"
        case .discharging: return "电池供给系统负载"
        case .idle: return "能量未流动"
        case .unknown: return "数据不可用"
        }
    }

    /// 优先 `classifiedEnergyFlow()`（缺 `IsCharging` 不当成真充电）；其内部调用 `EnergyFlow.classify`。
    private static func classified(_ snapshot: BatterySnapshot) -> EnergyFlow {
        snapshot.classifiedEnergyFlow()
    }
}

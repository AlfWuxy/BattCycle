import BattCycleCore
import SwiftUI

/// 概览：能量流向、电量、电池净功率（不是适配器瓦数）、适配器物理连接 / 系统使用适配器 / 正在充电分列。
struct OverviewView: View {
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        DashboardForm {
            SurfaceCard {
                VStack(alignment: .leading, spacing: 24) {
                    Text("当前电量").font(.callout).foregroundStyle(.secondary)
                    heroPercent
                    Divider()
                    EnergyFlowView(flow: engine.flow)
                }
            }
            DashboardSection("电池与供电") {
                MetricRow(metric: engine.metrics.batteryPercent) { "\($0)" }
                MetricRow(metric: engine.metrics.batteryNetPowerWatts, name: "电池净功率", format: MetricDisplay.wattsZH)
                MetricRow(boolMetric: engine.metrics.adapterPhysicallyConnected, name: "适配器物理连接")
                MetricRow(boolMetric: engine.metrics.systemUsingAdapter, name: "系统正在使用适配器", availability: engine.snapshot.externalConnectedAvailability)
                MetricRow(boolMetric: engine.metrics.isCharging, name: "正在充电", availability: engine.snapshot.isChargingAvailability)
            }
            DashboardSection("功率与充电能力") {
                MetricRow(metric: engine.metrics.adapterOutputWatts, format: MetricDisplay.wattsZH)
                MetricRow(metric: engine.metrics.adapterRatedMaxWatts, format: MetricDisplay.wattsZH)
                MetricRow(metric: engine.metrics.adapterNegotiatedWatts, format: MetricDisplay.wattsZH)
                MetricRow(metric: engine.metrics.systemPowerWatts, format: MetricDisplay.wattsZH)
                MetricRow(metric: engine.metrics.chargePercentLimit) { "\($0)" }
                MetricRow(metric: engine.metrics.chargePowerLimitWatts, format: MetricDisplay.wattsZH)
            }
            DashboardSection("采样与可信度") {
                labeledRow("最近采样", value: formatDate(engine.lastSampleAt))
                labeledRow("下次采样", value: nextSampleText)
                labeledRow("热状态", value: engine.thermalMessage)
                labeledRow("引擎阶段", value: engine.phaseLabel)
                trustBadge
            }
        }
    }

    private var heroPercent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if engine.snapshot.percentIsAvailable {
                    Text("\(engine.snapshot.percent)%")
                        .font(.system(size: 60, weight: .medium, design: .rounded))
                        .monospacedDigit()
                } else {
                    Text(MetricDisplay.unavailableText(engine.snapshot.percentReading.availability))
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(percentAccessibility)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: engine.flow.symbolName)
                    Text(engine.flow.labelZH)
                        .font(.headline)
                }
                .foregroundStyle(flowColor)
                Text(engine.phaseLabel)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }

    /// 过期 / 不可用 / 冲突不得显示「可信」。缺键或充电/功率冲突时，即使控制器标成 trusted 也降级。
    private var displayedTrust: DataTrust {
        let snapshot = engine.snapshot
        if !snapshot.isCompleteForDataTrust {
            return engine.trust == .stale ? .stale : .unavailable
        }
        if DataTrustEvaluator.isConflicting(snapshot) {
            return .conflicting
        }
        switch engine.trust {
        case .trusted:
            return .trusted
        case .stale:
            return .stale
        case .unavailable:
            return .unavailable
        case .conflicting:
            return .conflicting
        @unknown default:
            return .unavailable
        }
    }

    private var trustBadge: some View {
        let trust = displayedTrust
        let label = MetricDisplay.trustZH(trust)
        return HStack {
            Text("数据可信度")
            Spacer()
            Text(label)
                .font(.body.weight(.medium))
                .foregroundStyle(trustColor(trust))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(trustColor(trust).opacity(0.12), in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("数据可信度，\(label)")
    }

    private func labeledRow(_ name: String, value: String) -> some View {
        let shown = statusOrUnavailable(value)
        return HStack {
            Text(name)
            Spacer()
            Text(shown)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)，\(shown)")
    }

    /// 空串不当成已测状态，避免空白行冒充有效读数。
    private func statusOrUnavailable(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前不可用" : text
    }

    private var nextSampleText: String {
        if engine.monitorSettings.recordingPaused {
            return "记录已暂停"
        }
        return formatDate(engine.nextHistorySampleAt)
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "当前不可用" }
        return OverviewView.timeFormatter.string(from: date)
    }

    private var percentAccessibility: String {
        if engine.snapshot.percentIsAvailable {
            return "电池电量 \(engine.snapshot.percent) 百分比，\(engine.flow.accessibilityLabel)"
        }
        let placeholder = MetricDisplay.unavailableText(engine.snapshot.percentReading.availability)
        return "电池电量 \(placeholder)，\(engine.flow.accessibilityLabel)"
    }

    private var flowColor: Color {
        switch engine.flow.direction {
        case .charging: return .green
        case .discharging: return .orange
        case .idle, .unknown: return .secondary
        }
    }

    private func trustColor(_ trust: DataTrust) -> Color {
        switch trust {
        case .trusted: return .green
        case .stale: return .orange
        case .unavailable: return .secondary
        case .conflicting: return .red
        @unknown default: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

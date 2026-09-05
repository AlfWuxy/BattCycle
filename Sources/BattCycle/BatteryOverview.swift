import BattCycleCore
import SwiftUI

struct BatteryOverview: View {
    @EnvironmentObject private var engine: EngineController
    let editPlan: () -> Void

    private var hasReading: Bool { engine.snapshot.capturedAt != .distantPast }
    private var lower: Int { engine.isRunning ? engine.engine.lower : engine.config.lowerLimit }
    private var upper: Int { engine.isRunning ? engine.engine.upper : engine.config.upperLimit }
    private var stopDate: Date {
        engine.isRunning ? Date(timeIntervalSince1970: TimeInterval(engine.engine.stopAtEpoch)) : engine.config.stopDate
    }

    var body: some View {
        VStack(spacing: 18) {
            batteryCard
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    rangeCard.frame(minWidth: 230)
                    scheduleCard.frame(minWidth: 230)
                }
                VStack(spacing: 16) {
                    rangeCard
                    scheduleCard
                }
            }
            EnvironmentView()
            NoticeView(
                title: "请在有人照看时运行",
                message: "这是主动充放电测试工具，会施加 CPU 与 GPU 负载并消耗电池循环。保持 MacBook 开盖、通风，随时留意热状态。",
                symbol: "exclamationmark.triangle"
            )
        }
    }

    private var batteryCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前电量").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(hasReading ? "\(engine.snapshot.percent)" : "—")
                                .font(.system(size: 60, weight: .light, design: .rounded))
                                .monospacedDigit()
                            if hasReading {
                                Text("%")
                                    .font(.system(size: 26, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("当前电量")
                        .accessibilityValue(hasReading ? "百分之\(engine.snapshot.percent)" : "暂无读数")
                        Text(hasReading ? engine.snapshot.drawingFrom : "暂无内置电池读数")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    BatteryGlyph(percent: hasReading ? engine.snapshot.percent : nil, charging: engine.snapshot.isCharging)
                }
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    metric(title: "电池侧功率", value: powerText, symbol: "bolt", color: .primary)
                    Divider()
                    metric(title: "循环阶段", value: engine.phaseLabel, symbol: "arrow.triangle.2.circlepath", color: engine.isRunning ? .orange : .primary)
                }
                .fixedSize(horizontal: false, vertical: true)
                if !hasReading || engine.snapshot.watts == 0 {
                    Text("“—”表示暂无可确认读数；不能据此判断电量或适配器状态。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var powerText: String {
        // 底层的零值也可能表示读取失败，界面不把它当作已确认的零功率。
        guard hasReading, engine.snapshot.watts != 0, engine.snapshot.watts.isFinite else { return "—" }
        return String(format: "%+.1f W", engine.snapshot.watts)
    }

    private func metric(title: String, value: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(color).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Label("循环区间", systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("调整", action: editPlan).buttonStyle(.plain).foregroundStyle(.tint)
                        .accessibilityLabel("调整循环计划")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(lower)%").foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 15, weight: .medium)).foregroundStyle(.tertiary)
                    Text("\(upper)%")
                }
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit()
                ChargeRangeBar(lower: lower, upper: upper)
            }
        }
    }

    private var scheduleCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 17) {
                Label("定时停止", systemImage: "clock")
                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text(stopDate, style: .time)
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 5) {
                    Text(stopDate, format: .dateTime.month().day())
                    Text("· 最长 24 小时")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 20)
            }
        }
    }
}

private struct BatteryGlyph: View {
    let percent: Int?
    let charging: Bool

    private var color: Color { (percent ?? 100) <= 20 ? .orange : .green }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 3)
                if let percent {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(color.gradient)
                        .frame(width: max(4, 134 * CGFloat(percent) / 100))
                        .padding(8)
                }
                if percent == nil || charging {
                    Image(systemName: percent == nil ? "questionmark" : "bolt.fill")
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.45))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 150, height: 78)
            RoundedRectangle(cornerRadius: 3)
                .fill(.primary.opacity(0.15))
                .frame(width: 6, height: 25)
        }
        .accessibilityHidden(true)
    }
}

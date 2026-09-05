import BattCycleCore
import SwiftUI

struct CyclePlanView: View {
    @EnvironmentObject private var engine: EngineController
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 18) {
            if engine.isRunning {
                NoticeView(title: "循环正在运行", message: "停止后可编辑下一次计划。当前运行区间与停止时间请查看电池概览。", symbol: "info.circle", color: .blue)
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeading(title: "充放电区间", subtitle: "充至上限后施加负载，降至下限后恢复适配器。", symbol: "battery.75percent")
                    HStack(spacing: 22) {
                        threshold("下限", value: $engine.config.lowerLimit, range: 20...80)
                        Image(systemName: "arrow.left.arrow.right").foregroundStyle(.tertiary)
                        threshold("上限", value: $engine.config.upperLimit, range: 50...100)
                    }
                    ChargeRangeBar(lower: engine.config.lowerLimit, upper: engine.config.upperLimit)
                    if engine.config.upperLimit - engine.config.lowerLimit < 5 {
                        Label("上下限之间至少保留 5% 的间隔。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.red)
                    } else {
                        Text("默认 30%–80%，上下限至少间隔 5%。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "定时停止", subtitle: "到时结束负载并恢复适配器。单次最长 24 小时。", symbol: "clock")
                    DatePicker(
                        "停止时间",
                        selection: Binding(get: { engine.config.stopDate }, set: { engine.config.stopDate = $0 }),
                        in: Date()...Date().addingTimeInterval(86_400),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.field)
                    .controlSize(.large)
                    Button { engine.config.stopDate = CycleConfig.nextOccurrence(hour: 7, minute: 0) } label: {
                        Label("设为下一次 07:00", systemImage: "sunrise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            SurfaceCard {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 18) {
                        Divider()
                        Picker("GPU 矩阵", selection: $engine.config.gpuSize) {
                            Text("2048 · 默认").tag(2048)
                            Text("4096").tag(4096)
                            Text("8192").tag(8192)
                        }
                        Stepper(value: $engine.config.cpuJobs, in: 1...16) {
                            settingLabel("CPU 线程", value: "\(engine.config.cpuJobs)")
                        }
                        Stepper(value: $engine.config.pollSeconds, in: 5...60, step: 5) {
                            settingLabel("轮询间隔", value: "\(engine.config.pollSeconds) 秒")
                        }
                        Text("更高负载会增加热量与能耗。请仅在明确实验需要时调整。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 16)
                } label: {
                    SectionHeading(title: "负载与轮询", subtitle: "CPU、GPU 与轮询间隔", symbol: "cpu")
                }
            }
        }
        .disabled(engine.isRunning || engine.busy)
    }

    private func threshold(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)%")
                    .font(.system(size: 28, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .accessibilityLabel("循环\(title)")
            .accessibilityValue("百分之\(value.wrappedValue)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

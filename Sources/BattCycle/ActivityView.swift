import SwiftUI

struct EnvironmentView: View {
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: engine.environmentReady ? "checkmark.shield" : "wrench.and.screwdriver")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(engine.environmentReady ? .green : .secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(engine.environmentChecking ? "正在检查环境" : (engine.environmentReady ? "运行环境已就绪" : "运行环境待就绪"))
                            .font(.headline)
                        Text(engine.environmentMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button { engine.checkEnvironment() } label: {
                        Label("重新检查", systemImage: "arrow.clockwise")
                    }
                    .disabled(engine.environmentChecking || engine.busy)
                    .help("检查 batt、stress-ng、MLX 与运行所需脚本")
                }
                Divider()
                Label(engine.thermalMessage, systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(engine.thermalSafe ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var engine: EngineController

    var body: some View {
        VStack(spacing: 18) {
            EnvironmentView()
            SurfaceCard {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "本次运行", subtitle: "以下状态来自循环引擎的最近一次记录。", symbol: "waveform.path.ecg")
                    statusRow("循环阶段", value: engine.phaseLabel)
                    Divider()
                    statusRow("引擎状态", value: engine.isRunning ? "正在运行" : "未在运行")
                    Divider()
                    statusRow("最近记录", value: engine.engine.updatedAt.isEmpty ? "暂无运行记录" : engine.engine.updatedAt)
                }
            }
            SurfaceCard {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "运行日志", subtitle: "查看完整的充放电过程、停止请求与适配器恢复结果。", symbol: "doc.text.magnifyingglass")
                    Button { engine.openLog() } label: {
                        Label("打开日志", systemImage: "arrow.up.forward.square")
                    }
                    .controlSize(.large)
                    Text("日志仅保存在本机 Library 目录中。没有运行日志时，将打开日志文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NoticeView(title: "恢复结果以验证反馈为准", message: "需要重新开启适配器时，使用底部的“恢复适配器”。界面上的电量与功率读数不代表恢复操作已经完成。", symbol: "powerplug", color: .blue)
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

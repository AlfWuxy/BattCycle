import AppKit
import BattCycleCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: EngineController
    @State private var showingStartConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            safetyNotice
            environment
            Divider()
            limits
            Divider()
            schedule
            Divider()
            advanced
            messages
            actions
            footer
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 510, minHeight: 700)
        .confirmationDialog(
            "确认开始电池循环？",
            isPresented: $showingStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认开始", role: .destructive) {
                engine.start()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将主动切断适配器并运行 CPU 与 GPU 压测。请保持 MacBook 开盖、通风，并留意温度。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BattCycle")
                    .font(.title.weight(.semibold))
                Spacer()
                Text(engine.isRunning ? "运行中" : "已停止")
                    .font(.headline)
                    .foregroundStyle(engine.isRunning ? Color.orange : Color.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(engine.snapshot.percent)%")
                    .font(.system(size: 44, weight: .medium, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(engine.phaseLabel)
                    Text("\(engine.snapshot.drawingFrom)  ·  \(engine.snapshot.watts, specifier: "%+.1f") W")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "这是 Mac 专用的主动充放电测试工具。运行期间会产生明显负载与热量，请保持开盖和通风。",
                systemImage: "exclamationmark.triangle.fill"
            )
            Text(engine.thermalMessage)
                .foregroundStyle(engine.thermalSafe ? Color.secondary : Color.red)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var environment: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: engine.environmentReady ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill")
                .foregroundStyle(engine.environmentReady ? Color.green : Color.secondary)
            Text(engine.environmentMessage)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(engine.environmentChecking ? "检查中…" : "重新检查") {
                engine.checkEnvironment()
            }
            .disabled(engine.environmentChecking || engine.busy)
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("循环区间")
                .font(.headline)
            HStack {
                Text("上限")
                Spacer()
                Stepper(value: $engine.config.upperLimit, in: 50...100) {
                    Text("\(engine.config.upperLimit)%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Text("下限")
                Spacer()
                Stepper(value: $engine.config.lowerLimit, in: 20...80) {
                    Text("\(engine.config.lowerLimit)%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            Text("到上限后暂时关闭适配器并施加负载，到下限后恢复适配器。默认区间为 80% 到 30%。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("定时停止")
                .font(.headline)
            DatePicker(
                "停止时间",
                selection: Binding(
                    get: { engine.config.stopDate },
                    set: { engine.config.stopDate = $0 }
                ),
                in: Date()...Date().addingTimeInterval(86_400),
                displayedComponents: [.date, .hourAndMinute]
            )
            Button("设为下一次 07:00") {
                engine.config.stopDate = CycleConfig.nextOccurrence(hour: 7, minute: 0)
            }
            .buttonStyle(.borderless)
            Text("单次运行最长 24 小时。关闭窗口不会停止引擎，可用菜单栏的 Stop。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advanced: some View {
        DisclosureGroup("高级") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("GPU 矩阵", selection: $engine.config.gpuSize) {
                    Text("2048（默认）").tag(2048)
                    Text("4096").tag(4096)
                    Text("8192").tag(8192)
                }
                Stepper(value: $engine.config.cpuJobs, in: 1...16) {
                    Text("CPU 线程 \(engine.config.cpuJobs)")
                }
                Stepper(value: $engine.config.pollSeconds, in: 5...60, step: 5) {
                    Text("轮询间隔 \(engine.config.pollSeconds) 秒")
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let engineError = engine.engine.error, !engineError.isEmpty {
            Text(engineError)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = engine.lastError, !error.isEmpty {
            Text(error)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = engine.lastMessage, !message.isEmpty {
            Text(message)
                .foregroundStyle(.green)
                .textSelection(.enabled)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(engine.isRunning ? "运行中…" : "开始循环") {
                showingStartConfirmation = true
            }
            .disabled(engine.isRunning || engine.busy || !engine.environmentReady || !engine.thermalSafe)
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(.borderedProminent)

            Button("停止") {
                engine.stop()
            }
            .disabled(!engine.isRunning || engine.busy)
            .keyboardShortcut(".", modifiers: [.command])

            Button("恢复适配器") {
                engine.restorePower()
            }
            .disabled(engine.busy)
            .help("请求停止循环，再让 batt 恢复并验证电源适配器")
        }
        .controlSize(.large)
    }

    private var footer: some View {
        HStack {
            Button("打开日志") { engine.openLog() }
                .buttonStyle(.borderless)
            Spacer()
            Text("数据仅保存在 ~/Library，不同步 iCloud")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

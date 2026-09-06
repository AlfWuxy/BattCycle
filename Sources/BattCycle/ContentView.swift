import BattCycleCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: EngineController
    private let historyDirectory: URL
    @State private var section: DashboardPane = .overview
    @State private var showingStartConfirmation = false

    init(initialSection: DashboardPane = .overview, historyDirectory: URL = SupportPaths.historyDirectory) {
        _section = State(initialValue: initialSection)
        self.historyDirectory = historyDirectory
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        switch section {
                        case .overview:
                            OverviewView()
                        case .cycle:
                            CyclePlanView()
                        case .history:
                            HistoryView()
                        case .adapter:
                            AdapterControlView()
                        case .advice:
                            AdviceView()
                        case .settings:
                            SettingsDiagnosticsView(historyDirectory: historyDirectory)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 950)
                    .frame(maxWidth: .infinity)
                }
                feedback
                Divider()
                controls
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background {
            if section != .cycle {
                // 被动监测页保留键盘入口，显式启动按钮只显示在循环实验页。
                Button("开始循环") { showingStartConfirmation = true }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(engine.isRunning || engine.busy || !engine.environmentReady || !engine.thermalSafe)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .tint(.blue)
        .frame(minWidth: 820, minHeight: 640)
        .confirmationDialog(
            "确认开始电池循环？",
            isPresented: $showingStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认开始", role: .destructive) { engine.start() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将主动切断适配器并运行 CPU 与 GPU 压测。请保持 MacBook 开盖、通风，并留意温度。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BattCycle").font(.headline)
                    Text("电池监测与控制").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 27)
            .padding(.bottom, 24)

            List(DashboardPane.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .padding(.vertical, 5)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            VStack(alignment: .leading, spacing: 9) {
                Label("仅存于这台 Mac", systemImage: "lock.shield")
                    .font(.caption.weight(.medium))
                Text("配置与日志保存在本机，\n不通过 iCloud 同步。")
                    .font(.caption2)
                    .lineSpacing(3)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(20)
        }
        .frame(width: 184)
        .background(.bar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(section.title).font(.system(size: 28, weight: .bold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            StatusBadge(
                title: engine.busy ? "处理中" : (engine.isRunning ? "循环运行中" : "循环未启动"),
                symbol: engine.busy ? "hourglass" : (engine.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle"),
                color: engine.isRunning ? .orange : .secondary
            )
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if hasFeedback {
            ScrollView {
                VStack(spacing: 8) {
                    if let error = engine.engine.error, !error.isEmpty {
                        NoticeView(title: "引擎需要处理", message: error, symbol: "exclamationmark.octagon", color: .red)
                    }
                    if let error = engine.lastError, !error.isEmpty {
                        NoticeView(title: "操作未完成", message: error, symbol: "exclamationmark.circle", color: .red)
                    }
                    if let message = engine.lastMessage, !message.isEmpty {
                        NoticeView(title: "操作反馈", message: message, symbol: "checkmark.circle", color: .green)
                    }
                }
            }
            .frame(maxHeight: 110)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private var hasFeedback: Bool {
        [engine.engine.error, engine.lastError, engine.lastMessage]
            .contains { !($0 ?? "").isEmpty }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if engine.busy {
                    ProgressView().controlSize(.small)
                }
                Text("\(engine.thermalMessage) · \(engine.isRunning ? "关窗后继续运行，请使用停止结束。" : "主动循环会产生负载与热量，请保持通风。")")
                    .font(.caption)
                    .foregroundStyle(engine.thermalSafe ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if section == .cycle {
                    Button {
                        showingStartConfirmation = true
                    } label: {
                        Label(engine.isRunning ? "循环运行中" : "开始循环", systemImage: "play.fill")
                            .padding(.horizontal, 8)
                    }
                    .disabled(engine.isRunning || engine.busy || !engine.environmentReady || !engine.thermalSafe)
                    .keyboardShortcut("r", modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                }

                Button { engine.stop() } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(!engine.canStop)
                .keyboardShortcut(".", modifiers: [.command])

                Spacer(minLength: 8)
                Button { engine.restorePower() } label: {
                    Label("恢复适配器", systemImage: "powerplug")
                }
                .disabled(!engine.canRequestRestore)
                .help("请求停止循环，再让 batt 恢复并验证电源适配器")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .background(.bar)
    }
}

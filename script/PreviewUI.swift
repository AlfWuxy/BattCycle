// 仅用于开发预览：编译真实视图，但不链接引擎控制器或电源服务。
import AppKit
import BattCycleCore
import SwiftUI

enum AdapterCommandState: Equatable {
    case idle, running, success, failed, timeout, unknown
    var statusTitleZH: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "执行中"
        case .success: return "成功"
        case .failed: return "失败"
        case .timeout: return "超时"
        case .unknown: return "未知"
        }
    }
}

final class EngineController: ObservableObject {
    @Published var config = CycleConfig.default
    @Published var snapshot = BatterySnapshot.empty
    @Published var flow = EnergyFlow.classify(.empty)
    @Published var metrics = PowerMetrics.assemble(snapshot: .empty)
    @Published var trust: DataTrust = .unavailable
    @Published var battStatus: BattStatusSnapshot?
    @Published var capabilities = CapabilityInventory.build(snapshot: nil, battVersionOk: false, timedDisableSupported: false, daemonReachable: false)
    @Published var monitorSettings = MonitorSettings.default
    @Published var recordingState: RecordingController.State = .idle
    @Published var lastSampleAt: Date?
    @Published var nextHistorySampleAt: Date?
    @Published var lastHeartbeatAt: Date?
    @Published var historyRange = HistoryRange.hours1
    @Published var chartResult = HistoryQueryResult.empty
    @Published var energyEstimates: EnergyEstimates?
    @Published var advice: [Advice] = []
    @Published var adapterCommandState = AdapterCommandState.idle
    @Published var adapterCommandMessageZH = "预览模式：尚未执行适配器命令"
    @Published var adapterSuspendSeconds = 300
    @Published var adapterAutoEnableAt: Date?
    @Published var historySampleCount = 0
    @Published var historyByteCount = 0
    @Published var engine = EngineState.idle
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published var busy = false
    @Published var environmentChecking = false
    @Published var environmentReady = false
    @Published var environmentMessage = "预览模式：尚未检查运行环境。不会调用 batt 或读取运行目录。"
    @Published var thermalSafe = false
    @Published var thermalMessage = "预览模式：热状态未经实机验证"
    @Published var isRunning = false
    @Published var controlTransaction = ControlTransaction.idle

    var phaseLabel: String { isRunning ? "放电压测中（到下限）" : "空闲" }
    var canStop: Bool { isRunning && !busy }
    var canRequestRestore: Bool { controlTransaction.restoreArrival() != .ignoreDuplicate }
    var adapterManualControlBlockedReason: String? { isRunning ? "主动循环正在运行，适配器由循环引擎管理" : nil }

    // 所有按钮仅改变内存中的展示反馈，不访问硬件、用户文件或外部进程。
    func start() { lastMessage = "预览：已确认开始；未启动任何真实循环。" }
    func stop() { lastMessage = "预览：已点击停止；未执行任何硬件操作。" }
    func restorePower() { lastMessage = "预览：已点击恢复；未执行任何硬件操作。" }
    func checkEnvironment() { lastMessage = "预览：已点击检查；未探测任何服务。" }
    func openLog() { lastMessage = "预览：已点击日志；未打开或读取任何文件。" }
    func revealLogs() { openLog() }
    func setHistoryRange(_ range: HistoryRange) { historyRange = range }
    func setHistoryInterval(_ seconds: Int) { monitorSettings.historyIntervalSeconds = seconds }
    func setRetentionDays(_ days: Int) { monitorSettings.retentionDays = days }
    func pauseRecording() { monitorSettings.recordingPaused = true }
    func resumeRecording() { monitorSettings.recordingPaused = false }
    func restoreDefaultCycleConfig() { config = .default }
    func restoreDefaultMonitorSettings() { monitorSettings = .default }
    func suspendAdapterConfirmed() { lastMessage = "预览：已确认限时关闭；未操作硬件。" }
    func resumeAdapterNow() { lastMessage = "预览：已请求恢复；未操作硬件。" }
    func clearHistoryAndReport() { lastMessage = "预览：未删除任何历史文件。" }
    func exportHistoryCSV(to url: URL) throws { lastMessage = "预览：未向所选路径写入数据。" }
    func presentError(_ message: String) { lastError = message }

    init(state: String) {
        guard state != "empty" else { return }
        let now = Date()
        let running = state == "running"
        snapshot = BatterySnapshot(percent: 76, drawingFrom: running ? "电池供电" : "电源适配器", isCharging: !running, externalConnected: !running, watts: running ? -23.6 : 18.4, summary: "示例数据", capturedAt: now)
        flow = snapshot.classifiedEnergyFlow()
        metrics = PowerMetrics.assemble(snapshot: snapshot, adapterDetails: ["Watts": 67, "Name": "示例 USB-C 适配器", "Manufacturer": "示例厂商"], adapterPhysicallyConnected: true)
        battStatus = BattStatusSnapshot(pluggedIn: true, useAdapter: !running, allowCharging: true, allowNonRootAccess: true, adapterControl: true, currentChargePercent: 76, batteryState: running ? "discharging" : "charging", chargeRateWatts: running ? -23.6 : 18.4, upperLimitPercent: 80, voltageVolts: 12.5)
        capabilities = CapabilityInventory.build(snapshot: battStatus, battVersionOk: true, timedDisableSupported: true, daemonReachable: true)
        trust = .trusted
        environmentReady = true
        environmentMessage = "示例状态：batt、stress-ng 与 MLX 已就绪。未执行真实检查。"
        thermalSafe = true
        thermalMessage = "示例状态：热压力正常；未经实机验证"
        lastSampleAt = now
        nextHistorySampleAt = now.addingTimeInterval(30)
        lastHeartbeatAt = now
        monitorSettings.historyIntervalSeconds = 30
        var samples: [HistorySample] = []
        for index in 0...120 {
            if (54...62).contains(index) { continue }
            let charging = index < 45 || index >= 91
            let level = index < 45 ? 53 + index / 2 : (index < 91 ? 75 - (index - 45) / 2 : 53 + (index - 91) * 3 / 4)
            let watts = (charging ? 19.0 : -25.0) + sin(Double(index) / 4) * 4
            samples.append(HistorySample(at: now.addingTimeInterval(Double(index - 120) * 30), percent: level, watts: watts, direction: charging ? "charge" : "discharge", pluggedIn: true, useAdapter: charging, thermal: "nominal", enginePhase: charging ? "charging" : "discharging", intervalSeconds: 30))
        }
        chartResult = HistoryQueryResult(samples: samples, chartPoints: HistoryQuery.chartPoints(from: samples, intervalSeconds: 30))
        energyEstimates = EnergyEstimates.estimate(samples: samples, from: now.addingTimeInterval(-3600), to: now, intervalSeconds: 30)
        historySampleCount = samples.count
        historyByteCount = samples.count * 240
        advice = [Advice(id: "preview-advice", severity: .info, observedFactsZH: ["示例历史包含充电、放电与一段采样间隙。", "以下内容由预览数据生成，不是设备结论。"], timeRangeDescriptionZH: "最近 1 小时 · 示例", ruleId: "preview", ruleDescriptionZH: "回看历史，了解这次记录中的功率变化。", confidence: 0.2, suggestedActionZH: "先积累连续、完整的实际记录，再判断是否需要调整使用方式。", generatedAt: now, dataInsufficient: true, displayNameZH: "示例：检查历史完整度")]
        if running {
            isRunning = true
            engine.upper = 80
            engine.lower = 30
            engine.stopAtEpoch = config.stopAtEpoch
        }
        if state == "busy" { busy = true }
        if state == "error" {
            adapterCommandState = .unknown
            adapterCommandMessageZH = "示例错误：适配器状态无法确认，请立即恢复。"
            lastError = "示例错误：适配器恢复未通过验证。请检查运行日志，并保留电源连接后重试恢复。"
        }
    }
}

@main
struct PreviewApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    private func argument(_ name: String, fallback: String) -> String {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return fallback }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = argument("--state", fallback: "empty")
        let section = DashboardPane(rawValue: argument("--section", fallback: "overview")) ?? .overview
        let width = max(820, Double(argument("--width", fallback: "1120")) ?? 1120)
        let height = max(640, Double(argument("--height", fallback: "860")) ?? 860)
        let dark = ProcessInfo.processInfo.arguments.contains("--dark")
        let root = NSHostingView(rootView: ContentView(initialSection: section, historyDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BattCycle-preview-empty-history-\(UUID().uuidString)"))
            .environmentObject(EngineController(state: state))
            .environment(\.controlActiveState, .key)
            .environment(\.dashboardSnapshotPreview, true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "BattCycle UI Preview · 示例数据 · 无硬件操作"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        let output = argument("--output", fallback: "")
        guard !output.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            root.layoutSubtreeIfNeeded()
            guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(1) }
            root.cacheDisplay(in: root.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            do {
                try data.write(to: URL(fileURLWithPath: output))
                print("Native preview saved: \(output)")
                NSApp.terminate(nil)
            } catch {
                fputs("Preview write failed: \(error)\n", stderr)
                exit(1)
            }
        }
    }
}

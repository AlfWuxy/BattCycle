// 仅用于开发预览：编译真实视图，但不链接引擎控制器或电源服务。
import AppKit
import BattCycleCore
import SwiftUI

final class EngineController: ObservableObject {
    @Published var config = CycleConfig.default
    @Published var snapshot = BatterySnapshot.empty
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

    var phaseLabel: String { isRunning ? "放电压测中（到下限）" : "空闲" }

    // 所有按钮仅改变内存中的展示反馈，不访问文件、硬件或外部进程。
    func start() { lastMessage = "预览：已确认开始；未启动任何真实循环。" }
    func stop() { lastMessage = "预览：已点击停止；未执行任何硬件操作。" }
    func restorePower() { lastMessage = "预览：已点击恢复；未执行任何硬件操作。" }
    func checkEnvironment() { lastMessage = "预览：已点击检查；未探测任何服务。" }
    func openLog() { lastMessage = "预览：已点击日志；未打开或读取任何文件。" }

    init(state: String) {
        guard state != "empty" else { return }
        snapshot.percent = 76
        snapshot.drawingFrom = "电源适配器 · 示例数据"
        snapshot.isCharging = true
        snapshot.externalConnected = true
        snapshot.watts = 18.4
        snapshot.capturedAt = Date()
        environmentReady = true
        environmentMessage = "示例状态：batt、stress-ng 与 MLX 已就绪。未执行真实检查。"
        thermalSafe = true
        thermalMessage = "示例状态：热压力正常；未经实机验证"
        if state == "running" {
            isRunning = true
            snapshot.drawingFrom = "电池供电 · 示例数据"
            snapshot.isCharging = false
            snapshot.watts = -23.6
            engine.upper = 80
            engine.lower = 30
            engine.stopAtEpoch = config.stopAtEpoch
        }
        if state == "busy" { busy = true }
        if state == "error" {
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
        let section = AppSection(rawValue: argument("--section", fallback: "overview")) ?? .overview
        let width = max(820, Double(argument("--width", fallback: "1040")) ?? 1040)
        let height = max(640, Double(argument("--height", fallback: "820")) ?? 820)
        let dark = ProcessInfo.processInfo.arguments.contains("--dark")
        let root = NSHostingView(rootView: ContentView(initialSection: section)
            .environmentObject(EngineController(state: state))
            .environment(\.controlActiveState, .key))
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

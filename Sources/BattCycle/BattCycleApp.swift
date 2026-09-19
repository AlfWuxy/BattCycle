import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "org.alfwuxy.BattCycle", category: "app")

/// AppKit 入口：进程内菜单栏 + 主窗口。不装 LaunchAgent / Login Item。
@main
enum BattCycleMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication.delegate 为弱引用，必须延长 AppDelegate 寿命。
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// 生命周期：关窗不退出；心跳与历史记录留在本进程的 EngineController。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var engine: EngineController!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var stopMenuItem: NSMenuItem?
    private var menuTimer: Timer?
    /// 关窗或后台时阻止 App Nap 合并 2 秒定时器；仍允许系统休眠。
    private var heartbeatActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("BattCycle 启动")
        engine = EngineController()
        beginHeartbeatActivity()
        registerSleepWake()
        showMainWindow()
        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        // 等 RunLoop 转起来再开 2 秒节拍；心跳写在 EngineController.tick，不挪到进程外。
        DispatchQueue.main.async { [weak self] in
            self?.engine.startPolling()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// 关窗只隐藏界面；菜单栏与监测继续。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine?.hasActiveEngine == true else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "BattCycle 仍在运行"
        alert.informativeText = "请先停止循环并确认适配器已经恢复，再退出应用。"
        alert.addButton(withTitle: "返回并停止循环")
        alert.runModal()
        showMainWindow()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuTimer?.invalidate()
        menuTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        endHeartbeatActivity()
    }

    @objc func showMainWindow() {
        if let window {
            // isReleasedWhenClosed = false：关窗后复用同一窗口，避免再挂一套 ContentView。
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = NSHostingView(
            rootView: ContentView()
                .environmentObject(engine)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BattCycle"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 640)
        window.center()
        window.setFrameAutosaveName("BattCycleMain")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func stopCycle() {
        engine.stop()
    }

    @objc private func restoreAdapter() {
        engine.restorePower()
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        engine?.systemWillSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        engine?.systemDidWake()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusItem()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusItem()
    }

    private func registerSleepWake() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Batt"
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "打开 BattCycle", action: #selector(showMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let stop = NSMenuItem(title: "停止循环", action: #selector(stopCycle), keyEquivalent: ".")
        stop.target = self
        stopMenuItem = stop
        menu.addItem(stop)

        // Restore 保持可点：忙碌时由 EngineController 排队，不在菜单栏禁用。
        let restore = NSMenuItem(title: "恢复适配器", action: #selector(restoreAdapter), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())
        // 菜单栏无 Start：确认与配置必须在主窗口完成。
        menu.addItem(NSMenuItem(title: "退出 BattCycle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        // common 模式含菜单跟踪：拉开菜单栏时标题与 Stop 仍刷新；真正心跳在 EngineController。
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshStatusItem()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        statusItem?.button?.title = engine.menuBarTitle
        stopMenuItem?.isEnabled = engine.canStop
    }

    private func beginHeartbeatActivity() {
        guard heartbeatActivity == nil else { return }
        ProcessInfo.processInfo.disableAutomaticTermination("BattCycle 进程内监测")
        ProcessInfo.processInfo.disableSuddenTermination()
        heartbeatActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "BattCycle 进程内心跳与历史记录"
        )
    }

    private func endHeartbeatActivity() {
        if let heartbeatActivity {
            ProcessInfo.processInfo.endActivity(heartbeatActivity)
            self.heartbeatActivity = nil
        }
    }
}

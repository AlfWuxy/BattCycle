import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "org.alfwuxy.BattCycle", category: "app")

@main
enum BattCycleMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var engine: EngineController!
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var stopMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("BattCycle 启动")
        engine = EngineController()
        showMainWindow()
        setupStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.engine.startPolling()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

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

    @objc func showMainWindow() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = NSHostingView(
            rootView: ContentView()
                .environmentObject(engine)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 510, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BattCycle"
        window.contentView = root
        window.delegate = self
        window.isReleasedWhenClosed = false
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

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Batt"
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open BattCycle", action: #selector(showMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let stop = NSMenuItem(title: "Stop", action: #selector(stopCycle), keyEquivalent: ".")
        stop.target = self
        stopMenuItem = stop
        menu.addItem(stop)

        let restore = NSMenuItem(title: "Restore Adapter", action: #selector(restoreAdapter), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusItem?.button?.title = self.engine.menuBarTitle
            self.stopMenuItem?.isEnabled = self.engine.isRunning && !self.engine.busy
        }
    }
}

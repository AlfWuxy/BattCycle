import AppKit
import BattCycleCore
import Darwin
import Foundation
import SwiftUI

final class EngineController: ObservableObject {
    @Published var config: CycleConfig
    @Published var snapshot: BatterySnapshot = .empty
    @Published var engine: EngineState = .idle
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published private(set) var busy = false
    @Published private(set) var environmentChecking = false
    @Published private(set) var environmentReady = false
    @Published private(set) var environmentMessage = "尚未检查运行环境"
    @Published private(set) var thermalSafe = false
    @Published private(set) var thermalMessage = "正在建立热状态守护…"
    @Published private(set) var running = false

    private var timer: Timer?

    init() {
        config = Self.loadConfig()
    }

    func startPolling() {
        refreshAsync()
        checkEnvironment()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }
    }

    var isRunning: Bool { running }

    var phaseLabel: String {
        switch engine.phase {
        case "charging": return "充电中（到上限）"
        case "discharging": return "放电压测中（到下限）"
        case "init": return "启动中"
        case "failed": return "恢复失败"
        case "idle": return isRunning ? "循环运行中" : "空闲"
        default: return engine.phase.isEmpty ? (isRunning ? "循环运行中" : "空闲") : engine.phase
        }
    }

    var menuBarTitle: String {
        isRunning ? "\(snapshot.percent)%" : "Batt"
    }

    var hasActiveEngine: Bool {
        busy || isRunning || Self.recordedPID() != nil
    }

    func checkEnvironment() {
        guard !environmentChecking else { return }
        environmentChecking = true
        environmentMessage = "正在检查 batt、stress-ng 与 MLX…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let readiness = try BattService.preflight()
                DispatchQueue.main.async {
                    self.environmentReady = true
                    self.environmentMessage = readiness.summary
                    self.environmentChecking = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.environmentReady = false
                    self.environmentMessage = error.localizedDescription
                    self.environmentChecking = false
                }
            }
        }
    }

    @discardableResult
    func saveConfig() -> Bool {
        do {
            let valid = try config.validated()
            let data = try JSONEncoder.pretty.encode(valid)
            try SupportPaths.ensurePrivateDirectories()
            try data.write(to: SupportPaths.config, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: SupportPaths.config.path
            )
            config = valid
            return true
        } catch {
            lastError = "配置未保存：\(error.localizedDescription)"
            return false
        }
    }

    func start() {
        guard !busy, !isRunning else { return }
        lastError = nil
        lastMessage = nil
        guard saveConfig() else { return }

        do {
            if FileManager.default.fileExists(atPath: SupportPaths.stopRequest.path) {
                try FileManager.default.removeItem(at: SupportPaths.stopRequest)
            }
        } catch {
            lastError = "无法清除旧停止请求：\(error.localizedDescription)"
            return
        }

        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BattService.start()
                var started = false
                for _ in 0..<50 {
                    Thread.sleep(forTimeInterval: 0.2)
                    if Self.pidFileAlive() != nil {
                        started = true
                        break
                    }
                }
                DispatchQueue.main.async {
                    self.refreshAsync()
                    if started {
                        self.environmentReady = true
                        self.lastMessage = "循环引擎已启动"
                    } else {
                        self.lastError = "启动脚本已返回，但引擎没有进入运行状态。\(Self.launchFailureHint())"
                    }
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.environmentReady = false
                    self.environmentMessage = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func stop() {
        stop(reason: nil)
    }

    private func stop(reason: String?) {
        guard !busy else { return }
        busy = true
        lastError = reason
        lastMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.stopCycle()
                DispatchQueue.main.async {
                    self.lastMessage = "循环已停止，适配器已验证恢复：\(result)"
                    self.busy = false
                    self.refreshAsync()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.busy = false
                    self.refreshAsync()
                }
            }
        }
    }

    func restorePower() {
        guard !busy else { return }
        busy = true
        lastError = nil
        lastMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.restoreAdapter()
                DispatchQueue.main.async {
                    self.lastMessage = "适配器恢复成功：\(result)"
                    self.busy = false
                    self.refreshAsync()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.busy = false
                }
            }
        }
    }

    func openLog() {
        let latest = SupportPaths.latestLog
        if FileManager.default.fileExists(atPath: latest.path) {
            NSWorkspace.shared.open(latest)
        } else if !engine.log.isEmpty {
            let candidate = URL(fileURLWithPath: engine.log).standardizedFileURL
            let root = SupportPaths.logs.standardizedFileURL.path + "/"
            if candidate.path.hasPrefix(root), FileManager.default.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.open(candidate)
            } else {
                NSWorkspace.shared.open(SupportPaths.logs)
            }
        } else {
            NSWorkspace.shared.open(SupportPaths.logs)
        }
    }

    func refresh() {
        refreshAsync()
    }

    private func refreshAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = BatterySnapshot.capture()
            let state = Self.loadState()
            let running = Self.computeRunning(state)
            let recoveryNeeded = state.running && !running && Self.recordedPID() == state.pid
            let thermal = ProcessInfo.processInfo.thermalState
            let heartbeatError = Self.writeGuardianHeartbeat(thermalState: thermal)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snapshot
                self.engine = state
                self.running = running
                let thermalAllowed = thermal == .nominal || thermal == .fair
                self.thermalSafe = heartbeatError == nil && thermalAllowed
                self.thermalMessage = heartbeatError ?? Self.thermalDescription(thermal)
                if running, !self.thermalSafe, !self.busy {
                    self.stop(reason: "热状态守护触发停止：\(self.thermalMessage)")
                } else if recoveryNeeded, !self.busy {
                    self.stop(reason: "检测到引擎失联，正在终止残余负载并恢复适配器")
                }
            }
        }
    }

    private static func writeGuardianHeartbeat(thermalState: ProcessInfo.ThermalState) -> String? {
        do {
            try SupportPaths.ensurePrivateDirectories()
            let payload: [String: Any] = [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "updatedEpoch": Int(Date().timeIntervalSince1970),
                "thermalState": thermalStateName(thermalState),
                "executablePath": Bundle.main.executablePath ?? ""
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: SupportPaths.guardianHeartbeat, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: SupportPaths.guardianHeartbeat.path
            )
            return nil
        } catch {
            return "无法写入安全心跳：\(error.localizedDescription)"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "热状态正常"
        case .fair: return "热状态升高，系统仍允许运行"
        case .serious: return "热状态严重，已请求安全停止"
        case .critical: return "热状态临界，已请求安全停止"
        @unknown default: return "无法识别热状态，禁止启动"
        }
    }

    private static func computeRunning(_ state: EngineState) -> Bool {
        let age = Int(Date().timeIntervalSince1970) - state.updatedEpoch
        if state.running,
           state.pid > 1,
           state.pid <= Int(Int32.max),
           age >= 0,
           age <= 75,
           pidFileAlive() == state.pid,
           kill(pid_t(state.pid), 0) == 0 || errno == EPERM {
            return true
        }
        return false
    }

    private static func pidFileAlive() -> Int? {
        guard let pid = recordedPID() else { return nil }
        if kill(pid_t(pid), 0) == 0 || errno == EPERM { return pid }
        return nil
    }

    private static func recordedPID() -> Int? {
        guard let raw = try? String(contentsOf: SupportPaths.pid, encoding: .utf8),
              let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              pid <= Int(Int32.max) else { return nil }
        return pid
    }

    private static func launchFailureHint() -> String {
        let urls = [
            SupportPaths.logs.appendingPathComponent("engine.out"),
            SupportPaths.logs.appendingPathComponent("launch.log"),
            SupportPaths.latestLog
        ]
        for url in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let last = text.split(separator: "\n").suffix(4).joined(separator: " / ")
                if !last.isEmpty { return "日志：\(last)" }
            }
        }
        return "请打开日志查看原因。"
    }

    private static func loadConfig() -> CycleConfig {
        guard let data = try? Data(contentsOf: SupportPaths.config),
              var decoded = try? JSONDecoder().decode(CycleConfig.self, from: data) else {
            return .default
        }
        decoded.applyDefaultStopIfNeeded()
        return (try? decoded.validated()) ?? .default
    }

    private static func loadState() -> EngineState {
        guard let data = try? Data(contentsOf: SupportPaths.state),
              let decoded = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return .idle
        }
        return decoded
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

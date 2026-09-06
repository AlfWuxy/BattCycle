import BattCycleCore
import Darwin
import Foundation

enum BattService {
    struct Readiness: Equatable {
        let battVersion: String

        var summary: String {
            "环境已就绪，batt \(battVersion) daemon 可用"
        }
    }

    static func preflight() throws -> Readiness {
        do {
            try SupportPaths.ensurePrivateDirectories()
        } catch {
            throw ServiceError.unavailable("无法创建私有运行目录：\(error.localizedDescription)")
        }

        let scripts = SupportPaths.scriptDirectory()
        let systemPython = URL(fileURLWithPath: "/usr/bin/python3")
        let consoleUserGuard = scripts.appendingPathComponent("active_console_users.py")
        try requireExecutable(systemPython, label: "系统 Python 3")
        try requireExecutable(SupportPaths.processGroupExecScript, label: "process_group_exec.py")
        try requireExecutable(consoleUserGuard, label: "active_console_users.py")

        let consoleResult = try run(
            systemPython,
            arguments: ["-I", consoleUserGuard.path],
            timeout: 5
        )
        guard consoleResult.status == 0 else {
            throw ServiceError.unavailable(
                "无法确认启动时仅有当前 macOS 控制台账号：\(consoleResult.output)"
            )
        }

        try requireExecutable(SupportPaths.battExecutable, label: "batt")
        try requireExecutable(SupportPaths.stressExecutable, label: "stress-ng")
        try requireExecutable(SupportPaths.pythonExecutable, label: "Python 3")

        let startScript = SupportPaths.startDetachedScript
        try requireExecutable(startScript, label: "start-detached.sh")
        try requireExecutable(SupportPaths.boundedExecScript, label: "bounded_exec.py")
        try requireExecutable(scripts.appendingPathComponent("engine_lock.py"), label: "engine_lock.py")
        try requireExecutable(
            scripts.appendingPathComponent("process_group_marker.py"),
            label: "process_group_marker.py"
        )
        try requireExecutable(scripts.appendingPathComponent("battery_cycle_stress.sh"), label: "循环引擎")
        try requireExecutable(scripts.appendingPathComponent("battcycle"), label: "battcycle CLI")
        guard FileManager.default.isReadableFile(atPath: scripts.appendingPathComponent("mlx_gpu_stress.py").path) else {
            throw ServiceError.unavailable("找不到可读的 MLX 压测脚本")
        }
        guard FileManager.default.isReadableFile(atPath: scripts.appendingPathComponent("battcycle_config.py").path) else {
            throw ServiceError.unavailable("找不到可读的配置验证器 battcycle_config.py")
        }

        let versionResult = try run(SupportPaths.battExecutable, arguments: ["version"], timeout: 3)
        guard let versions = parsedVersions(versionResult.output) else {
            throw ServiceError.unavailable("无法同时读取 batt Client 与 Daemon 版本：\(versionResult.output)")
        }
        guard !versions.client.components.lexicographicallyPrecedes([0, 8, 0]),
              !versions.daemon.components.lexicographicallyPrecedes([0, 8, 0]) else {
            throw ServiceError.unavailable(
                "Client 与 Daemon 都需要 batt 0.8.0 或更新版本，当前为 \(versions.client.text) / \(versions.daemon.text)"
            )
        }

        let daemonResult = try run(SupportPaths.battExecutable, arguments: ["status", "--json"], timeout: 3)
        guard daemonResult.status == 0 else {
            throw ServiceError.unavailable("batt daemon 未就绪。请先按 README 安装 daemon 并允许普通用户访问。\n\(daemonResult.output)")
        }
        try validateDaemonStatus(daemonResult.output)
        try requireTimedDisableHelp()

        let mlxResult = try run(
            SupportPaths.pythonExecutable,
            arguments: ["-I", "-c", "import mlx"],
            timeout: 5
        )
        guard mlxResult.status == 0 else {
            throw ServiceError.unavailable("Python 无法导入 mlx：\(mlxResult.output)")
        }

        return Readiness(battVersion: "Client \(versions.client.text) / Daemon \(versions.daemon.text)")
    }

    static func start() throws {
        try rejectStartIfManualSuspendActive()
        _ = try preflight()
        let result = try run(
            SupportPaths.startDetachedScript,
            arguments: [
                SupportPaths.config.path,
                SupportPaths.applicationSupport.path,
                SupportPaths.logs.path
            ],
            timeout: 12
        )
        guard result.status == 0 else {
            throw ServiceError.commandFailed("启动请求被拒绝：\(result.output)")
        }
    }

    static func restoreAdapter() throws -> String {
        let output = try runControl(command: "restore", timeout: 180)
        clearManualSuspendMarker()
        return output
    }

    static func stopCycle() throws -> String {
        try runControl(command: "stop", timeout: 180)
    }

    /// 只读：`batt status --json`。daemon 不可达时抛错，由调用方把快照置为 nil。
    static func readStatusJSON() throws -> BattStatusSnapshot {
        try requireExecutable(SupportPaths.battExecutable, label: "batt")
        let result = try run(SupportPaths.battExecutable, arguments: ["status", "--json"], timeout: 3)
        guard result.status == 0 else {
            throw ServiceError.unavailable("无法读取 batt 状态：\(result.output)")
        }
        return try BattStatusSnapshot.parse(result.output)
    }

    /// 只读：`batt adapter disable --help`。不执行 disable。
    static func adapterDisableHelpText() throws -> String {
        try requireExecutable(SupportPaths.battExecutable, label: "batt")
        let result = try run(
            SupportPaths.battExecutable,
            arguments: ["adapter", "disable", "--help"],
            timeout: 3
        )
        if result.output.isEmpty {
            throw ServiceError.commandFailed("无法读取 batt adapter disable 帮助")
        }
        return result.output
    }

    /// 帮助文本按选项词含 `--for` / `--for=` 则为 true；仅有 `--force` 或任何错误为 false。
    static func probeTimedDisableSupported() -> Bool {
        guard let help = try? adapterDisableHelpText() else { return false }
        return TimedDisableHelp.supportsTimedDisable(help)
    }

    /// 与 CLI `require_timed_adapter_disable_help` 同一口径：token 级 `--for`，不含 `--force`。
    private static func requireTimedDisableHelp() throws {
        let help = try adapterDisableHelpText()
        guard TimedDisableHelp.supportsTimedDisable(help) else {
            throw ServiceError.unavailable("当前 batt 不支持 adapter disable --for")
        }
    }

    /// 只读版本探针，不要求 daemon 已就绪。失败为 false。
    static func probeVersionOK() -> Bool {
        do {
            try requireExecutable(SupportPaths.battExecutable, label: "batt")
            let result = try run(SupportPaths.battExecutable, arguments: ["version"], timeout: 3)
            guard let versions = parsedVersions(result.output) else { return false }
            return !versions.client.components.lexicographicallyPrecedes([0, 8, 0])
                && !versions.daemon.components.lexicographicallyPrecedes([0, 8, 0])
        } catch {
            return false
        }
    }

    /// 独立限时切断。循环运行时必须拒绝，此处不上 stop/restore。
    /// 只接受 1...600 秒；battcycle 会转成 `adapter disable --for=<seconds>s`。
    /// 调用当下立刻写下保守的 `adapter-suspend-until`，再等待 batt 命令。
    static func suspendAdapter(seconds: Int) throws -> String {
        try rejectIndependentAdapterIfCycleRunning(suggested: "stop")
        guard (1...600).contains(seconds) else {
            throw ServiceError.unavailable("适配器切断时长必须是 1 到 600 秒的整数")
        }
        let until = Date().addingTimeInterval(TimeInterval(seconds))
        try persistSuspendUntil(until)
        do {
            // 包含最长 60 秒控制锁等待、只读检查，以及最多两轮 enable/status 补偿。
            return try runBattcycle(arguments: ["suspend-adapter", String(seconds)], timeout: 135)
        } catch {
            let originalError = error
            // 旧写命令组未确认退出时，不能凭一次状态读取清除恢复标记。
            if let serviceError = error as? ServiceError, case .cleanupUnconfirmed = serviceError {
                throw originalError
            }
            // 普通失败已由 CLI 做有界补偿，只有外层超时才需要重新发起恢复。
            guard let serviceError = error as? ServiceError, case .timedOut = serviceError else {
                reconcileSuspendMarkerAfterFailure()
                throw originalError
            }
            if (try? readStatusJSON())?.useAdapter == true {
                clearManualSuspendMarker()
                throw originalError
            }
            // 外层超时已回收旧进程组；重新通过 CLI 锁执行恢复，不直接抢占适配器。
            let recovery: String
            do {
                recovery = try runBattcycle(arguments: ["resume-adapter"], timeout: 100)
            } catch let recoveryError {
                reconcileSuspendMarkerAfterFailure()
                throw ServiceError.commandFailed(
                    "切断请求失败：\(originalError.localizedDescription)\n恢复结果：\(recoveryError.localizedDescription)"
                )
            }
            clearManualSuspendMarker()
            throw ServiceError.commandFailed(
                "切断请求失败：\(originalError.localizedDescription)\n恢复已验证：\(recovery)"
            )
        }
    }

    /// 独立恢复适配器。循环运行时必须拒绝，此处不上 stop。
    static func resumeAdapter() throws -> String {
        try rejectIndependentAdapterIfCycleRunning(suggested: "restore")
        let output = try runBattcycle(arguments: ["resume-adapter"], timeout: 100)
        clearManualSuspendMarker()
        return output
    }

    /// 手动切断截止文件。不改 SupportPaths；沿用 applicationSupport 拼接。
    static var adapterSuspendUntilURL: URL {
        SupportPaths.applicationSupport.appendingPathComponent("adapter-suspend-until")
    }

    static func clearManualSuspendMarker() {
        try? FileManager.default.removeItem(at: adapterSuspendUntilURL)
    }

    /// 限时切断文件仍在、或 `useAdapter == false` 时禁止启动循环。
    static func shouldBlockEngineStart(status: BattStatusSnapshot?) -> Bool {
        if status?.useAdapter == false {
            return true
        }
        guard let until = readSuspendUntil() else {
            return false
        }
        if until > Date() {
            return true
        }
        return status?.useAdapter != true
    }

    /// 独立 suspend/resume 不得与循环抢适配器；Restore 不走此检查。
    private static func rejectIndependentAdapterIfCycleRunning(suggested: String) throws {
        guard let raw = try? String(contentsOf: SupportPaths.pid, encoding: .utf8),
              let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              pid <= Int(Int32.max) else { return }
        if Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM {
            throw ServiceError.unavailable(
                "循环引擎正在运行；请使用 \(suggested) 停止循环或等待结束，勿抢占适配器"
            )
        }
    }

    private static func rejectStartIfManualSuspendActive() throws {
        guard readSuspendUntil() != nil else { return }
        let status = try? readStatusJSON()
        if shouldBlockEngineStart(status: status) {
            throw ServiceError.unavailable("手动限时切断适配器仍在生效，请先恢复适配器后再启动循环")
        }
        if status?.useAdapter == true {
            clearManualSuspendMarker()
        }
    }

    private static func persistSuspendUntil(_ date: Date) throws {
        do {
            try SupportPaths.ensurePrivateDirectories()
            let payload = "\(Int(date.timeIntervalSince1970))\n"
            try Data(payload.utf8).write(to: adapterSuspendUntilURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: adapterSuspendUntilURL.path
            )
        } catch {
            throw ServiceError.unavailable("无法写入适配器切断截止时间：\(error.localizedDescription)")
        }
    }

    private static func readSuspendUntil() -> Date? {
        guard let text = try? String(contentsOf: adapterSuspendUntilURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let epoch = TimeInterval(trimmed) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// 超时或失败后重读 status：切断已生效则保留截止文件；已恢复则清除；未知则保留。
    private static func reconcileSuspendMarkerAfterFailure() {
        let status = try? readStatusJSON()
        switch status?.useAdapter {
        case .some(false):
            break
        case .some(true):
            clearManualSuspendMarker()
        case .none:
            break
        }
    }

    private static func runControl(command: String, timeout: TimeInterval) throws -> String {
        try runBattcycle(arguments: [command], timeout: timeout)
    }

    private static func runBattcycle(arguments: [String], timeout: TimeInterval) throws -> String {
        let control = SupportPaths.scriptDirectory().appendingPathComponent("battcycle")
        try requireExecutable(control, label: "battcycle CLI")
        let result = try run(control, arguments: arguments, timeout: timeout)
        let name = arguments.first ?? "battcycle"
        guard result.status == 0 else {
            throw ServiceError.commandFailed("\(name) 失败：\(result.output)")
        }
        return result.output.isEmpty ? "命令已完成并通过验证" : result.output
    }

    private static func requireExecutable(_ url: URL, label: String) throws {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ServiceError.unavailable("找不到可执行的 \(label)：\(url.path)")
        }
    }

    private static func parsedVersions(_ output: String) -> ParsedVersions? {
        guard let client = parsedVersion(label: "Client", output: output),
              let daemon = parsedVersion(label: "Daemon", output: output) else { return nil }
        return ParsedVersions(client: client, daemon: daemon)
    }

    private static func parsedVersion(label: String, output: String) -> ParsedVersion? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label)):\\s*v?(\\d+)\\.(\\d+)(?:\\.(\\d+))?"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ) else {
            return nil
        }
        let values = (1...3).map { index -> Int in
            let range = match.range(at: index)
            guard range.location != NSNotFound,
                  let swiftRange = Range(range, in: output) else { return 0 }
            return Int(output[swiftRange]) ?? 0
        }
        return ParsedVersion(components: values, text: values.map(String.init).joined(separator: "."))
    }

    private static func validateDaemonStatus(_ output: String) throws {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let configuration = root["configuration"] as? [String: Any],
              let allowNonRootAccess = configuration["allowNonRootAccess"] as? Bool,
              allowNonRootAccess,
              let compatibility = root["compatibility"] as? [String: Any],
              compatibility["adapterControl"] as? Bool == true,
              let charging = root["charging"] as? [String: Any],
              charging["useAdapter"] as? Bool == true,
              charging["pluggedIn"] as? Bool == true else {
            throw ServiceError.unavailable(
                "batt daemon 配置不符合安全运行条件：需要普通用户访问、适配器控制，并在启动前接入且启用电源适配器。"
            )
        }
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-I",
            SupportPaths.processGroupExecScript.path,
            "--",
            executable.path
        ] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardOutput = pipe
        process.standardError = pipe
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME", "SHELL"] {
            if let value = inherited[key], !value.isEmpty {
                environment[key] = value
            }
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["BATT"] = SupportPaths.battExecutable.path
        environment["STRESS_NG"] = SupportPaths.stressExecutable.path
        environment["MLX_PYTHON"] = SupportPaths.pythonExecutable.path
        environment["CAFFEINATE"] = "/usr/bin/caffeinate"
        environment["BATTCYCLE_CONFIG"] = SupportPaths.config.path
        environment["BATTCYCLE_SUPPORT"] = SupportPaths.applicationSupport.path
        environment["BATTCYCLE_LOG_DIR"] = SupportPaths.logs.path
        environment["BATTCYCLE_GUARDIAN_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["BATTCYCLE_GUARDIAN_PATH"] = Bundle.main.executablePath ?? ""
        process.environment = environment

        let completion = DispatchSemaphore(value: 0)
        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ServiceError.commandFailed("无法运行 \(executable.path)：\(error.localizedDescription)")
        }

        var didTimeOut = false
        if completion.wait(timeout: .now() + timeout) == .timedOut {
            didTimeOut = true
            let commandGroup = process.processIdentifier
            signalProcessGroup(commandGroup, signal: SIGTERM)
            var leaderExited = completion.wait(timeout: .now() + 1) == .success
            // leader 先退出也不能留下仍可能写电源状态的子进程。
            if !leaderExited || processGroupExists(commandGroup) {
                signalProcessGroup(commandGroup, signal: SIGKILL)
                if !leaderExited {
                    leaderExited = completion.wait(timeout: .now() + 2) == .success
                }
            }
            let cleanupDeadline = DispatchTime.now() + 2
            while processGroupExists(commandGroup), DispatchTime.now() < cleanupDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard leaderExited, !processGroupExists(commandGroup) else {
                pipe.fileHandleForReading.readabilityHandler = nil
                throw ServiceError.cleanupUnconfirmed(
                    "命令超时且无法确认旧进程组已退出，适配器状态未知：\(executable.lastPathComponent)"
                )
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let text = output.text
        if didTimeOut {
            throw ServiceError.timedOut("命令执行超时并已终止：\(executable.lastPathComponent)\n\(text)")
        }
        return CommandResult(status: process.terminationStatus, output: text)
    }

    private static func processGroupExists(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        return Darwin.kill(-pid, 0) == 0 || errno == EPERM
    }

    private static func signalProcessGroup(_ pid: pid_t, signal: Int32) {
        guard pid > 1 else { return }
        if Darwin.kill(-pid, signal) != 0 {
            _ = Darwin.kill(pid, signal)
        }
    }

    private struct ParsedVersion {
        let components: [Int]
        let text: String
    }

    private struct ParsedVersions {
        let client: ParsedVersion
        let daemon: ParsedVersion
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let maximumBytes = 64 * 1024

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            // 错误原因通常位于输出末尾，因此有界缓存保留最新内容。
            if chunk.count >= maximumBytes {
                data = Data(chunk.suffix(maximumBytes))
                return
            }
            let overflow = data.count + chunk.count - maximumBytes
            if overflow > 0 {
                data.removeFirst(overflow)
            }
            data.append(chunk)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    enum ServiceError: LocalizedError {
        case unavailable(String)
        case commandFailed(String)
        case timedOut(String)
        case cleanupUnconfirmed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .commandFailed(let message), .timedOut(let message), .cleanupUnconfirmed(let message):
                return message
            }
        }
    }
}

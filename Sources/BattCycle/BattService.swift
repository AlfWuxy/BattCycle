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
        try runControl(command: "restore", timeout: 75)
    }

    static func stopCycle() throws -> String {
        try runControl(command: "stop", timeout: 75)
    }

    private static func runControl(command: String, timeout: TimeInterval) throws -> String {
        let control = SupportPaths.scriptDirectory().appendingPathComponent("battcycle")
        try requireExecutable(control, label: "battcycle CLI")
        let result = try run(control, arguments: [command], timeout: timeout)
        guard result.status == 0 else {
            throw ServiceError.commandFailed("\(command) 失败：\(result.output)")
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
            signalProcessGroup(process.processIdentifier, signal: SIGTERM)
            if completion.wait(timeout: .now() + 1) == .timedOut {
                signalProcessGroup(process.processIdentifier, signal: SIGKILL)
                guard completion.wait(timeout: .now() + 2) == .success else {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    throw ServiceError.commandFailed("命令超时且无法确认进程已退出：\(executable.lastPathComponent)")
                }
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let text = output.text
        if didTimeOut {
            throw ServiceError.commandFailed("命令执行超时并已终止：\(executable.lastPathComponent)\n\(text)")
        }
        return CommandResult(status: process.terminationStatus, output: text)
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

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .commandFailed(let message):
                return message
            }
        }
    }
}

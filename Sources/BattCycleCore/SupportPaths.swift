import Foundation

/// 运行时数据路径：只落在当前用户 `Library` 下的 BattCycle 目录。
///
/// 生产布局固定为：
/// - `~/Library/Application Support/BattCycle/`（config.json、monitor.json、history/、guardian.json、control.lock 等）
/// - `~/Library/Logs/BattCycle/`
///
/// 不提供 LaunchAgent / Login Item / 系统目录。测试应注入临时家目录，避免写入真实用户 Library。
public struct SupportPaths: Equatable, Sendable {
    /// 用作 `Library/...` 的根；生产默认是当前用户主目录。
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    /// 当前登录用户的生产布局。
    public static var live: SupportPaths { SupportPaths() }

    /// `~/Library/Application Support/BattCycle/`，不同步 iCloud。
    public var applicationSupport: URL {
        libraryDirectory.appendingPathComponent("Application Support/BattCycle", isDirectory: true)
    }

    /// `~/Library/Logs/BattCycle/`，与 Application Support 分离。
    public var logs: URL {
        libraryDirectory.appendingPathComponent("Logs/BattCycle", isDirectory: true)
    }

    public var config: URL { applicationSupport.appendingPathComponent("config.json") }
    public var state: URL { applicationSupport.appendingPathComponent("state.json") }
    /// 监测与历史设置，与引擎 CycleConfig（config.json）分离。
    public var monitor: URL { applicationSupport.appendingPathComponent("monitor.json") }
    /// 追加写入的 JSONL 历史目录，不进入 config.json / state.json。
    public var historyDirectory: URL { applicationSupport.appendingPathComponent("history", isDirectory: true) }
    public var pid: URL { applicationSupport.appendingPathComponent("run.pid") }
    public var stopRequest: URL { applicationSupport.appendingPathComponent("stop.request") }
    public var guardianHeartbeat: URL { applicationSupport.appendingPathComponent("guardian.json") }
    /// CLI 与适配器写操作的 flock 文件，与脚本 `control.lock` 对齐。
    public var controlLock: URL { applicationSupport.appendingPathComponent("control.lock") }
    public var latestLog: URL { logs.appendingPathComponent("latest.log") }

    public static let battExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/batt")
    public static let stressExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/stress-ng")

    /// 用户本地 MLX venv，仍在 Application Support/BattCycle 下。
    public var pythonExecutable: URL {
        applicationSupport.appendingPathComponent("venv/bin/python3")
    }

    public static var pythonExecutable: URL { live.pythonExecutable }

    public static func scriptDirectory() -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
#if DEBUG
        if let env = ProcessInfo.processInfo.environment["BATTCYCLE_SCRIPTS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // 调试构建从源码位置回到仓库根目录。
        let thisFile = URL(fileURLWithPath: #filePath)
        let repo = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repo.appendingPathComponent("scripts", isDirectory: true)
#else
        // 发布构建只信任应用包内资源，缺失时由预检明确报错。
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/scripts", isDirectory: true)
#endif
    }

    public static var startDetachedScript: URL {
        scriptDirectory().appendingPathComponent("start-detached.sh")
    }

    public static var boundedExecScript: URL {
        scriptDirectory().appendingPathComponent("bounded_exec.py")
    }

    public static var processGroupExecScript: URL {
        scriptDirectory().appendingPathComponent("process_group_exec.py")
    }

    /// 创建 Application Support、history、Logs，权限 0700；拒绝符号链接。
    public func ensurePrivateDirectories() throws {
        try createPrivateDirectoryOrThrow(applicationSupport)
        try createPrivateDirectoryOrThrow(historyDirectory)
        try createPrivateDirectoryOrThrow(logs)
    }

    public static func ensurePrivateDirectories() throws {
        try live.ensurePrivateDirectories()
    }

    private var libraryDirectory: URL {
        homeDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    private func createPrivateDirectoryOrThrow(_ directory: URL) throws {
        let manager = FileManager.default
        // 先看路径自身是否为符号链接，避免 fileExists 跟随后写到 iCloud 或共享目录。
        if isSymbolicLink(directory) {
            throw SupportPathError.symbolicLink(directory.path)
        }
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw SupportPathError.notDirectory(directory.path)
        }
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if isSymbolicLink(directory) {
            throw SupportPathError.symbolicLink(directory.path)
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

extension SupportPaths {
    public static var applicationSupport: URL { live.applicationSupport }
    public static var logs: URL { live.logs }
    public static var config: URL { live.config }
    public static var state: URL { live.state }
    public static var monitor: URL { live.monitor }
    public static var historyDirectory: URL { live.historyDirectory }
    public static var pid: URL { live.pid }
    public static var stopRequest: URL { live.stopRequest }
    public static var guardianHeartbeat: URL { live.guardianHeartbeat }
    public static var controlLock: URL { live.controlLock }
    public static var latestLog: URL { live.latestLog }
}

public enum SupportPathError: LocalizedError, Equatable, Sendable {
    case symbolicLink(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .symbolicLink(let path):
            return "运行目录不能是符号链接：\(path)"
        case .notDirectory(let path):
            return "运行路径不是目录：\(path)"
        }
    }
}

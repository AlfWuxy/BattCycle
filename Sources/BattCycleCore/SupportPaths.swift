import Foundation

public enum SupportPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BattCycle", isDirectory: true)
    }

    public static var logs: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Logs/BattCycle", isDirectory: true)
    }

    public static var config: URL { applicationSupport.appendingPathComponent("config.json") }
    public static var state: URL { applicationSupport.appendingPathComponent("state.json") }
    public static var pid: URL { applicationSupport.appendingPathComponent("run.pid") }
    public static var stopRequest: URL { applicationSupport.appendingPathComponent("stop.request") }
    public static var guardianHeartbeat: URL { applicationSupport.appendingPathComponent("guardian.json") }
    public static var latestLog: URL { logs.appendingPathComponent("latest.log") }

    public static let battExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/batt")
    public static let stressExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/stress-ng")
    public static var pythonExecutable: URL {
        applicationSupport.appendingPathComponent("venv/bin/python3")
    }

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

    public static func ensurePrivateDirectories() throws {
        try createPrivateDirectoryOrThrow(applicationSupport)
        try createPrivateDirectoryOrThrow(logs)
    }

    private static func createPrivateDirectoryOrThrow(_ directory: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw SupportPathError.symbolicLink(directory.path)
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SupportPathError.notDirectory(directory.path)
            }
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private enum SupportPathError: LocalizedError {
        case symbolicLink(String)
        case notDirectory(String)

        var errorDescription: String? {
            switch self {
            case .symbolicLink(let path):
                return "运行目录不能是符号链接：\(path)"
            case .notDirectory(let path):
                return "运行路径不是目录：\(path)"
            }
        }
    }
}

import BattCycleCore
import XCTest

final class SupportPathsTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("BattCycle-SupportPaths-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome {
            try? FileManager.default.removeItem(at: tempHome)
        }
    }

    /// 生产路径钉在当前用户 Library，不进 Desktop / Documents / iCloud / LaunchAgent。
    func testLiveLayoutStaysUnderUserLibraryBattCycle() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = SupportPaths.live
        let support = home.appendingPathComponent("Library/Application Support/BattCycle", isDirectory: true)
        let logs = home.appendingPathComponent("Library/Logs/BattCycle", isDirectory: true)

        XCTAssertEqual(paths.applicationSupport.standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(paths.logs.standardizedFileURL, logs.standardizedFileURL)
        XCTAssertEqual(SupportPaths.applicationSupport.standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(SupportPaths.logs.standardizedFileURL, logs.standardizedFileURL)

        assertLibraryOnly(paths.applicationSupport)
        assertLibraryOnly(paths.logs)
        assertNoLaunchAgentOrICloud(paths.applicationSupport)
        assertNoLaunchAgentOrICloud(paths.logs)
    }

    func testNamedRuntimeFilesStayUnderApplicationSupport() {
        let paths = SupportPaths.live
        let supportPath = paths.applicationSupport.path

        XCTAssertEqual(paths.config, paths.applicationSupport.appendingPathComponent("config.json"))
        XCTAssertEqual(paths.monitor, paths.applicationSupport.appendingPathComponent("monitor.json"))
        XCTAssertEqual(paths.historyDirectory, paths.applicationSupport.appendingPathComponent("history", isDirectory: true))
        XCTAssertEqual(paths.guardianHeartbeat, paths.applicationSupport.appendingPathComponent("guardian.json"))
        XCTAssertEqual(paths.controlLock, paths.applicationSupport.appendingPathComponent("control.lock"))
        XCTAssertEqual(SupportPaths.controlLock, paths.controlLock)

        for url in [
            paths.config,
            paths.monitor,
            paths.historyDirectory,
            paths.guardianHeartbeat,
            paths.controlLock,
            paths.state,
            paths.pid,
            paths.stopRequest,
            paths.pythonExecutable
        ] {
            XCTAssertTrue(url.path.hasPrefix(supportPath), "\(url.path) 必须在 Application Support/BattCycle 下")
            assertNoLaunchAgentOrICloud(url)
        }

        XCTAssertTrue(paths.latestLog.path.hasPrefix(paths.logs.path))
        XCTAssertEqual(paths.latestLog.lastPathComponent, "latest.log")
        XCTAssertNotEqual(paths.monitor, paths.config)
        XCTAssertNotEqual(paths.historyDirectory, paths.applicationSupport)
        XCTAssertNotEqual(paths.controlLock, paths.pid)
    }

    func testInjectedHomeKeepsLibraryLayoutWithoutTouchingLiveSupport() throws {
        let paths = SupportPaths(homeDirectory: tempHome)
        let support = tempHome.appendingPathComponent("Library/Application Support/BattCycle", isDirectory: true)
        let logs = tempHome.appendingPathComponent("Library/Logs/BattCycle", isDirectory: true)

        XCTAssertEqual(paths.applicationSupport.standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(paths.logs.standardizedFileURL, logs.standardizedFileURL)
        XCTAssertEqual(paths.config.lastPathComponent, "config.json")
        XCTAssertEqual(paths.monitor.lastPathComponent, "monitor.json")
        XCTAssertEqual(paths.historyDirectory.lastPathComponent, "history")
        XCTAssertEqual(paths.guardianHeartbeat.lastPathComponent, "guardian.json")
        XCTAssertEqual(paths.controlLock.lastPathComponent, "control.lock")
        XCTAssertTrue(paths.controlLock.path.hasPrefix(support.path))
        XCTAssertTrue(paths.latestLog.path.hasPrefix(logs.path))

        // 注入家目录不得改写真实用户 Library。
        XCTAssertFalse(paths.applicationSupport.path.hasPrefix(SupportPaths.live.applicationSupport.path))
        XCTAssertFalse(paths.logs.path.hasPrefix(SupportPaths.live.logs.path))
    }

    func testEnsurePrivateDirectoriesCreatesOnlyBattCycleLibraryTrees() throws {
        let paths = SupportPaths(homeDirectory: tempHome)
        try paths.ensurePrivateDirectories()

        try assertMode700(paths.applicationSupport)
        try assertMode700(paths.historyDirectory)
        try assertMode700(paths.logs)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.controlLock.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))

        let launchAgents = tempHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgents.path))

        try assertCreatedPathsStayInBattCycleLibrary(home: tempHome)
    }

    func testEnsureRejectsSymlinkSupportDirectory() throws {
        let paths = SupportPaths(homeDirectory: tempHome)
        let parent = paths.applicationSupport.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // 诱饵放在临时家目录之外，避免污染 BattCycle Library 树的枚举断言。
        let decoy = FileManager.default.temporaryDirectory
            .appendingPathComponent("BattCycle-SupportPaths-decoy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: decoy)
        }
        try FileManager.default.createSymbolicLink(at: paths.applicationSupport, withDestinationURL: decoy)

        XCTAssertThrowsError(try paths.ensurePrivateDirectories()) { error in
            guard let pathError = error as? SupportPathError,
                  case .symbolicLink = pathError else {
                XCTFail("期望 symbolicLink，实际 \(error)")
                return
            }
        }
    }

    func testEnsureRejectsFileInPlaceOfLogsDirectory() throws {
        let paths = SupportPaths(homeDirectory: tempHome)
        let logsParent = paths.logs.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logsParent, withIntermediateDirectories: true)
        try Data().write(to: paths.logs)

        XCTAssertThrowsError(try paths.ensurePrivateDirectories()) { error in
            guard let pathError = error as? SupportPathError,
                  case .notDirectory = pathError else {
                XCTFail("期望 notDirectory，实际 \(error)")
                return
            }
        }
    }

    func testStaticAccessorsMatchLiveInstance() {
        let live = SupportPaths.live
        XCTAssertEqual(SupportPaths.applicationSupport, live.applicationSupport)
        XCTAssertEqual(SupportPaths.logs, live.logs)
        XCTAssertEqual(SupportPaths.config, live.config)
        XCTAssertEqual(SupportPaths.monitor, live.monitor)
        XCTAssertEqual(SupportPaths.historyDirectory, live.historyDirectory)
        XCTAssertEqual(SupportPaths.guardianHeartbeat, live.guardianHeartbeat)
        XCTAssertEqual(SupportPaths.controlLock, live.controlLock)
        XCTAssertEqual(SupportPaths.latestLog, live.latestLog)
        XCTAssertEqual(SupportPaths.pythonExecutable, live.pythonExecutable)
    }

    private func assertLibraryOnly(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let path = url.path
        XCTAssertTrue(path.contains("/Library/Application Support/BattCycle") || path.contains("/Library/Logs/BattCycle"), file: file, line: line)
        XCTAssertFalse(path.contains("/Desktop"), file: file, line: line)
        XCTAssertFalse(path.contains("/Documents"), file: file, line: line)
    }

    private func assertNoLaunchAgentOrICloud(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let path = url.path
        for forbidden in ["LaunchAgents", "LaunchDaemons", "Mobile Documents", "iCloud Drive", "PrivilegedHelperTools"] {
            XCTAssertFalse(path.contains(forbidden), "\(url.path) 不得包含 \(forbidden)", file: file, line: line)
        }
    }

    private func assertMode700(_ directory: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(Int(truncating: try XCTUnwrap(mode)) & 0o777, 0o700)
    }

    /// 注入家目录下只允许 Library/Application Support/BattCycle 与 Library/Logs/BattCycle 两棵树。
    private func assertCreatedPathsStayInBattCycleLibrary(home: URL) throws {
        let supportRoot = home.appendingPathComponent("Library/Application Support/BattCycle", isDirectory: true)
            .resolvingSymlinksInPath().path
        let logsRoot = home.appendingPathComponent("Library/Logs/BattCycle", isDirectory: true)
            .resolvingSymlinksInPath().path
        let library = home.appendingPathComponent("Library", isDirectory: true).resolvingSymlinksInPath().path
        let appSupportParent = home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .resolvingSymlinksInPath().path
        let logsParent = home.appendingPathComponent("Library/Logs", isDirectory: true).resolvingSymlinksInPath().path

        let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            let path = item.resolvingSymlinksInPath().path
            let allowed =
                path == library
                || path == appSupportParent
                || path == logsParent
                || path == supportRoot
                || path.hasPrefix(supportRoot + "/")
                || path == logsRoot
                || path.hasPrefix(logsRoot + "/")
            XCTAssertTrue(allowed, "测试不得写到 BattCycle Library 目录之外：\(item.path)")
        }
    }
}

import Foundation

/// 监测与历史记录设置，只存放于 monitor.json。
///
/// 历史键（`historyIntervalSeconds` / `recordingPaused` / `retentionDays` / `lastModified`）
/// 不得写入引擎 `config.json`。config.json 仍只保留 6 键：
/// `upperLimit`、`lowerLimit`、`gpuSize`、`cpuJobs`、`pollSeconds`、`stopAtEpoch`。
///
/// `recordingPaused` 只暂停历史采样落盘，不改变适配器状态，也不驱动循环引擎，更不改心跳 2 秒。
public struct MonitorSettings: Equatable, Sendable {
    public static let presetIntervals = [2, 5, 10, 30, 60, 300]
    public static let allowedRetentionDays = [7, 30, 90]
    /// 历史采集间隔边界（秒），与 SamplingPolicy.allowedHistoryRange 对齐；不是引擎 pollSeconds。
    public static let intervalRange = 2...3600
    /// monitor.json 的全部字段。与引擎 6 键无交集。
    public static let jsonKeys: Set<String> = [
        "historyIntervalSeconds",
        "recordingPaused",
        "retentionDays",
        "lastModified"
    ]
    /// 引擎 config.json 的 6 键，供加载时拒绝混入。
    public static let engineConfigJSONKeys: Set<String> = [
        "upperLimit", "lowerLimit", "gpuSize", "cpuJobs", "pollSeconds", "stopAtEpoch"
    ]

    public var historyIntervalSeconds: Int
    public var recordingPaused: Bool
    public var retentionDays: Int
    public var lastModified: Date

    public init(
        historyIntervalSeconds: Int = 10,
        recordingPaused: Bool = false,
        retentionDays: Int = 30,
        lastModified: Date = Date()
    ) {
        self.historyIntervalSeconds = historyIntervalSeconds
        self.recordingPaused = recordingPaused
        self.retentionDays = retentionDays
        self.lastModified = lastModified
    }

    public static var `default`: MonitorSettings { MonitorSettings() }

    public func validated() throws -> MonitorSettings {
        guard Self.intervalRange.contains(historyIntervalSeconds) else {
            throw MonitorSettingsError.intervalOutOfRange
        }
        guard Self.allowedRetentionDays.contains(retentionDays) else {
            throw MonitorSettingsError.retentionUnsupported
        }
        return self
    }

    public static func load(from url: URL) throws -> MonitorSettings {
        let data = try Data(contentsOf: url)
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw MonitorSettingsError.notObject
        }

        let keys = Set(object.keys)
        let unknown = keys.subtracting(Self.jsonKeys)
        if !unknown.isEmpty {
            throw MonitorSettingsError.unknownKeys(unknown.sorted())
        }
        let missing = Self.jsonKeys.subtracting(keys)
        if !missing.isEmpty {
            throw MonitorSettingsError.missingKeys(missing.sorted())
        }

        let interval = try strictInt(object["historyIntervalSeconds"], name: "historyIntervalSeconds")
        let paused = try strictBool(object["recordingPaused"], name: "recordingPaused")
        let retention = try strictInt(object["retentionDays"], name: "retentionDays")
        let modified = try strictDate(object["lastModified"], name: "lastModified")
        return try MonitorSettings(
            historyIntervalSeconds: interval,
            recordingPaused: paused,
            retentionDays: retention,
            lastModified: modified
        ).validated()
    }

    public func save(to url: URL, now: Date = Date()) throws {
        var copy = try validated()
        copy.lastModified = now
        let payload: [String: Any] = [
            "historyIntervalSeconds": copy.historyIntervalSeconds,
            "recordingPaused": copy.recordingPaused,
            "retentionDays": copy.retentionDays,
            "lastModified": HistorySample.iso8601String(from: copy.lastModified)
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func strictInt(_ raw: Any?, name: String) throws -> Int {
        guard let raw else { throw MonitorSettingsError.invalidType(name) }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                throw MonitorSettingsError.invalidType(name)
            }
            let value = number.doubleValue
            guard value.rounded(.towardZero) == value else {
                throw MonitorSettingsError.invalidType(name)
            }
            return number.intValue
        }
        throw MonitorSettingsError.invalidType(name)
    }

    private static func strictBool(_ raw: Any?, name: String) throws -> Bool {
        guard let raw else { throw MonitorSettingsError.invalidType(name) }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        throw MonitorSettingsError.invalidType(name)
    }

    private static func strictDate(_ raw: Any?, name: String) throws -> Date {
        guard let text = raw as? String, let date = HistorySample.parseISO8601(text) else {
            throw MonitorSettingsError.invalidLastModified
        }
        _ = name
        return date
    }
}

public enum MonitorSettingsError: LocalizedError {
    case notObject
    case unknownKeys([String])
    case missingKeys([String])
    case invalidType(String)
    case intervalOutOfRange
    case retentionUnsupported
    case invalidLastModified

    public var errorDescription: String? {
        switch self {
        case .notObject:
            return "monitor.json 顶层必须是 JSON 对象"
        case .unknownKeys(let keys):
            return "monitor.json 包含未知字段: \(keys.joined(separator: ", "))"
        case .missingKeys(let keys):
            return "monitor.json 缺少字段: \(keys.joined(separator: ", "))"
        case .invalidType(let name):
            return "monitor.json 字段 \(name) 类型无效"
        case .intervalOutOfRange:
            return "历史采样间隔需要在 2 到 3600 秒之间"
        case .retentionUnsupported:
            return "历史保留天数只支持 7 / 30 / 90"
        case .invalidLastModified:
            return "lastModified 必须是 ISO8601 时间"
        }
    }
}
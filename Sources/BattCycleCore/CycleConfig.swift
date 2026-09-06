import Foundation

/// 循环引擎配置，对应 `config.json` 的恰好 6 个键。
/// 监测/历史字段（如 `historyIntervalSeconds`）属于 `monitor.json`，禁止混入本结构。
public struct CycleConfig: Codable, Equatable, Sendable {
    /// `config.json` 允许的全部键；数量必须保持为 6。
    public static let allowedJSONKeys: Set<String> = [
        "upperLimit",
        "lowerLimit",
        "gpuSize",
        "cpuJobs",
        "pollSeconds",
        "stopAtEpoch"
    ]

    /// 属于 monitor.json 的键，出现在 config.json 时一律拒绝。
    public static let forbiddenMonitorKeys: Set<String> = [
        "historyIntervalSeconds",
        "recordingPaused",
        "retentionDays",
        "lastModified"
    ]

    public var upperLimit: Int
    public var lowerLimit: Int
    public var gpuSize: Int
    public var cpuJobs: Int
    public var pollSeconds: Int
    public var stopAtEpoch: Int

    public init(
        upperLimit: Int = 80,
        lowerLimit: Int = 30,
        gpuSize: Int = 2048,
        cpuJobs: Int = 4,
        pollSeconds: Int = 10,
        stopAtEpoch: Int = 0
    ) {
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
        self.gpuSize = gpuSize
        self.cpuJobs = cpuJobs
        self.pollSeconds = pollSeconds
        self.stopAtEpoch = stopAtEpoch
    }

    public static var `default`: CycleConfig {
        var config = CycleConfig()
        config.applyDefaultStopIfNeeded()
        return config
    }

    public var stopDate: Date {
        get { Date(timeIntervalSince1970: TimeInterval(stopAtEpoch)) }
        set { stopAtEpoch = Int(newValue.timeIntervalSince1970) }
    }

    public mutating func applyDefaultStopIfNeeded(now: Date = Date()) {
        if stopAtEpoch <= Int(now.timeIntervalSince1970) {
            let nextSeven = Self.nextOccurrence(hour: 7, minute: 0, now: now)
            stopDate = min(nextSeven, now.addingTimeInterval(86_400))
        }
    }

    public static func nextOccurrence(hour: Int, minute: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        let today = calendar.date(from: parts) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    /// 严格解析 config.json：必须恰好 6 个键，并校验 pollSeconds 与循环百分比边界。
    /// 本函数不调用 batt，也不把监测字段写进配置。
    public static func parse(_ json: String, now: Date = Date()) throws -> CycleConfig {
        try parse(Data(json.utf8), now: now)
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> CycleConfig {
        try JSONDecoder().decode(CycleConfig.self, from: data).validated(now: now)
    }

    public static func load(from url: URL, now: Date = Date()) throws -> CycleConfig {
        try parse(Data(contentsOf: url), now: now)
    }

    /// 校验循环百分比、pollSeconds（5–60）以及停止时间。不改写任何字段。
    public func validated(now: Date = Date()) throws -> CycleConfig {
        try validateStaticBounds()
        let remaining = TimeInterval(stopAtEpoch) - now.timeIntervalSince1970
        if remaining <= 0 {
            throw ConfigError.stopTimeNotInFuture
        }
        if remaining > 86_400 {
            throw ConfigError.stopTimeTooFarAway
        }
        return self
    }

    /// 与 `now` 无关的边界：循环百分比、回差、负载与 pollSeconds。
    private func validateStaticBounds() throws {
        guard (50...100).contains(upperLimit) else {
            throw ConfigError.upperLimitOutOfRange
        }
        guard (20...80).contains(lowerLimit) else {
            throw ConfigError.lowerLimitOutOfRange
        }
        if upperLimit - lowerLimit < 5 {
            throw ConfigError.insufficientHysteresis
        }
        if !(1...16).contains(cpuJobs) {
            throw ConfigError.cpuJobsOutOfRange
        }
        if ![2048, 4096, 8192].contains(gpuSize) {
            throw ConfigError.gpuSizeUnsupported
        }
        if !(5...60).contains(pollSeconds) {
            throw ConfigError.pollSecondsOutOfRange
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case upperLimit
        case lowerLimit
        case gpuSize
        case cpuJobs
        case pollSeconds
        case stopAtEpoch
    }

    public init(from decoder: Decoder) throws {
        let extras = try decoder.container(keyedBy: AnyJSONKey.self)
        let present = Set(extras.allKeys.map(\.stringValue))
        try Self.rejectUnexpectedKeys(present)

        let container = try decoder.container(keyedBy: CodingKeys.self)
        upperLimit = try container.decode(Int.self, forKey: .upperLimit)
        lowerLimit = try container.decode(Int.self, forKey: .lowerLimit)
        gpuSize = try container.decode(Int.self, forKey: .gpuSize)
        cpuJobs = try container.decode(Int.self, forKey: .cpuJobs)
        pollSeconds = try container.decode(Int.self, forKey: .pollSeconds)
        stopAtEpoch = try container.decode(Int.self, forKey: .stopAtEpoch)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(upperLimit, forKey: .upperLimit)
        try container.encode(lowerLimit, forKey: .lowerLimit)
        try container.encode(gpuSize, forKey: .gpuSize)
        try container.encode(cpuJobs, forKey: .cpuJobs)
        try container.encode(pollSeconds, forKey: .pollSeconds)
        try container.encode(stopAtEpoch, forKey: .stopAtEpoch)
    }

    private static func rejectUnexpectedKeys(_ present: Set<String>) throws {
        let unknown = present.subtracting(allowedJSONKeys)
        if !unknown.isEmpty {
            let monitor = unknown.filter { forbiddenMonitorKeys.contains($0) }
            if !monitor.isEmpty {
                throw ConfigError.monitorKeysNotAllowed(monitor.sorted())
            }
            throw ConfigError.unknownKeys(unknown.sorted())
        }
        let missing = allowedJSONKeys.subtracting(present)
        if !missing.isEmpty {
            throw ConfigError.missingKeys(missing.sorted())
        }
    }

    public enum ConfigError: LocalizedError {
        case upperLimitOutOfRange
        case lowerLimitOutOfRange
        case insufficientHysteresis
        case cpuJobsOutOfRange
        case gpuSizeUnsupported
        case pollSecondsOutOfRange
        case stopTimeNotInFuture
        case stopTimeTooFarAway
        case unknownKeys([String])
        case missingKeys([String])
        case monitorKeysNotAllowed([String])

        public var errorDescription: String? {
            switch self {
            case .upperLimitOutOfRange:
                return "上限需要在 50% 到 100% 之间"
            case .lowerLimitOutOfRange:
                return "下限需要在 20% 到 80% 之间"
            case .insufficientHysteresis:
                return "上下限之间至少需要保留 5% 的间隔"
            case .cpuJobsOutOfRange:
                return "CPU 线程数需要在 1 到 16 之间"
            case .gpuSizeUnsupported:
                return "GPU size 只支持 2048 / 4096 / 8192"
            case .pollSecondsOutOfRange:
                return "轮询间隔需要在 5 到 60 秒之间"
            case .stopTimeNotInFuture:
                return "停止时间必须晚于现在"
            case .stopTimeTooFarAway:
                return "单次运行最长 24 小时"
            case .unknownKeys(let keys):
                return "config.json 包含未知字段: \(keys.joined(separator: ", "))"
            case .missingKeys(let keys):
                return "config.json 缺少字段: \(keys.joined(separator: ", "))"
            case .monitorKeysNotAllowed(let keys):
                return "config.json 不得包含监测/历史字段（属于 monitor.json）: \(keys.joined(separator: ", "))"
            }
        }
    }
}

/// JSON 任意键，用于拒绝 config.json 中的未知字段。
private struct AnyJSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// 引擎运行时状态（state.json），不是 config.json 的一部分。
public struct EngineState: Codable, Equatable, Sendable {
    public var phase: String
    public var percent: Int
    public var pid: Int
    public var stopAtEpoch: Int
    public var upper: Int
    public var lower: Int
    public var updatedAt: String
    public var updatedEpoch: Int
    public var log: String
    public var running: Bool
    public var error: String?

    public static var idle: EngineState {
        EngineState(
            phase: "idle",
            percent: 0,
            pid: 0,
            stopAtEpoch: 0,
            upper: 80,
            lower: 30,
            updatedAt: "",
            updatedEpoch: 0,
            log: "",
            running: false,
            error: nil
        )
    }
}

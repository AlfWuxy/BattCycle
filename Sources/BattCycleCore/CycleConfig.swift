import Foundation

public struct CycleConfig: Codable, Equatable, Sendable {
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

    public func validated(now: Date = Date()) throws -> CycleConfig {
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
        let remaining = TimeInterval(stopAtEpoch) - now.timeIntervalSince1970
        if remaining <= 0 {
            throw ConfigError.stopTimeNotInFuture
        }
        if remaining > 86_400 {
            throw ConfigError.stopTimeTooFarAway
        }
        return self
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
            }
        }
    }
}

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

import Foundation

/// 采样时钟策略：三条时钟必须各自独立，禁止互相改写。
///
/// 1. UI / App 守护心跳：固定 `heartbeatSeconds` = 2，写入 guardian.json，用户不可设。
/// 2. 历史曲线采集：`historyInterval`，推荐 2 / 5 / 10 / 30 / 60 / 300，自定义 `allowedHistoryRange` 2...3600。
///    只写入 monitor.json，不得进入引擎 config.json。
/// 3. 引擎安全轮询：`enginePollSeconds`，从 `CycleConfig.pollSeconds` 拷贝；合法范围 5...60 由 CycleConfig 校验。
///
/// 本类型不提供“用历史间隔去改心跳或引擎轮询”的 API，避免把安全采样放松成曲线采样。
public struct SamplingPolicy: Equatable, Sendable {
    /// 用户可设的历史采集间隔（秒）。变更不得改写心跳或引擎轮询。
    public var historyInterval: TimeInterval

    /// 引擎安全轮询间隔（秒），从 `CycleConfig.pollSeconds` 拷贝，独立存储。
    /// 本类型不校验 5...60：那是 `CycleConfig` 的职责，避免历史键渗入引擎配置。
    public var enginePollSeconds: Int

    /// App 守护心跳固定间隔（秒）。与历史间隔、引擎轮询都无关。
    public static let heartbeatSeconds: TimeInterval = 2

    /// 推荐的历史采集档位（秒）。与心跳 2 秒、引擎 5...60 秒不是同一条时钟。
    public static let recommendedHistoryIntervals: [TimeInterval] = [2, 5, 10, 30, 60, 300]

    /// 自定义历史采集允许范围（秒）。不含把心跳或引擎轮询“放松”的通道。
    public static let allowedHistoryRange: ClosedRange<TimeInterval> = 2...3_600

    /// 心跳间隔永远是 2 秒；只读，避免被历史间隔或外部赋值改写。
    public var heartbeatInterval: TimeInterval {
        Self.heartbeatSeconds
    }

    public init(historyInterval: TimeInterval = 10, enginePollSeconds: Int = 10) {
        self.historyInterval = historyInterval
        self.enginePollSeconds = enginePollSeconds
    }

    /// 从 monitor.json 的历史键与引擎 pollSeconds 组装策略；两路输入不得互相覆盖。
    public init(monitor: MonitorSettings, enginePollSeconds: Int) {
        self.init(
            historyInterval: TimeInterval(monitor.historyIntervalSeconds),
            enginePollSeconds: enginePollSeconds
        )
    }

    /// 校验历史间隔边界 2...3600。不检查、不改写 `enginePollSeconds`（那是 `CycleConfig` 的职责）。
    public func validated() throws -> SamplingPolicy {
        guard historyInterval.isFinite, Self.allowedHistoryRange.contains(historyInterval) else {
            throw PolicyError.historyIntervalOutOfRange
        }
        return self
    }

    /// 是否应写入一个真实的历史样本。暂停、休眠时返回 false，且不会生成补点。
    public func shouldRecordHistory(
        now: Date,
        lastHistoryAt: Date?,
        paused: Bool,
        sleeping: Bool
    ) -> Bool {
        guard !paused, !sleeping else { return false }
        guard let lastHistoryAt else { return true }
        return now.timeIntervalSince(lastHistoryAt) >= historyInterval
    }

    /// 心跳与历史采集独立：只要进程未退出，就按固定 2 秒判断，不受暂停/休眠/历史间隔影响。
    public func shouldWriteHeartbeat(
        now: Date,
        lastHeartbeatAt: Date?,
        processExiting: Bool
    ) -> Bool {
        guard !processExiting else { return false }
        guard let lastHeartbeatAt else { return true }
        return now.timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval
    }

    /// UI「下一次采集时间」。只做历史间隔算术，不读取引擎轮询。
    public func nextSampleAt(from last: Date) -> Date {
        last.addingTimeInterval(historyInterval)
    }

    public enum PolicyError: LocalizedError {
        case historyIntervalOutOfRange

        public var errorDescription: String? {
            switch self {
            case .historyIntervalOutOfRange:
                return "历史采集间隔需要在 2 到 3600 秒之间"
            }
        }
    }
}

/// App 层在收到系统休眠/唤醒通知后调用。Core 不注册 AppKit 观察者。
public protocol SleepWakeHandling: AnyObject {
    /// 系统即将休眠：停止历史采样，并标记唤醒后存在真实缺口。
    func onSleep()
    /// 系统已唤醒：恢复采样，不回填休眠期间的样本。
    func onWake()
}

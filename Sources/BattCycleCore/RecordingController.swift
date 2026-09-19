import Foundation

/// 历史记录纯状态机：不 IO、不观察 AppKit、不改适配器、不停止循环引擎。
///
/// 三条时钟在此保持分离：
/// - 心跳：`shouldWriteHeartbeat` 固定 2 秒，暂停期间仍为 true（进程退出除外）
/// - 历史：`shouldRecordHistory` 只按 `policy.historyInterval`，暂停时必须跳过追加且不抛错
/// - 引擎：`policy.enginePollSeconds` 只读拷贝，pause/resume/改历史间隔都不得改写
///
/// 暂停：不再产生历史样本，但守护心跳仍应按 2 秒写入（由 App 层继续调用心跳判定）。
/// 休眠：不产生历史样本，`needsGap == true`；唤醒后只采真实点，不回填。
public final class RecordingController: SleepWakeHandling {
    public enum State: Equatable, Sendable {
        /// 尚未 `start`。
        case idle
        /// 正在按历史间隔采集。
        case recording
        /// 用户暂停历史记录。心跳仍应继续。
        case paused
        /// 系统休眠。历史采样停止，缺口待标记。
        case sleeping
        /// 应用即将退出。历史与心跳均停止。
        case stopped
    }

    public var policy: SamplingPolicy
    public private(set) var state: State
    /// 唤醒后下一次真实样本应标记为缺口；本机不生成休眠期补点。
    public private(set) var needsGap: Bool

    /// 休眠前的状态，唤醒后还原（暂停保持暂停，不会被唤醒自动继续采集）。
    private var stateBeforeSleep: State?

    public init(policy: SamplingPolicy) {
        self.policy = policy
        self.state = .idle
        self.needsGap = false
    }

    /// 开始历史采集。已启动或已退出时是空操作，防止重复 start。
    public func start() {
        switch state {
        case .idle:
            state = .recording
        case .recording, .paused, .sleeping, .stopped:
            return
        }
    }

    /// 暂停历史采样。不改变 `enginePollSeconds`，不停止循环，不改适配器。
    public func pause() {
        switch state {
        case .recording:
            state = .paused
        case .sleeping:
            if stateBeforeSleep == .recording || stateBeforeSleep == .idle {
                stateBeforeSleep = .paused
            }
        case .idle, .paused, .stopped:
            return
        }
    }

    /// 从用户暂停恢复历史采样。休眠中只更新唤醒后目标状态。
    public func resume() {
        switch state {
        case .paused:
            state = .recording
        case .sleeping:
            if stateBeforeSleep == .paused {
                stateBeforeSleep = .recording
            }
        case .idle, .recording, .stopped:
            return
        }
    }

    /// 系统即将休眠。不写历史点；标记真实缺口。心跳判定仍可询问（进程冻结前）。
    public func systemWillSleep() {
        onSleep()
    }

    /// 系统已唤醒。不回填休眠区间。
    public func systemDidWake() {
        onWake()
    }

    public func onSleep() {
        guard state != .stopped, state != .sleeping else { return }
        stateBeforeSleep = state
        needsGap = true
        state = .sleeping
    }

    public func onWake() {
        guard state == .sleeping else { return }
        let restored = stateBeforeSleep ?? .recording
        stateBeforeSleep = nil
        switch restored {
        case .idle, .recording, .paused, .stopped:
            state = restored
        case .sleeping:
            state = .recording
        }
    }

    /// 应用即将退出。此后不再写历史，也不再写心跳。
    public func appWillTerminate() {
        state = .stopped
        stateBeforeSleep = nil
    }

    /// 是否应追加一个真实历史点。暂停 / 休眠 / 未启动 / 已退出一律跳过，且永不抛错、不伪造样本。
    /// 调用方应在本方法为 false 时直接跳过 `HistoryStore.append`，不要当成失败。
    public func shouldRecordHistory(now: Date, lastHistoryAt: Date?) -> Bool {
        switch state {
        case .recording:
            break
        case .idle, .paused, .sleeping, .stopped:
            return false
        }
        return policy.shouldRecordHistory(
            now: now,
            lastHistoryAt: lastHistoryAt,
            paused: false,
            sleeping: false
        )
    }

    /// 心跳独立于历史状态：仅在进程退出时停止；暂停期间仍应写入。
    public func shouldWriteHeartbeat(now: Date, lastHeartbeatAt: Date?) -> Bool {
        policy.shouldWriteHeartbeat(
            now: now,
            lastHeartbeatAt: lastHeartbeatAt,
            processExiting: state == .stopped
        )
    }

    /// UI「下一次采集时间」。直接按当前 `policy.historyInterval` 计算，改间隔无需重启应用。
    public func nextSampleAt(from last: Date) -> Date {
        policy.nextSampleAt(from: last)
    }

    /// 消费缺口标记。返回本次是否为休眠后的真实缺口；永不生成中间点。
    @discardableResult
    public func consumeGapIfNeeded() -> Bool {
        guard needsGap else { return false }
        needsGap = false
        return true
    }
}

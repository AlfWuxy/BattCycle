import Foundation

/// 快照可信度：新鲜可信 / 过期 / 捕获失败 / 标志冲突。
public enum DataTrust: Equatable, Sendable {
    case trusted
    case stale
    case unavailable
    case conflicting
}

public enum DataTrustEvaluator {
    /// 按是否捕获成功、以及采样时刻相对轮询间隔的年龄判断。
    /// `now - capturedAt > interval` 视为 stale；捕获失败或缺 `IsCharging` / `Power Source State` 视为 unavailable。
    public static func evaluate(
        isAvailable: Bool,
        capturedAt: Date,
        now: Date = Date(),
        interval: TimeInterval,
        conflicting: Bool = false
    ) -> DataTrust {
        guard isAvailable else { return .unavailable }
        if conflicting { return .conflicting }
        if now.timeIntervalSince(capturedAt) > interval { return .stale }
        return .trusted
    }

    public static func evaluate(
        snapshot: BatterySnapshot,
        now: Date = Date(),
        interval: TimeInterval
    ) -> DataTrust {
        evaluate(
            isAvailable: snapshot.isCompleteForDataTrust,
            capturedAt: snapshot.capturedAt,
            now: now,
            interval: interval,
            conflicting: isConflicting(snapshot)
        )
    }

    /// 充电标志为真，但电池侧功率明显为负，视为冲突。缺 `IsCharging` 不算冲突。
    public static func isConflicting(_ snapshot: BatterySnapshot) -> Bool {
        guard snapshot.isChargingIsAvailable else { return false }
        return isConflicting(
            isCharging: snapshot.isCharging,
            wattsIsAvailable: snapshot.wattsIsAvailable,
            watts: snapshot.watts
        )
    }

    public static func isConflicting(
        isCharging: Bool,
        wattsIsAvailable: Bool,
        watts: Double
    ) -> Bool {
        wattsIsAvailable && isCharging && watts < -EnergyFlow.idlePowerThresholdWatts
    }
}

import Foundation

/// 单次节拍的纯派生结果。调用方必须只 `capture()` 一次。
public struct TickSnapshot: Equatable, Sendable {
    public var snapshot: BatterySnapshot
    public var flow: EnergyFlow
    public var metrics: PowerMetrics
    public var trust: DataTrust

    public init(
        snapshot: BatterySnapshot,
        flow: EnergyFlow,
        metrics: PowerMetrics,
        trust: DataTrust
    ) {
        self.snapshot = snapshot
        self.flow = flow
        self.metrics = metrics
        self.trust = trust
    }
}

/// 心跳节拍的纯派生入口。不 capture、不写 batt、不读 IOKit。
public enum SnapshotTick {
    /// 建议只使用最近 1 小时样本，禁止把 30 天 JSONL 送进 AdviceEngine。
    public static let adviceLookbackRange: HistoryRange = .hours1

    /// `provider.capture()` 由调用方执行一次。本函数只根据已捕获快照派生。
    public static func derive(
        snapshot: BatterySnapshot,
        now: Date,
        heartbeatInterval: TimeInterval
    ) -> TickSnapshot {
        let pair = metricsAndFlow(from: snapshot)
        let trust = DataTrustEvaluator.evaluate(
            snapshot: snapshot,
            now: now,
            interval: heartbeatInterval
        )
        return TickSnapshot(
            snapshot: snapshot,
            flow: pair.flow,
            metrics: pair.metrics,
            trust: trust
        )
    }
}

/// 由同一快照组装功率指标与能量流向。不调用 capture，不读 IOKit。
public func metricsAndFlow(from snapshot: BatterySnapshot) -> (metrics: PowerMetrics, flow: EnergyFlow) {
    (
        PowerMetrics.assemble(snapshot: snapshot),
        EnergyFlow.classify(snapshot)
    )
}

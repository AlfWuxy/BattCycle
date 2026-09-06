import Foundation

extension PowerDirection {
    /// 写入 JSONL 的方向字符串，与 `EnergyFlowDirection` 对齐。
    public var historyDirectionRawValue: String {
        switch self {
        case .charging:
            return EnergyFlowDirection.charge.rawValue
        case .discharging:
            return EnergyFlowDirection.discharge.rawValue
        case .idle:
            return EnergyFlowDirection.idle.rawValue
        case .unknown:
            return EnergyFlowDirection.unknown.rawValue
        }
    }
}

extension HistorySample {
    /// 由实时快照与引擎字段组装历史点。
    /// 百分比/瓦数仅在快照标记可用时写入，缺失保持 nil，绝不填 0。
    /// 瓦数只取电池侧净功率，禁止用适配器额定/协商功率或 `chargeRateWatts` 回填。
    /// `pluggedIn` / `useAdapter` 透传 batt 的 `Bool?`：缺失为 nil，不得写成 false，也不得用 IOKit AC 状态冒充。
    /// `intervalSeconds` 取该次写入策略；`segmentId` 由调用方传入（本工厂不生成）。
    /// `sleepGap` 仅对显式间隙样本为 true；false 与 nil 均视为缺省，编码时省略。
    public static func makeLive(
        at date: Date,
        snapshot: BatterySnapshot,
        direction: PowerDirection,
        battStatus: BattStatusSnapshot?,
        thermal: String?,
        enginePhase: String?,
        recordingPaused: Bool,
        intervalSeconds: Int? = nil,
        segmentId: String? = nil,
        sleepGap: Bool? = nil
    ) -> HistorySample {
        // 电池侧可选瓦数：不可用时保持 nil。适配器功率字段故意不参与。
        let batteryWatts: Double? = snapshot.wattsIsAvailable ? snapshot.watts : nil
        return HistorySample(
            at: date,
            percent: snapshot.percentIsAvailable ? snapshot.percent : nil,
            watts: batteryWatts,
            wattsAvailable: snapshot.wattsIsAvailable,
            direction: direction.historyDirectionRawValue,
            pluggedIn: battStatus?.pluggedIn,
            useAdapter: battStatus?.useAdapter,
            thermal: thermal,
            enginePhase: enginePhase,
            recordingPaused: recordingPaused,
            sleepGap: sleepGap == true ? true : nil,
            intervalSeconds: intervalSeconds,
            segmentId: segmentId
        )
    }

    /// 由快照与 `EnergyFlow` 组装历史点；间隔取该次 tick 的写入策略。
    public static func makeLive(
        at date: Date,
        snapshot: BatterySnapshot,
        flow: EnergyFlow,
        battStatus: BattStatusSnapshot?,
        thermal: String?,
        enginePhase: String?,
        recordingPaused: Bool,
        intervalSeconds: Int? = nil,
        segmentId: String? = nil,
        sleepGap: Bool? = nil
    ) -> HistorySample {
        makeLive(
            at: date,
            snapshot: snapshot,
            direction: flow.direction,
            battStatus: battStatus,
            thermal: thermal,
            enginePhase: enginePhase,
            recordingPaused: recordingPaused,
            intervalSeconds: intervalSeconds,
            segmentId: segmentId,
            sleepGap: sleepGap
        )
    }
}

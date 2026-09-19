import Foundation

/// 能量与功率统计均为估算（估算）。
/// 缺失功率不当作 0；超过间隙阈值的间隔不积分，避免把睡眠当成放电。
public struct EnergyEstimates: Equatable, Sendable {
    public static let estimateLabel = "估算"

    public let isEstimate: Bool
    public let energyInWh: Double
    public let energyOutWh: Double
    public let netWh: Double
    public let meanChargeW: Double?
    public let meanDischargeW: Double?
    public let peakInW: Double?
    public let peakOutW: Double?
    public let durationUsingAdapter: TimeInterval?
    public let durationOnBattery: TimeInterval?
    public let completeness: Double

    public init(
        isEstimate: Bool = true,
        energyInWh: Double,
        energyOutWh: Double,
        netWh: Double,
        meanChargeW: Double?,
        meanDischargeW: Double?,
        peakInW: Double?,
        peakOutW: Double?,
        durationUsingAdapter: TimeInterval?,
        durationOnBattery: TimeInterval?,
        completeness: Double
    ) {
        self.isEstimate = true
        self.energyInWh = energyInWh
        self.energyOutWh = energyOutWh
        self.netWh = netWh
        self.meanChargeW = meanChargeW
        self.meanDischargeW = meanDischargeW
        self.peakInW = peakInW
        self.peakOutW = peakOutW
        self.durationUsingAdapter = durationUsingAdapter
        self.durationOnBattery = durationOnBattery
        self.completeness = min(1, max(0, completeness))
        _ = isEstimate
    }

    /// 能量间隙：2.5 倍采样间隔与 15 分钟取较小值。
    public static func gapThreshold(intervalSeconds: Int) -> TimeInterval {
        min(2.5 * TimeInterval(max(intervalSeconds, 1)), 15 * 60)
    }

    /// 数组入口保留乱序兼容；排序后的每个样本仍交给同一常量空间累加器。
    public static func estimate(
        samples: [HistorySample],
        from start: Date,
        to end: Date,
        intervalSeconds: Int
    ) -> EnergyEstimates {
        let ordered = samples
            .filter { $0.epoch.isFinite && $0.epoch >= start.timeIntervalSince1970 && $0.epoch <= end.timeIntervalSince1970 }
            .sorted { $0.epoch < $1.epoch }
        var accumulator = EnergyAccumulator(from: start, to: end, intervalSeconds: intervalSeconds)
        for sample in ordered {
            // 排序后的有限时间戳不会触发逆序错误。
            try? accumulator.append(sample)
        }
        return accumulator.finish()
    }

    /// 全量流入口不保留样本数组；读取错误或时间倒退直接抛出，不返回部分窗口的估算。
    public static func estimateStream(
        from start: Date,
        to end: Date,
        intervalSeconds: Int,
        samples: (_ consume: (HistorySample) throws -> Void) throws -> Void
    ) throws -> EnergyEstimates {
        var accumulator = EnergyAccumulator(from: start, to: end, intervalSeconds: intervalSeconds)
        try samples { sample in try accumulator.append(sample) }
        return accumulator.finish()
    }

    /// App 与性能回归共用的历史路径：完整 JSONL 流，独立于图表下采样。
    public static func estimateHistory(
        store: HistoryStore,
        range: HistoryRange,
        now: Date = Date(),
        intervalSeconds: Int
    ) throws -> EnergyEstimates {
        let window = range.window(now: now)
        let start = min(window.start, window.end)
        let end = max(window.start, window.end)
        return try estimateStream(from: start, to: end, intervalSeconds: intervalSeconds) { consume in
            try HistoryQuery.forEachSample(store: store, from: start, to: end, body: consume)
        }
    }

    /// 数据不足时的安全空估算。均值与峰值统一为 nil，不混用 0。
    fileprivate static func insufficientData() -> EnergyEstimates {
        EnergyEstimates(
            energyInWh: 0,
            energyOutWh: 0,
            netWh: 0,
            meanChargeW: nil,
            meanDischargeW: nil,
            peakInW: nil,
            peakOutW: nil,
            durationUsingAdapter: nil,
            durationOnBattery: nil,
            completeness: 0
        )
    }

    /// 过零梯形拆成正、负两段分别积分，禁止先净面积再按符号归类。
    fileprivate static func addTrapezoidEnergy(
        w0: Double,
        w1: Double,
        dt: TimeInterval,
        energyIn: inout Double,
        energyOut: inout Double,
        chargeSeconds: inout Double,
        dischargeSeconds: inout Double
    ) {
        if (w0 > 0 && w1 < 0) || (w0 < 0 && w1 > 0) {
            let span = w1 - w0
            guard span != 0, span.isFinite else { return }
            let fraction = -w0 / span
            guard fraction.isFinite, fraction > 0, fraction < 1 else { return }
            let firstDt = dt * fraction
            addSignedEnergy(
                w0: w0,
                w1: 0,
                dt: firstDt,
                energyIn: &energyIn,
                energyOut: &energyOut,
                chargeSeconds: &chargeSeconds,
                dischargeSeconds: &dischargeSeconds
            )
            addSignedEnergy(
                w0: 0,
                w1: w1,
                dt: dt - firstDt,
                energyIn: &energyIn,
                energyOut: &energyOut,
                chargeSeconds: &chargeSeconds,
                dischargeSeconds: &dischargeSeconds
            )
            return
        }
        addSignedEnergy(
            w0: w0,
            w1: w1,
            dt: dt,
            energyIn: &energyIn,
            energyOut: &energyOut,
            chargeSeconds: &chargeSeconds,
            dischargeSeconds: &dischargeSeconds
        )
    }

    private static func addSignedEnergy(
        w0: Double,
        w1: Double,
        dt: TimeInterval,
        energyIn: inout Double,
        energyOut: inout Double,
        chargeSeconds: inout Double,
        dischargeSeconds: inout Double
    ) {
        let areaWh = (w0 + w1) / 2.0 * (dt / 3600.0)
        if areaWh > 0 {
            energyIn += areaWh
            chargeSeconds += dt
        } else if areaWh < 0 {
            energyOut += -areaWh
            dischargeSeconds += dt
        }
    }

    fileprivate static func meanPower(energyWh: Double, seconds: TimeInterval, fallbackSum: Double, count: Int) -> Double? {
        if seconds > 0 {
            return energyWh * 3600.0 / seconds
        }
        if count > 0 {
            return fallbackSum / Double(count)
        }
        return nil
    }

}

public enum EnergyEstimationError: Error, Equatable, LocalizedError {
    case outOfOrder(previousEpoch: TimeInterval, currentEpoch: TimeInterval)

    public var errorDescription: String? {
        "历史记录时间倒退，能量估算不可用；请检查该时间窗口的记录。"
    }
}

/// 只保存前一点的标量与累计统计；内存占用不随样本数增长。
/// 逆序时间戳拒绝积分，重复时间戳不产生面积；缺失功率、睡眠与长间隙不会被连线补齐。
public struct EnergyAccumulator: Sendable {
    private struct Point: Sendable {
        let epoch: TimeInterval
        let watts: Double?
        let useAdapter: Bool?
        let pluggedIn: Bool?
        let intervalSeconds: Int?

        init(_ sample: HistorySample) {
            epoch = sample.epoch
            watts = sample.integrableWatts.flatMap { $0.isFinite ? $0 : nil }
            useAdapter = sample.useAdapter
            pluggedIn = sample.pluggedIn
            intervalSeconds = sample.intervalSeconds
        }

        var onBattery: Bool? {
            if let useAdapter { return !useAdapter }
            return pluggedIn == false ? true : nil
        }
    }

    private let startEpoch: TimeInterval
    private let endEpoch: TimeInterval
    private let intervalSeconds: Int
    private var previous: Point?
    private var sampleCount = 0
    private var energyIn = 0.0
    private var energyOut = 0.0
    private var chargeSeconds = 0.0
    private var dischargeSeconds = 0.0
    private var adapterSeconds = 0.0
    private var batterySeconds = 0.0
    private var sawAdapterFlag = false
    private var sawBatteryFlag = false
    private var peakIn: Double?
    private var peakOut: Double?
    private var chargeSum = 0.0
    private var chargeCount = 0
    private var dischargeSum = 0.0
    private var dischargeCount = 0

    public init(from start: Date, to end: Date, intervalSeconds: Int) {
        startEpoch = start.timeIntervalSince1970
        endEpoch = end.timeIntervalSince1970
        self.intervalSeconds = max(1, intervalSeconds)
    }

    public mutating func append(_ sample: HistorySample) throws {
        guard sample.epoch.isFinite, sample.epoch >= startEpoch, sample.epoch <= endEpoch else { return }
        let current = Point(sample)
        if let previous, current.epoch < previous.epoch {
            throw EnergyEstimationError.outOfOrder(previousEpoch: previous.epoch, currentEpoch: current.epoch)
        }
        sampleCount += 1
        if let watts = current.watts {
            if watts > 0 {
                peakIn = max(peakIn ?? watts, watts)
                chargeSum += watts
                chargeCount += 1
            } else if watts < 0 {
                let magnitude = -watts
                peakOut = max(peakOut ?? magnitude, magnitude)
                dischargeSum += magnitude
                dischargeCount += 1
            }
        }
        defer { previous = current }
        guard let previous, sample.sleepGap != true else { return }
        let dt = current.epoch - previous.epoch
        // 使用写入当时的间隔，不用当前设置重解释旧段。
        let recordedInterval = current.intervalSeconds ?? previous.intervalSeconds ?? intervalSeconds
        guard dt > 0, dt <= EnergyEstimates.gapThreshold(intervalSeconds: recordedInterval) else { return }
        if let w0 = previous.watts, let w1 = current.watts {
            EnergyEstimates.addTrapezoidEnergy(
                w0: w0, w1: w1, dt: dt,
                energyIn: &energyIn, energyOut: &energyOut,
                chargeSeconds: &chargeSeconds, dischargeSeconds: &dischargeSeconds
            )
        }
        if let left = previous.useAdapter, let right = current.useAdapter {
            sawAdapterFlag = true
            sawBatteryFlag = true
            if left && right { adapterSeconds += dt }
            else if !left && !right { batterySeconds += dt }
        } else {
            if previous.useAdapter != nil || current.useAdapter != nil { sawAdapterFlag = true }
            if previous.onBattery != nil || current.onBattery != nil { sawBatteryFlag = true }
            if previous.onBattery == true, current.onBattery == true { batterySeconds += dt }
        }
    }

    /// 0/1 条样本不能产生能量、均值或峰值；返回值不结束累加，可继续 append。
    public func finish() -> EnergyEstimates {
        guard sampleCount >= 2 else { return EnergyEstimates.insufficientData() }
        let duration = max(0, endEpoch - startEpoch)
        let expected = duration / TimeInterval(intervalSeconds)
        return EnergyEstimates(
            energyInWh: energyIn,
            energyOutWh: energyOut,
            netWh: energyIn - energyOut,
            meanChargeW: EnergyEstimates.meanPower(energyWh: energyIn, seconds: chargeSeconds, fallbackSum: chargeSum, count: chargeCount),
            meanDischargeW: EnergyEstimates.meanPower(energyWh: energyOut, seconds: dischargeSeconds, fallbackSum: dischargeSum, count: dischargeCount),
            peakInW: peakIn,
            peakOutW: peakOut,
            durationUsingAdapter: sawAdapterFlag ? adapterSeconds : nil,
            durationOnBattery: sawBatteryFlag ? batterySeconds : nil,
            completeness: expected <= 0 ? 1 : min(1, Double(sampleCount) / expected)
        )
    }
}

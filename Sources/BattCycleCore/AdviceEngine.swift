import Foundation

/// 本地只读建议引擎。不调用 BattService、不下发适配器命令、不启动压力负载。
/// `current` 每次都是 `f(context)`：只包含此刻条件为真的规则，不做粘滞展示。
public struct AdviceEngine: Sendable {
    /// 同一 ruleId 的默认冷却时间（秒）。
    public static let defaultCooldown: TimeInterval = 15 * 60
    /// 功率类规则所需的最少有效瓦数样本。
    public static let minValidWattsSamples = 5
    /// 持续高放电：放电功率均值低于该阈值（瓦，负值）。
    public static let highDischargeMeanWatts = -20.0
    /// 持续高放电所需的最短窗口（秒）。
    public static let highDischargeMinSeconds: TimeInterval = 10 * 60
    /// 「接入适配器仍在放电」所需的最短持续窗口（秒）。
    public static let adapterDischargeMinSeconds: TimeInterval = 2 * 60
    /// 充电功率视为明显低于额定的比例上限（不含等于）。
    public static let chargeBelowRatedRatio = 0.4
    /// 充电功率偏低所需的最短窗口（秒）。
    public static let chargeBelowRatedMinSeconds: TimeInterval = 10 * 60
    /// 方向抖动的观察窗口（秒）。
    public static let chatterWindowSeconds: TimeInterval = 5 * 60
    /// 短窗口内方向翻转次数下限。
    public static let chatterMinFlips = 6
    /// 数据过期的最短阈值（秒），与 3 倍采样间隔取较大值。
    public static let staleFloorSeconds: TimeInterval = 60
    /// 短间隔告警：采样间隔小于等于该值（秒）。
    public static let shortIntervalSeconds: TimeInterval = 2
    /// 长保留告警：保留天数大于等于该值。
    public static let longRetentionDays = 90
    /// 适配器状态冲突所需的最少冲突样本。
    public static let adapterConflictMinSamples = 3
    /// 数据不足建议的占位置信度；UI 应通过 `displayedConfidence` 隐藏，而不是显示 1.0。
    public static let insufficientDataConfidence: Double = 0.2
    /// 连续片段的 dt 倍数，与历史查询间隙口径一致。
    public static let gapIntervalMultiplier: TimeInterval = 2.5

    public var cooldown: TimeInterval

    public init(cooldown: TimeInterval = AdviceEngine.defaultCooldown) {
        self.cooldown = cooldown
    }

    /// 超过该阈值的 dt 视为间隙，打断「持续」片段。
    public static func gapThreshold(historyIntervalSeconds: TimeInterval) -> TimeInterval {
        Self.gapIntervalMultiplier * max(historyIntervalSeconds, 1)
    }

    /// 使用上次发出的建议做冷却记账。返回此刻条件为真的建议（UI 只应展示这一组）。
    public func evaluate(
        context: AdviceContext,
        previous: [Advice] = [],
        now: Date = Date()
    ) -> [Advice] {
        evaluateAll(context: context, previous: previous, now: now).current
    }

    /// 同时给出当前建议与冷却抑制列表。冷却不从 `current` 中隐藏仍为真的规则。
    public func evaluateAll(
        context: AdviceContext,
        previous: [Advice] = [],
        now: Date = Date()
    ) -> AdviceEvaluation {
        var deduper = AdviceDeduper(previous: previous)
        return evaluateAll(context: context, deduper: &deduper, now: now)
    }

    /// 使用内存去重器。成功新发出的 ruleId 写入 `deduper`；冷却中的仍为真规则只进入 `suppressedByCooldown`。
    public func evaluate(
        context: AdviceContext,
        deduper: inout AdviceDeduper,
        now: Date = Date()
    ) -> [Advice] {
        evaluateAll(context: context, deduper: &deduper, now: now).current
    }

    /// 使用内存去重器，返回完整评估（当前建议 + 冷却抑制）。
    public func evaluateAll(
        context: AdviceContext,
        deduper: inout AdviceDeduper,
        now: Date = Date()
    ) -> AdviceEvaluation {
        // current 只来自本次 collect，不把 previous 并进去，因此条件结束即空。
        let prepared = PreparedContext(context: context, now: now)
        let candidates = collect(prepared)
        var current: [Advice] = []
        var suppressed: [String] = []
        current.reserveCapacity(candidates.count)
        for item in candidates {
            current.append(item)
            if deduper.isCoolingDown(ruleId: item.ruleId, now: now, cooldown: cooldown) {
                suppressed.append(item.ruleId)
            } else {
                deduper.record(item)
            }
        }
        return AdviceEvaluation(current: current, suppressedByCooldown: suppressed)
    }

    // MARK: - 规则调度

    private func collect(_ ctx: PreparedContext) -> [Advice] {
        var items: [Advice] = []
        let wattsReady = ctx.validWatts.count >= Self.minValidWattsSamples

        if !wattsReady {
            items.append(insufficientWatts(ctx))
        }
        if wattsReady, let item = sustainedHighDischarge(ctx) {
            items.append(item)
        }
        // 循环放电且 useAdapter == false 的样本在规则内剔除，避免「适配器关闭仍放电」误报。
        if let item = dischargingWhileAdapterConnected(ctx) {
            items.append(item)
        }
        if wattsReady, let item = chargePowerWellBelowAdapterCapability(ctx) {
            items.append(item)
        }
        if let item = rapidDirectionChatter(ctx) {
            items.append(item)
        }
        if let item = thermalTooHigh(ctx) {
            items.append(item)
        }
        if let item = staleData(ctx) {
            items.append(item)
        }
        if let item = shortIntervalLongRetention(ctx) {
            items.append(item)
        }
        if let item = cycleLoadPlusHeat(ctx) {
            items.append(item)
        }
        if let item = adapterStateConflictsBatteryDirection(ctx) {
            items.append(item)
        }
        return items
    }

    // MARK: - 规则 1

    /// 连续片段内放电功率均值持续偏高。跨睡眠 / 大 dt / 未知方向的散点不算持续。
    private func sustainedHighDischarge(_ ctx: PreparedContext) -> Advice? {
        var best: (mean: Double, count: Int, span: TimeInterval)?
        for segment in ctx.segments {
            let discharge = validWatts(in: segment).filter { $0.watts < 0 }
            guard discharge.count >= Self.minValidWattsSamples else { continue }
            let mean = average(discharge.map(\.watts))
            guard mean < Self.highDischargeMeanWatts else { continue }
            let span = spanSeconds(discharge.map(\.sample.epoch))
            guard span >= Self.highDischargeMinSeconds else { continue }
            if best == nil || span > best!.span || (span == best!.span && mean < best!.mean) {
                best = (mean, discharge.count, span)
            }
        }
        guard let best else { return nil }

        let magnitude = abs(best.mean)
        let severity: AdviceSeverity = magnitude >= 40 ? .high : .warning
        let durationFactor = min(1, best.span / (30 * 60))
        let magnitudeFactor = min(1, magnitude / 40)
        let confidence = 0.5 + 0.25 * durationFactor + 0.25 * magnitudeFactor

        return makeAdvice(
            rule: .sustainedHighDischarge,
            severity: severity,
            facts: ctx.commonFacts() + [
                String(format: "放电功率均值 %.1f W（阈值 %.1f W）", best.mean, Self.highDischargeMeanWatts),
                "有效放电样本 \(best.count) 条，覆盖 \(describeSpan(best.span))"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "仅在连续片段内统计：有效放电功率均值低于 -20 W，且该片段至少覆盖 10 分钟时发出。睡眠间隙、过大 dt、未知方向会打断片段。",
            confidence: confidence,
            action: "请考虑检查当前是否存在持续高负载，并核对放电功率读数是否与使用情况相符。",
            now: ctx.now
        )
    }

    // MARK: - 规则 2

    /// 方向为放电，同时适配器接入（useAdapter 或 pluggedIn）并在连续片段内持续一段时间。
    /// 引擎放电阶段且未使用适配器的样本视为循环预期，不计入「适配器关闭仍放电」。
    private func dischargingWhileAdapterConnected(_ ctx: PreparedContext) -> Advice? {
        var best: (count: Int, span: TimeInterval)?
        for segment in ctx.segments {
            let matching = segment.filter { sample in
                guard !isExpectedCycleDischargeSample(sample) else { return false }
                return Direction.parse(sample.direction) == .discharging
                    && (sample.useAdapter == true || sample.pluggedIn == true)
            }
            guard matching.count >= Self.minValidWattsSamples else { continue }
            let span = spanSeconds(matching.map(\.epoch))
            guard span >= Self.adapterDischargeMinSeconds else { continue }
            if best == nil || matching.count > best!.count {
                best = (matching.count, span)
            }
        }
        guard let best else { return nil }

        let confidence = min(1, 0.4 + 0.6 * Double(best.count) / 20)
        return makeAdvice(
            rule: .dischargingWhileAdapterConnected,
            severity: .warning,
            facts: ctx.commonFacts() + [
                "放电且适配器相关标志为真的样本 \(best.count) 条",
                "上述样本覆盖 \(describeSpan(best.span))"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "当充放电方向为 discharging，且 useAdapter 为 true，或 pluggedIn 为 true 的放电状态在连续片段内持续至少 2 分钟时发出。引擎处于放电阶段且未使用适配器时跳过（循环预期行为）。",
            confidence: confidence,
            action: "请考虑检查适配器是否实际供电、负载是否大于输入，以及系统报告的充电方向是否与指示灯一致。",
            now: ctx.now
        )
    }

    // MARK: - 规则 3

    /// 仅在提供额定功率时比较。充电功率均值在连续片段内长期明显低于额定值。
    private func chargePowerWellBelowAdapterCapability(_ ctx: PreparedContext) -> Advice? {
        guard let rated = ctx.adapterRatedMaxWatts, rated.isFinite, rated > 0 else {
            return nil
        }
        var best: (mean: Double, count: Int, span: TimeInterval)?
        for segment in ctx.segments {
            let charge = validWatts(in: segment).filter { $0.watts > 0 }
            guard charge.count >= Self.minValidWattsSamples else { continue }
            let mean = average(charge.map(\.watts))
            let limit = rated * Self.chargeBelowRatedRatio
            guard mean < limit else { continue }
            let span = spanSeconds(charge.map(\.sample.epoch))
            guard span >= Self.chargeBelowRatedMinSeconds else { continue }
            if best == nil || span > best!.span {
                best = (mean, charge.count, span)
            }
        }
        guard let best else { return nil }

        let ratio = best.mean / rated
        let confidence = min(1, 0.45 + 0.55 * (1 - min(1, ratio / Self.chargeBelowRatedRatio)))
        return makeAdvice(
            rule: .chargePowerWellBelowAdapterCapability,
            severity: .warning,
            facts: ctx.commonFacts() + [
                String(format: "适配器额定最大功率 %.1f W（由调用方提供，非引擎估计）", rated),
                String(format: "充电功率均值 %.1f W，约为额定值的 %.0f%%（对照阈值 %.0f%%）", best.mean, ratio * 100, Self.chargeBelowRatedRatio * 100),
                "有效充电样本 \(best.count) 条，覆盖 \(describeSpan(best.span))"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "仅在上下文提供 adapterRatedMaxWatts 时生效。连续片段内充电功率均值低于额定值的 40%，且充电样本至少覆盖 10 分钟时发出。额定值缺失则跳过，不编造。",
            confidence: confidence,
            action: "请考虑检查线材、接口接触与系统是否在限流，核对充电功率是否明显低于该适配器的额定输出。",
            now: ctx.now
        )
    }

    // MARK: - 规则 4

    /// 短窗口内方向频繁翻转。未知方向在计数前剔除，不参与翻转。
    private func rapidDirectionChatter(_ ctx: PreparedContext) -> Advice? {
        let known = ctx.samples.compactMap { sample -> (epoch: TimeInterval, direction: Direction)? in
            let direction = Direction.parse(sample.direction)
            guard direction != .unknown else { return nil }
            return (sample.epoch, direction)
        }
        guard known.count >= Self.chatterMinFlips + 1 else { return nil }

        var bestFlips = 0
        var bestSpan: TimeInterval = 0
        for startIndex in known.indices {
            let windowStart = known[startIndex].epoch
            let windowEnd = windowStart + Self.chatterWindowSeconds
            var flips = 0
            var previous: Direction?
            var lastEpoch = windowStart
            for index in startIndex..<known.count {
                let point = known[index]
                if point.epoch > windowEnd { break }
                if let previous, point.direction != previous {
                    flips += 1
                }
                previous = point.direction
                lastEpoch = point.epoch
            }
            if flips > bestFlips {
                bestFlips = flips
                bestSpan = max(0, lastEpoch - windowStart)
            }
        }

        guard bestFlips >= Self.chatterMinFlips else { return nil }
        let confidence = min(1, Double(bestFlips) / 12)
        return makeAdvice(
            rule: .rapidDirectionChatter,
            severity: .warning,
            facts: ctx.commonFacts() + [
                "\(Int(Self.chatterWindowSeconds / 60)) 分钟窗口内最多观测到 \(bestFlips) 次方向翻转",
                "对应子窗口约 \(describeSpan(bestSpan))"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "先过滤未知方向，再在任意 5 分钟窗口内统计规范化后的充放电方向翻转；达到 6 次及以上时发出。",
            confidence: confidence,
            action: "请考虑检查充电接触是否不稳，或电源状态是否在短时间内反复变化。",
            now: ctx.now
        )
    }

    // MARK: - 规则 5

    /// 热状态为 serious 或 critical。
    private func thermalTooHigh(_ ctx: PreparedContext) -> Advice? {
        let hot = ctx.samples.filter { sample in
            let band = ThermalBand.parse(sample.thermal)
            return band == .serious || band == .critical
        }
        guard !hot.isEmpty else { return nil }

        let latest = ctx.samples.last { $0.thermal != nil }
        let latestBand = ThermalBand.parse(latest?.thermal)
        let latestIsHot = latestBand == .serious || latestBand == .critical
        let hasCritical = hot.contains { ThermalBand.parse($0.thermal) == .critical }
        let severity: AdviceSeverity = hasCritical ? .high : .warning
        let confidence = latestIsHot ? 0.9 : 0.65

        return makeAdvice(
            rule: .thermalTooHigh,
            severity: severity,
            facts: ctx.commonFacts() + [
                "热状态为 serious/critical 的样本 \(hot.count) 条",
                "最近一条带热状态的样本：\(latest?.thermal ?? "无")"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "窗口中出现 thermal 为 serious 或 critical 的样本时发出。只报告热状态读数。",
            confidence: confidence,
            action: "请考虑降低负载、改善通风，并等待热状态回落后再继续观察。",
            now: ctx.now
        )
    }

    // MARK: - 规则 6

    /// 没有新于 max(3×间隔, 60秒) 的样本。
    private func staleData(_ ctx: PreparedContext) -> Advice? {
        let interval = max(0, ctx.historyIntervalSeconds)
        let threshold = max(3 * interval, Self.staleFloorSeconds)
        let newestEpoch = ctx.samples.last?.epoch
        let age: TimeInterval
        if let newestEpoch {
            age = ctx.nowEpoch - newestEpoch
        } else {
            age = .infinity
        }
        guard age > threshold else { return nil }

        var facts = ctx.commonFacts()
        if ctx.samples.isEmpty {
            facts.append("窗口内没有任何样本")
        } else {
            facts.append(String(format: "最新样本距评估时刻 %.0f 秒", age))
        }
        facts.append(String(format: "过期阈值 %.0f 秒（max(3×间隔, 60)）", threshold))

        let confidence: Double = ctx.samples.isEmpty ? 0.95 : min(1, 0.7 + min(age, 600) / 2000)
        return makeAdvice(
            rule: .staleData,
            severity: .warning,
            facts: facts,
            timeRange: ctx.timeRangeDescriptionZH,
            description: "若没有比 max(3×historyIntervalSeconds, 60秒) 更新的样本，则判定数据过期。",
            confidence: confidence,
            action: "请考虑确认历史记录是否仍在采集，或检查采样是否已暂停。",
            now: ctx.now
        )
    }

    // MARK: - 规则 7

    /// 采样过密且保留过长，提示本地存储压力。不涉及电池健康。
    private func shortIntervalLongRetention(_ ctx: PreparedContext) -> Advice? {
        guard ctx.historyIntervalSeconds <= Self.shortIntervalSeconds,
              ctx.retentionDays >= Self.longRetentionDays else {
            return nil
        }
        return makeAdvice(
            rule: .shortIntervalLongRetention,
            severity: .info,
            facts: ctx.commonFacts() + [
                String(format: "采样间隔 %.1f 秒（≤ %.0f 秒）", ctx.historyIntervalSeconds, Self.shortIntervalSeconds),
                "保留 \(ctx.retentionDays) 天（≥ \(Self.longRetentionDays) 天）"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "当采样间隔小于等于 2 秒且保留天数大于等于 90 时发出存储占用提醒。",
            confidence: 0.85,
            action: "请考虑增大采样间隔或缩短保留天数，以降低本地历史存储占用。",
            now: ctx.now
        )
    }

    // MARK: - 规则 8

    /// 同一条样本上：引擎处于放电阶段且热状态为 fair/serious。
    private func cycleLoadPlusHeat(_ ctx: PreparedContext) -> Advice? {
        let matching = ctx.samples.filter { sample in
            guard isDischargingPhase(sample.enginePhase) else { return false }
            let band = ThermalBand.parse(sample.thermal)
            return band == .fair || band == .serious
        }
        guard !matching.isEmpty else { return nil }

        let hasSerious = matching.contains { ThermalBand.parse($0.thermal) == .serious }
        let severity: AdviceSeverity = hasSerious ? .warning : .info
        let confidence = min(1, 0.4 + 0.1 * Double(matching.count))
        return makeAdvice(
            rule: .cycleLoadPlusHeat,
            severity: severity,
            facts: ctx.commonFacts() + [
                "enginePhase 为放电且热状态为 fair/serious 的样本 \(matching.count) 条",
                "其中热状态示例：\(matching.last?.thermal ?? "无")"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "同一条样本同时满足 enginePhase 为 discharging、thermal 为 fair 或 serious 时发出。不把热量解释为健康损伤。",
            confidence: confidence,
            action: "请考虑在放电负载期间关注温度，必要时降低负载并改善通风。",
            now: ctx.now
        )
    }

    // MARK: - 规则 9

    /// 适配器标志与电池方向不一致。置信度随冲突样本数上升。
    /// 引擎放电阶段且未使用适配器的样本不计入冲突（循环预期行为）。
    private func adapterStateConflictsBatteryDirection(_ ctx: PreparedContext) -> Advice? {
        var adapterOnButDischarging = 0
        var adapterOffButCharging = 0
        for sample in ctx.samples {
            if isExpectedCycleDischargeSample(sample) { continue }
            let direction = Direction.parse(sample.direction)
            if sample.useAdapter == true, direction == .discharging {
                adapterOnButDischarging += 1
            } else if sample.useAdapter == false,
                      direction == .charging,
                      sample.pluggedIn == true {
                adapterOffButCharging += 1
            }
        }
        let conflicts = adapterOnButDischarging + adapterOffButCharging
        guard conflicts >= Self.adapterConflictMinSamples else { return nil }

        let confidence = min(1, Double(conflicts) / 10)
        var facts = ctx.commonFacts()
        if adapterOnButDischarging > 0 {
            facts.append("useAdapter 为 true 但方向为放电：\(adapterOnButDischarging) 条")
        }
        if adapterOffButCharging > 0 {
            facts.append("useAdapter 为 false 但已插入且方向为充电：\(adapterOffButCharging) 条")
        }
        facts.append("冲突样本合计 \(conflicts) 条（置信度随样本数上升）")

        return makeAdvice(
            rule: .adapterStateConflictsBatteryDirection,
            severity: .warning,
            facts: facts,
            timeRange: ctx.timeRangeDescriptionZH,
            description: "当 useAdapter 为 true 却在放电，或 useAdapter 为 false 却出现已插入适配器的充电标签时发出。引擎放电且未用适配器时跳过。置信度依据冲突样本数量。",
            confidence: confidence,
            action: "请考虑核对适配器状态与电池充放电方向是否一致。本建议只读，不会改动适配器。",
            now: ctx.now
        )
    }

    // MARK: - 数据不足

    private func insufficientWatts(_ ctx: PreparedContext) -> Advice {
        makeAdvice(
            rule: .insufficientWattsSamples,
            severity: .info,
            facts: ctx.commonFacts() + [
                "有效功率样本 \(ctx.validWatts.count) 条，少于 \(Self.minValidWattsSamples) 条",
                "数据不足，跳过依赖瓦数的功率规则，不编造放电或充电结论"
            ],
            timeRange: ctx.timeRangeDescriptionZH,
            description: "有效瓦数样本少于 5 条时，功率类规则不予计算，改为明确提示数据不足。",
            confidence: Self.insufficientDataConfidence,
            action: "当前有效功率样本不足，无法给出功率相关建议。请积累更多采样后再查看。",
            now: ctx.now,
            dataInsufficient: true
        )
    }

    // MARK: - 装配

    private func makeAdvice(
        rule: AdviceRuleID,
        severity: AdviceSeverity,
        facts: [String],
        timeRange: String,
        description: String,
        confidence: Double,
        action: String,
        now: Date,
        dataInsufficient: Bool = false
    ) -> Advice {
        Advice(
            id: rule.rawValue,
            severity: severity,
            observedFactsZH: facts,
            timeRangeDescriptionZH: timeRange,
            ruleId: rule.rawValue,
            ruleDescriptionZH: description,
            confidence: confidence,
            suggestedActionZH: action,
            generatedAt: now,
            dataInsufficient: dataInsufficient,
            displayNameZH: rule.displayNameZH
        )
    }
}

// MARK: - 窗口预处理

private struct PreparedContext {
    let samples: [AdviceSample]
    let segments: [[AdviceSample]]
    let historyIntervalSeconds: TimeInterval
    let recordingPaused: Bool
    let sampleCount: Int
    let retentionDays: Int
    let adapterRatedMaxWatts: Double?
    let now: Date
    let nowEpoch: TimeInterval
    let validWatts: [(sample: AdviceSample, watts: Double)]

    init(context: AdviceContext, now: Date) {
        let sorted = context.samples.sorted { $0.epoch < $1.epoch }
        self.samples = sorted
        self.historyIntervalSeconds = context.historyIntervalSeconds
        self.segments = splitContiguousSegments(
            sorted,
            intervalSeconds: context.historyIntervalSeconds
        )
        self.recordingPaused = context.recordingPaused
        self.sampleCount = context.sampleCount
        self.retentionDays = context.retentionDays
        self.adapterRatedMaxWatts = context.adapterRatedMaxWatts
        self.now = now
        self.nowEpoch = now.timeIntervalSince1970
        self.validWatts = sorted.compactMap { sample in
            guard let watts = sample.watts, watts.isFinite else { return nil }
            return (sample, watts)
        }
    }

    var timeRangeDescriptionZH: String {
        guard let first = samples.first, let last = samples.last else {
            return "无可用样本窗口"
        }
        let span = max(0, last.epoch - first.epoch)
        return "\(describeSpan(span))，窗口 \(samples.count) 条样本"
    }

    func commonFacts() -> [String] {
        var facts = [
            "窗口样本 \(samples.count) 条，声明总量 \(sampleCount) 条",
            String(format: "采样间隔 %.1f 秒，保留 %d 天", historyIntervalSeconds, retentionDays)
        ]
        if recordingPaused {
            facts.append("记录已暂停")
        }
        if let percent = samples.last?.percent {
            facts.append(String(format: "窗口末电量读数 %.0f%%", percent))
        }
        return facts
    }
}

private enum Direction: Equatable {
    case charging
    case discharging
    case idle
    case unknown

    static func parse(_ raw: String) -> Direction {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return .unknown }
        if text.contains("discharg") || text.contains("放电") { return .discharging }
        if text.contains("charg") || text.contains("充电") { return .charging }
        if text == "idle" || text.contains("待机") || text.contains("空闲") { return .idle }
        if text == "unknown" || text.contains("未知") { return .unknown }
        return .unknown
    }
}

private enum ThermalBand: Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    static func parse(_ raw: String?) -> ThermalBand {
        guard let raw else { return .unknown }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.isEmpty { return .unknown }
        if text.contains("critical") || text.contains("危急") || text.contains("危险") {
            return .critical
        }
        if text.contains("serious") || text.contains("严重") {
            return .serious
        }
        if text.contains("fair") || text.contains("微热") {
            return .fair
        }
        if text.contains("nominal") || text.contains("normal") || text.contains("正常") {
            return .nominal
        }
        return .unknown
    }
}

private func isDischargingPhase(_ raw: String?) -> Bool {
    guard let raw else { return false }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return text == "discharging" || text.contains("放电")
}

private func isExpectedCycleDischargeSample(_ sample: AdviceSample) -> Bool {
    isDischargingPhase(sample.enginePhase) && sample.useAdapter == false
}

private func validWatts(in samples: [AdviceSample]) -> [(sample: AdviceSample, watts: Double)] {
    samples.compactMap { sample in
        guard let watts = sample.watts, watts.isFinite else { return nil }
        return (sample, watts)
    }
}

/// 按睡眠间隙、过大 dt、未知方向切成连续片段。未知点本身不进入任何片段。
private func splitContiguousSegments(
    _ samples: [AdviceSample],
    intervalSeconds: TimeInterval
) -> [[AdviceSample]] {
    let threshold = AdviceEngine.gapThreshold(historyIntervalSeconds: intervalSeconds)
    var segments: [[AdviceSample]] = []
    var current: [AdviceSample] = []

    for sample in samples {
        if Direction.parse(sample.direction) == .unknown {
            if !current.isEmpty {
                segments.append(current)
                current = []
            }
            continue
        }

        let shouldBreak: Bool
        if let last = current.last {
            let dt = sample.epoch - last.epoch
            shouldBreak = sample.sleepGap == true || dt > threshold
        } else {
            shouldBreak = false
        }

        if shouldBreak {
            segments.append(current)
            current = [sample]
        } else {
            current.append(sample)
        }
    }
    if !current.isEmpty {
        segments.append(current)
    }
    return segments
}

private func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

private func spanSeconds(_ epochs: [TimeInterval]) -> TimeInterval {
    guard let first = epochs.first, let last = epochs.last else { return 0 }
    return max(0, last - first)
}

private func describeSpan(_ seconds: TimeInterval) -> String {
    let rounded = Int(seconds.rounded())
    if seconds >= 60 {
        return "约 \(rounded / 60) 分钟（\(rounded) 秒）"
    }
    return "\(rounded) 秒"
}

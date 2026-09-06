import AppKit
import BattCycleCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// 曲线页预设。自定义项对应 `HistoryRange.custom`，避免带关联值的枚举无法作为 Picker 标签。
private enum HistoryRangeChoice: String, CaseIterable, Identifiable, Hashable {
    case minutes15
    case hours1
    case hours6
    case hours24
    case days7
    case days30
    case custom

    var id: String { rawValue }

    var titleZH: String {
        switch self {
        case .minutes15: return "15 分钟"
        case .hours1: return "1 小时"
        case .hours6: return "6 小时"
        case .hours24: return "24 小时"
        case .days7: return "7 天"
        case .days30: return "30 天"
        case .custom: return "自定义"
        }
    }

    init(_ range: HistoryRange) {
        switch range {
        case .minutes15: self = .minutes15
        case .hours1: self = .hours1
        case .hours6: self = .hours6
        case .hours24: self = .hours24
        case .days7: self = .days7
        case .days30: self = .days30
        case .custom: self = .custom
        }
    }

    var namedRange: HistoryRange? {
        switch self {
        case .minutes15: return .minutes15
        case .hours1: return .hours1
        case .hours6: return .hours6
        case .hours24: return .hours24
        case .days7: return .days7
        case .days30: return .days30
        case .custom: return nil
        }
    }
}

/// 适配器开关或循环阶段跃迁。从查询结果样本提取（已下采样），再限制标记数量。
private struct OverlayEvent: Identifiable {
    enum Kind: String {
        case adapterOn
        case adapterOff
        case phaseChange
    }

    var id: String { "\(kind.rawValue)-\(epoch)-\(caption)" }
    var epoch: TimeInterval
    var kind: Kind
    var caption: String
    var percent: Int?

    var date: Date { Date(timeIntervalSince1970: epoch) }

    var color: Color {
        switch kind {
        case .adapterOn: return .teal
        case .adapterOff: return .red
        case .phaseChange: return .purple
        }
    }

    var symbol: BasicChartSymbolShape {
        switch kind {
        case .adapterOn: return .circle
        case .adapterOff: return .triangle
        case .phaseChange: return .diamond
        }
    }
}

/// 睡眠或采样间隙的横向色带。
private struct GapRegion: Identifiable {
    var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    var start: Date
    var end: Date
}

struct HistoryView: View {
    @EnvironmentObject private var engine: EngineController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverDate: Date?
    /// 事件标记缓存：只在样本集变化时扫描，避免悬停每帧扫全量。
    @State private var overlayEvents: [OverlayEvent] = []
    @State private var sampleGapRegions: [GapRegion] = []

    var body: some View {
        DashboardForm {
            DashboardSection("范围") {
                Picker("时间范围", selection: rangeChoiceBinding) {
                    ForEach(HistoryRangeChoice.allCases) { choice in
                        Text(choice.titleZH).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("时间范围")

                if isCustomRange {
                    DatePicker(
                        "开始",
                        selection: customStartBinding,
                        in: safeDateRange(from: Date.distantPast, to: customEndDate),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    DatePicker(
                        "结束",
                        selection: customEndBinding,
                        in: safeDateRange(from: customStartDate, to: customEndLimit),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Text("自定义范围按所选起止时刻查询，不再随当前时间滑动。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let failure = historyFailureText {
                DashboardSection("曲线") {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Text("历史文件可能损坏或读取失败。可在「设置与诊断」清除全部历史后重新记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if seriesIsEmpty {
                DashboardSection("曲线") {
                    Text(emptyTitle)
                        .foregroundStyle(.secondary)
                    Text(emptyCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                DashboardSection("电量") {
                    percentChart
                        .frame(minHeight: 180)
                        .accessibilityLabel("电量随时间变化，灰色带为睡眠或采样间隙")
                        .transaction { transaction in
                            if reduceMotion {
                                transaction.animation = nil
                            }
                        }
                }

                DashboardSection("电池净功率") {
                    wattsChart
                        .frame(minHeight: 180)
                        .accessibilityLabel("电池净功率随时间变化，正值充电，负值放电，灰色带为间隙，零线为参考")
                        .transaction { transaction in
                            if reduceMotion {
                                transaction.animation = nil
                            }
                        }
                }

                DashboardSection("图例") {
                    chartLegend
                }

                if let hoverSummary {
                    DashboardSection("指针处") {
                        Text(hoverSummary)
                            .font(.body.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
            }

            DashboardSection(EnergyEstimates.estimateLabel) {
                Text("以下数值为\(EnergyEstimates.estimateLabel)，缺失功率不按 0 积分，睡眠间隙不计入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                estimateRow("充入能量", value: energyText(engine.energyEstimates?.energyInWh), unit: "Wh")
                estimateRow("放出能量", value: energyText(engine.energyEstimates?.energyOutWh), unit: "Wh")
                estimateRow("净能量", value: energyText(engine.energyEstimates?.netWh), unit: "Wh")
                estimateRow("平均充电功率", value: optionalWatts(engine.energyEstimates?.meanChargeW), unit: "W")
                estimateRow("平均放电功率", value: optionalWatts(engine.energyEstimates?.meanDischargeW), unit: "W")
                estimateRow("峰值充入", value: optionalWatts(engine.energyEstimates?.peakInW), unit: "W")
                estimateRow("峰值放出", value: optionalWatts(engine.energyEstimates?.peakOutW), unit: "W")
                estimateRow(
                    "使用适配器时长",
                    value: engine.energyEstimates?.durationUsingAdapter.map(MetricDisplay.durationZH),
                    unit: ""
                )
                estimateRow(
                    "电池供电时长",
                    value: engine.energyEstimates?.durationOnBattery.map(MetricDisplay.durationZH),
                    unit: ""
                )
                estimateRow(
                    "完整度",
                    value: engine.energyEstimates.map { String(format: "%.0f", $0.completeness * 100) },
                    unit: "%"
                )
            }

            DashboardSection("控制") {
                HStack {
                    if engine.monitorSettings.recordingPaused {
                        Button("继续记录") { engine.resumeRecording() }
                    } else {
                        Button("暂停记录") { engine.pauseRecording() }
                    }
                    Button("导出 CSV") { exportCSV() }
                    Spacer()
                    Text(engine.monitorSettings.recordingPaused ? "仅暂停历史落盘，不影响循环与适配器" : "正在按间隔写入历史")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("CSV 按当前时间范围流式写出全部样本，不经过曲线下采样。能量行为\(EnergyEstimates.estimateLabel)。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshOverlays)
        .onChange(of: overlayRefreshKey) { _, _ in
            refreshOverlays()
        }
    }

    private var rangeChoiceBinding: Binding<HistoryRangeChoice> {
        Binding(
            get: { HistoryRangeChoice(engine.historyRange) },
            set: { choice in
                if let named = choice.namedRange {
                    engine.setHistoryRange(named)
                    return
                }
                if case .custom = engine.historyRange {
                    return
                }
                let window = engine.historyRange.window()
                applyCustomRange(from: window.start, to: window.end)
            }
        )
    }

    private var isCustomRange: Bool {
        if case .custom = engine.historyRange { return true }
        return false
    }

    private var customStartDate: Date {
        engine.historyRange.window().start
    }

    private var customEndDate: Date {
        engine.historyRange.window().end
    }

    private var customEndLimit: Date {
        max(Date().addingTimeInterval(60), customEndDate)
    }

    private var customStartBinding: Binding<Date> {
        Binding(
            get: { customStartDate },
            set: { applyCustomRange(from: $0, to: customEndDate) }
        )
    }

    private var customEndBinding: Binding<Date> {
        Binding(
            get: { customEndDate },
            set: { applyCustomRange(from: customStartDate, to: $0) }
        )
    }

    private var percentChart: some View {
        Chart {
            sharedOverlays
            ForEach(Array(percentSegments.enumerated()), id: \.offset) { segmentIndex, segment in
                ForEach(segment, id: \.epoch) { point in
                    if let percent = point.percent {
                        LineMark(
                            x: .value("时间", Date(timeIntervalSince1970: point.epoch)),
                            y: .value("电量", percent),
                            series: .value("连续段", segmentIndex)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.linear)
                    }
                }
            }
            ForEach(overlayEvents) { event in
                PointMark(
                    x: .value("事件", event.date),
                    y: .value("电量", event.percent ?? 50)
                )
                .foregroundStyle(event.color)
                .symbol(event.symbol)
                .symbolSize(48)
            }
            hoverPointMark(percent: true)
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartYAxis { AxisMarks(values: [0, 50, 100]) }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            hoverOverlay(proxy: proxy)
        }
    }

    private var wattsChart: some View {
        Chart {
            sharedOverlays
            RuleMark(y: .value("零", 0))
                .foregroundStyle(Color.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(Array(wattsSegments.enumerated()), id: \.offset) { segmentIndex, segment in
                ForEach(segment.points, id: \.epoch) { point in
                    if let watts = point.watts {
                        LineMark(
                            x: .value("时间", Date(timeIntervalSince1970: point.epoch)),
                            y: .value("功率", watts),
                            series: .value("连续段", segmentIndex)
                        )
                        .foregroundStyle(segment.charging ? Color.green : Color.orange)
                        .interpolationMethod(.linear)
                    }
                }
            }
            hoverPointMark(percent: false)
        }
        .chartXScale(domain: xDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            hoverOverlay(proxy: proxy)
        }
    }

    @ChartContentBuilder
    private var sharedOverlays: some ChartContent {
        ForEach(gapRegions) { region in
            RectangleMark(
                xStart: .value("间隙起", region.start),
                xEnd: .value("间隙止", region.end)
            )
            .foregroundStyle(Color.secondary.opacity(0.16))
        }
        ForEach(overlayEvents) { event in
            RuleMark(x: .value("事件", event.date))
                .foregroundStyle(event.color.opacity(0.55))
                .lineStyle(
                    StrokeStyle(
                        lineWidth: 1,
                        dash: event.kind == .phaseChange ? [3, 3] : []
                    )
                )
        }
        if let hoverDate {
            RuleMark(x: .value("指针", hoverDate))
                .foregroundStyle(Color.primary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }

    @ChartContentBuilder
    private func hoverPointMark(percent: Bool) -> some ChartContent {
        if let hoverDate, let point = nearestHoverPoint(to: hoverDate), !point.isGap {
            if percent, let value = point.percent {
                PointMark(
                    x: .value("时间", Date(timeIntervalSince1970: point.epoch)),
                    y: .value("电量", value)
                )
                .foregroundStyle(Color.accentColor)
                .symbolSize(36)
            } else if !percent, let watts = point.watts {
                PointMark(
                    x: .value("时间", Date(timeIntervalSince1970: point.epoch)),
                    y: .value("功率", watts)
                )
                .foregroundStyle(watts >= 0 ? Color.green : Color.orange)
                .symbolSize(36)
            }
        }
    }

    private func hoverOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let x: CGFloat
                        if let plotFrame = proxy.plotFrame {
                            x = location.x - geo[plotFrame].origin.x
                        } else {
                            x = location.x
                        }
                        if let date: Date = proxy.value(atX: x) {
                            hoverDate = date
                        }
                    case .ended:
                        hoverDate = nil
                    }
                }
        }
    }

    private var chartLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                legendSwatch(Color.accentColor, title: "电量")
                legendSwatch(Color.green, title: "充电功率")
                legendSwatch(Color.orange, title: "放电功率")
                legendSwatch(Color.secondary.opacity(0.45), title: "零线", dashed: true)
            }
            HStack(spacing: 14) {
                legendSwatch(Color.secondary.opacity(0.35), title: "睡眠/间隙", filled: true)
                legendSwatch(Color.teal, title: "适配器开启")
                legendSwatch(Color.red, title: "适配器关闭")
                legendSwatch(Color.purple, title: "循环阶段变化", dashed: true)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("图例：电量、充电功率、放电功率、零线、睡眠或间隙、适配器开启、适配器关闭、循环阶段变化")
    }

    private func legendSwatch(
        _ color: Color,
        title: String,
        dashed: Bool = false,
        filled: Bool = false
    ) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(filled ? color : Color.clear)
                .overlay {
                    Capsule()
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : [])
                        )
                }
                .frame(width: 16, height: 8)
            Text(title)
        }
    }

    /// 空序列必须得到合法闭区间，避免 `start...end` 在起止颠倒时崩溃。
    private var xDomain: ClosedRange<Date> {
        let window = engine.historyRange.window()
        return safeDateRange(from: window.start, to: window.end)
    }

    /// DatePicker 与坐标轴共用：起止相等或颠倒时仍返回合法闭区间。
    private func safeDateRange(from start: Date, to end: Date) -> ClosedRange<Date> {
        let lower = min(start, end)
        let upper = max(start, end)
        if lower == upper {
            return lower.addingTimeInterval(-1)...upper.addingTimeInterval(1)
        }
        return lower...upper
    }

    private var seriesIsEmpty: Bool {
        engine.chartResult.chartPoints.isEmpty && engine.chartResult.samples.isEmpty
    }

    private var emptyTitle: String {
        if engine.historySampleCount == 0 {
            return "还没有写入任何历史样本。"
        }
        return "当前时间范围内没有历史样本。"
    }

    private var emptyCaption: String {
        "睡眠与缺失功率不会补成 0。可扩大范围、确认未暂停记录，或等待下一次采样。"
    }

    /// 引擎未单独发布查询错误时，只在空曲线且错误文案像历史 IO 时展示失败态。
    private var historyFailureText: String? {
        guard seriesIsEmpty else { return nil }
        guard let error = engine.lastError, !error.isEmpty else { return nil }
        let hints = ["历史", "jsonl", "JSONL", "损坏", "decode", "corrupt", "样本文件"]
        guard hints.contains(where: { error.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }
        return error
    }

    /// 只消费引擎已按当前 HistoryRange 下采样的 chartPoints，不再次加载 30 天全量。
    private var percentSegments: [[HistoryChartPoint]] {
        splitSegments(engine.chartResult.chartPoints) { point in
            point.isGap || point.percent == nil
        }
    }

    private var wattsSegments: [(charging: Bool, points: [HistoryChartPoint])] {
        var result: [(Bool, [HistoryChartPoint])] = []
        var current: [HistoryChartPoint] = []
        var charging = true
        for point in engine.chartResult.chartPoints {
            guard !point.isGap, let watts = point.watts else {
                if !current.isEmpty {
                    result.append((charging, current))
                    current = []
                }
                continue
            }
            let isCharging = watts >= 0
            if current.isEmpty {
                charging = isCharging
                current = [point]
            } else if isCharging == charging {
                current.append(point)
            } else {
                result.append((charging, current))
                charging = isCharging
                current = [point]
            }
        }
        if !current.isEmpty {
            result.append((charging, current))
        }
        return result
    }

    private var gapRegions: [GapRegion] {
        Self.mergeGapRegions(
            Self.makeGapRegions(from: engine.chartResult.chartPoints) + sampleGapRegions
        )
    }

    /// 计数与端点变化时才重扫样本，避免悬停触发全量遍历。
    private var overlayRefreshKey: String {
        let points = engine.chartResult.chartPoints
        let samples = engine.chartResult.samples
        let first = samples.first?.epoch ?? points.first?.epoch ?? 0
        let last = samples.last?.epoch ?? points.last?.epoch ?? 0
        return "\(samples.count)-\(points.count)-\(first)-\(last)"
    }

    private func splitSegments(
        _ points: [HistoryChartPoint],
        shouldBreak: (HistoryChartPoint) -> Bool
    ) -> [[HistoryChartPoint]] {
        var segments: [[HistoryChartPoint]] = []
        var current: [HistoryChartPoint] = []
        for point in points {
            if shouldBreak(point) {
                if !current.isEmpty {
                    segments.append(current)
                    current = []
                }
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private var hoverSummary: String? {
        guard let hoverDate else { return nil }
        guard let point = nearestHoverPoint(to: hoverDate) else { return nil }
        let time = HistoryView.timeFormatter.string(from: Date(timeIntervalSince1970: point.epoch))
        let percent = point.percent.map { "\($0)%" } ?? "当前不可用"
        let watts: String
        if let value = point.watts {
            watts = String(format: "%+.1f W", value)
        } else {
            watts = "当前不可用"
        }
        let direction = directionZH(watts: point.watts, isGap: point.isGap)
        var text = "\(time)  ·  \(watts)  ·  \(percent)  ·  \(direction)"
        if let event = nearestOverlayEvent(to: point.epoch), abs(event.epoch - point.epoch) <= 30 {
            text += "  ·  \(event.caption)"
        }
        if point.isGap {
            text += "  ·  睡眠/间隙"
        }
        return text
    }

    /// 悬停只查当前范围下采样 chartPoints（≤1500），走 HistoryQuery.nearestPoint，不扫 30 天全量。
    private func nearestHoverPoint(to date: Date) -> HistoryChartPoint? {
        let points = engine.chartResult.chartPoints
        guard !points.isEmpty else { return nil }
        let epoch = date.timeIntervalSince1970
        let found = HistoryQuery.nearestPoint(in: points, epoch: epoch)
        guard let found else { return nil }
        if found.isGap {
            return Self.nearestNonGapPoint(in: points, around: found, epoch: epoch) ?? found
        }
        return found
    }

    private func nearestOverlayEvent(to epoch: TimeInterval) -> OverlayEvent? {
        overlayEvents.min { abs($0.epoch - epoch) < abs($1.epoch - epoch) }
    }

    private func applyCustomRange(from start: Date, to end: Date) {
        let orderedStart = min(start, end)
        var orderedEnd = max(start, end)
        if orderedStart == orderedEnd {
            orderedEnd = orderedStart.addingTimeInterval(60)
        }
        engine.setHistoryRange(.custom(from: orderedStart, to: orderedEnd))
    }

    /// 交给引擎按当前 HistoryRange 流式导出；曲线仍只用 ≤1500 的 chartResult。
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battcycle-history.csv"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                try engine.exportHistoryCSV(to: url)
            } catch {
                engine.presentError("导出失败：\(error.localizedDescription)")
            }
        }
    }

    private func refreshOverlays() {
        let built = Self.makeOverlays(from: engine.chartResult.samples)
        overlayEvents = built.events
        sampleGapRegions = built.gaps
    }

    private func estimateRow(_ name: String, value: String?, unit: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value ?? "当前不可用")
                .font(.body.monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
            if let value, !unit.isEmpty, value != "当前不可用" {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(EnergyEstimates.estimateLabel)，\(name)，\(value ?? "当前不可用") \(unit)")
    }

    private func energyText(_ value: Double?) -> String? {
        value.map { MetricDisplay.numberZH($0) }
    }

    private func optionalWatts(_ value: Double?) -> String? {
        value.map { MetricDisplay.numberZH($0) }
    }

    private func directionZH(watts: Double?, isGap: Bool) -> String {
        if isGap { return "间隙" }
        guard let watts else { return "当前不可用" }
        if watts > 0 { return "充电" }
        if watts < 0 { return "放电" }
        return "待机"
    }

    private static func nearestNonGapPoint(
        in points: [HistoryChartPoint],
        around gap: HistoryChartPoint,
        epoch: TimeInterval
    ) -> HistoryChartPoint? {
        guard let index = points.firstIndex(where: { $0.epoch == gap.epoch && $0.isGap }) else {
            return nil
        }
        var left = index - 1
        while left >= 0, points[left].isGap {
            left -= 1
        }
        var right = index + 1
        while right < points.count, points[right].isGap {
            right += 1
        }
        let leftPoint = left >= 0 ? points[left] : nil
        let rightPoint = right < points.count ? points[right] : nil
        switch (leftPoint, rightPoint) {
        case let (left?, right?):
            return abs(left.epoch - epoch) <= abs(right.epoch - epoch) ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        default:
            return nil
        }
    }

    private static func makeGapRegions(from points: [HistoryChartPoint]) -> [GapRegion] {
        guard !points.isEmpty else { return [] }
        var regions: [GapRegion] = []
        var index = 0
        while index < points.count {
            if points[index].isGap {
                let startEpoch = index > 0 ? points[index - 1].epoch : points[index].epoch
                var end = index
                while end < points.count, points[end].isGap {
                    end += 1
                }
                let endEpoch: TimeInterval
                if end < points.count {
                    endEpoch = points[end].epoch
                } else {
                    endEpoch = points[end - 1].epoch
                }
                let start = Date(timeIntervalSince1970: startEpoch)
                let finish = Date(timeIntervalSince1970: max(endEpoch, startEpoch + 1))
                regions.append(GapRegion(start: start, end: finish))
                index = end
            } else {
                index += 1
            }
        }
        return regions
    }

    private static func mergeGapRegions(_ regions: [GapRegion]) -> [GapRegion] {
        let ordered = regions.sorted { $0.start < $1.start }
        guard var current = ordered.first else { return [] }
        var merged: [GapRegion] = []
        for region in ordered.dropFirst() {
            if region.start <= current.end {
                current.end = max(current.end, region.end)
            } else {
                merged.append(current)
                current = region
            }
        }
        merged.append(current)
        return merged
    }

    private static let maxOverlayEvents = 96

    private static func makeOverlays(
        from samples: [HistorySample]
    ) -> (events: [OverlayEvent], gaps: [GapRegion]) {
        guard !samples.isEmpty else { return ([], []) }
        var events: [OverlayEvent] = []
        var gaps: [GapRegion] = []
        var previousAdapter: Bool?
        var previousPhase: String?
        var previous: HistorySample?
        for sample in samples {
            if sample.sleepGap == true {
                let start: Date
                if let previous {
                    start = previous.date
                } else {
                    let pad = TimeInterval(sample.intervalSeconds ?? 10)
                    start = sample.date.addingTimeInterval(-max(pad, 1))
                }
                if sample.date > start {
                    gaps.append(GapRegion(start: start, end: sample.date))
                }
            }
            if let adapter = sample.useAdapter {
                if let previousAdapter, previousAdapter != adapter {
                    events.append(
                        OverlayEvent(
                            epoch: sample.epoch,
                            kind: adapter ? .adapterOn : .adapterOff,
                            caption: adapter ? "适配器开启" : "适配器关闭",
                            percent: sample.percent
                        )
                    )
                }
                previousAdapter = adapter
            }
            if let phase = sample.enginePhase, !phase.isEmpty {
                if let previousPhase, previousPhase != phase {
                    events.append(
                        OverlayEvent(
                            epoch: sample.epoch,
                            kind: .phaseChange,
                            caption: "阶段 \(phaseTitleZH(phase))",
                            percent: sample.percent
                        )
                    )
                }
                previousPhase = phase
            }
            previous = sample
        }
        return (downsampleEvents(events, limit: maxOverlayEvents), gaps)
    }

    private static func downsampleEvents(_ events: [OverlayEvent], limit: Int) -> [OverlayEvent] {
        guard events.count > limit, limit > 2 else { return events }
        var picked: [OverlayEvent] = []
        picked.reserveCapacity(limit)
        var lastID: String?
        for step in 0..<limit {
            let index = Int((Double(step) * Double(events.count - 1) / Double(limit - 1)).rounded())
            let event = events[index]
            if event.id != lastID {
                picked.append(event)
                lastID = event.id
            }
        }
        return picked
    }

    private static func phaseTitleZH(_ raw: String) -> String {
        switch raw {
        case "charging": return "充电中"
        case "discharging": return "放电压测"
        case "init": return "启动中"
        case "failed": return "恢复失败"
        case "idle": return "空闲"
        case "cleanup": return "清理中"
        default: return raw
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

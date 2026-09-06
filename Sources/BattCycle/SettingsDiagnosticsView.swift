import AppKit
import BattCycleCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsDiagnosticsView: View {
    let historyDirectory: URL

    init(historyDirectory: URL = SupportPaths.historyDirectory) {
        self.historyDirectory = historyDirectory
    }

    @EnvironmentObject private var engine: EngineController
    @State private var customInterval = ""
    /// 自定义间隔校验失败时的行内说明；非法输入不得写入 monitor 设置。
    @State private var intervalError: String?
    @State private var showingClearConfirmation = false
    /// 全部历史的首尾样本时间；打开清除确认时刷新，不跟当前曲线范围走。
    @State private var allHistoryFirstAt: Date?
    @State private var allHistoryLastAt: Date?

    var body: some View {
        DashboardForm {
            DashboardSection("历史记录") {
                Picker("记录间隔", selection: intervalBinding) {
                    ForEach(intervalChoices, id: \.self) { seconds in
                        Text(intervalLabel(seconds)).tag(seconds)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("自定义间隔")
                        // 单位只保留右侧「秒」，占位符不再写「秒」，避免重复。
                        TextField("2–3600", text: $customInterval)
                            .frame(width: 72)
                        Text("秒")
                        Button("应用") { applyCustomInterval() }
                    }
                    if let intervalError {
                        Text(intervalError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("记录间隔只写入 \(Self.monitorDisplayPath)，不会改写引擎 \(Self.configDisplayPath)（仍为六键）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("保留天数", selection: retentionBinding) {
                    ForEach(MonitorSettings.allowedRetentionDays, id: \.self) { days in
                        Text("\(days) 天").tag(days)
                    }
                }
                labeled("样本数量", value: "\(engine.historySampleCount)")
                labeled("占用空间", value: MetricDisplay.bytesZH(engine.historyByteCount))
                HStack {
                    if engine.monitorSettings.recordingPaused {
                        Button("继续记录") { engine.resumeRecording() }
                    } else {
                        Button("暂停记录") { engine.pauseRecording() }
                    }
                    Button("导出 CSV") { exportCSV() }
                    Button("清除历史…", role: .destructive) {
                        showingClearConfirmation = true
                    }
                }
            }

            DashboardSection("三路时钟") {
                labeled("记录间隔", value: recordingClockValue)
                labeled("引擎轮询", value: enginePollClockValue)
                labeled("守护心跳", value: heartbeatClockValue)
                Text(threeClocksNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            DashboardSection("监测默认值") {
                Button("恢复默认监测设置") {
                    engine.restoreDefaultMonitorSettings()
                    customInterval = ""
                    intervalError = nil
                }
                Text("只重置 \(Self.monitorDisplayPath)，不改 \(Self.configDisplayPath) 的六键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DashboardSection("隐私") {
                Text("数据仅保存在本机，无账号、无遥测、不同步 iCloud。")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                privacyPathRow("循环六键", path: Self.configDisplayPath)
                privacyPathRow("记录间隔、暂停、保留天数", path: Self.monitorDisplayPath)
                privacyPathRow("历史 JSONL", path: Self.historyDisplayPath)
                privacyPathRow("守护心跳", path: Self.guardianDisplayPath)
                privacyPathRow("引擎日志", path: Self.logsDisplayPath)
                Text("历史键不得写入 config.json；config.json 只保留 upperLimit、lowerLimit、gpuSize、cpuJobs、pollSeconds、stopAtEpoch。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            DashboardSection("能力") {
                if engine.capabilities.capabilities.isEmpty {
                    Text("能力清单尚未就绪。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        capabilityMatrix
                    }
                }
            }

            DashboardSection("运行环境") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: engine.environmentReady ? "checkmark.circle.fill" : "wrench.and.screwdriver.fill")
                        .foregroundStyle(engine.environmentReady ? Color.green : Color.secondary)
                    Text(engine.environmentMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(engine.environmentChecking ? "检查中…" : "重新检查") {
                        engine.checkEnvironment()
                    }
                    .disabled(engine.environmentChecking || engine.busy)
                }
                Text("重新检查只验证循环就绪条件。监测在 daemon 不可用时仍继续。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DashboardSection("诊断") {
                HStack {
                    Button("打开运行日志") { engine.openLog() }
                    Button("打开日志文件夹") { engine.revealLogs() }
                }
                Text("日志位于 \(Self.logsDisplayPath)，与历史 JSONL 分开。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if !MonitorSettings.presetIntervals.contains(engine.monitorSettings.historyIntervalSeconds) {
                customInterval = "\(engine.monitorSettings.historyIntervalSeconds)"
            }
            refreshAllHistoryBounds()
        }
        .onChange(of: showingClearConfirmation) { _, showing in
            if showing { refreshAllHistoryBounds() }
        }
        .onChange(of: engine.historySampleCount) { _, _ in
            refreshAllHistoryBounds()
        }
        .onChange(of: engine.lastSampleAt) { _, _ in
            refreshAllHistoryBounds()
        }
        .confirmationDialog(
            "清除全部历史？",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除全部历史", role: .destructive) {
                engine.clearHistoryAndReport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(clearHistoryMessage)
        }
    }

    /// 能力矩阵：在现有名称/取值之外展示 supportedRange、risk、requiresConfirmation。
    private var capabilityMatrix: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                matrixHeader("名称")
                matrixHeader("当前值")
                matrixHeader("支持范围")
                matrixHeader("风险")
                matrixHeader("需确认")
                matrixHeader("读写")
                matrixHeader("来源")
            }
            ForEach(engine.capabilities.capabilities) { capability in
                GridRow {
                    Text(capability.nameZH)
                        .font(.caption)
                    HStack(spacing: 4) {
                        Text(MetricDisplay.capabilityValueZH(capability.currentValue))
                            .font(.caption.monospacedDigit())
                        if !capability.unit.isEmpty {
                            Text(capability.unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(supportedRangeText(capability))
                        .font(.caption)
                    Text(riskZH(capability.risk))
                        .font(.caption)
                    Text(MetricDisplay.boolZH(capability.requiresConfirmation))
                        .font(.caption)
                    Text(readWriteZH(capability))
                        .font(.caption)
                    Text(MetricDisplay.sourceZH(capability.source))
                        .font(.caption)
                }
                if let detail = capabilityDetail(capability) {
                    GridRow {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .gridCellColumns(7)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("能力矩阵")
    }

    private func matrixHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var intervalChoices: [Int] {
        let current = engine.monitorSettings.historyIntervalSeconds
        if MonitorSettings.presetIntervals.contains(current) {
            return MonitorSettings.presetIntervals
        }
        return (MonitorSettings.presetIntervals + [current]).sorted()
    }

    private var intervalBinding: Binding<Int> {
        Binding(
            get: { engine.monitorSettings.historyIntervalSeconds },
            set: { engine.setHistoryInterval($0) }
        )
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { engine.monitorSettings.retentionDays },
            set: { engine.setRetentionDays($0) }
        )
    }

    /// `clearHistory` 删除 history 目录内全部 *.jsonl，文案必须写「全部历史」，不得写成当前曲线范围。
    /// 计数使用引擎已发布的 `historySampleCount` / `historyByteCount`（来自 HistoryStore）。
    /// 路径用 ~ 展示，不展开到用户名。首尾日期来自全部 JSONL，不是当前图表窗口。
    private var clearHistoryMessage: String {
        let scope = "\(Self.historyDisplayPath)/ 下全部 *.jsonl"
        var parts = [
            "将删除全部历史 JSONL（\(scope)），不影响 config.json、monitor.json 与日志。",
            "共 \(engine.historySampleCount) 条样本，占用 \(MetricDisplay.bytesZH(engine.historyByteCount))。"
        ]
        if engine.historySampleCount > 0 {
            parts.append(allHistoryDateRangeText)
        }
        return parts.joined(separator: " ")
    }

    /// 有首尾则写「最早–最晚」；缺一侧则写已知端点；都缺则写未知。仍是全部历史，不是当前曲线。
    private var allHistoryDateRangeText: String {
        let first = allHistoryFirstAt
        let last = allHistoryLastAt ?? engine.lastSampleAt
        switch (first, last) {
        case let (first?, last?):
            return "日期范围 \(Self.dateTimeFormatter.string(from: first)) – \(Self.dateTimeFormatter.string(from: last))。"
        case (nil, let last?):
            return "日期范围未知（已知最近样本 \(Self.dateTimeFormatter.string(from: last))）。"
        case (let first?, nil):
            return "日期范围未知（已知最早样本 \(Self.dateTimeFormatter.string(from: first))）。"
        case (nil, nil):
            return "日期范围未知。"
        }
    }

    /// 读写列不打印 raw `writable`：最大充电功率与 batt 上限永远「只读」。
    private func readWriteZH(_ capability: Capability) -> String {
        if CapabilityID.forbidsWritableControl(capability.id) {
            return "只读"
        }
        switch capability.controlState {
        case .writable:
            return "可写"
        case .readable:
            return "只读"
        case .unsupported:
            return "不支持"
        }
    }

    /// 扫描全部 `samples-*.jsonl` 的首尾样本；不读当前 `historyRange` / chartResult。
    private func refreshAllHistoryBounds() {
        let bounds = scanAllHistoryBounds(lastSampleHint: engine.lastSampleAt)
        allHistoryFirstAt = bounds.first
        allHistoryLastAt = bounds.last
    }

    /// 全部历史首尾：只看 history 目录里的 `samples-*.jsonl`，不用当前曲线窗口。
    private func scanAllHistoryBounds(lastSampleHint: Date?) -> (first: Date?, last: Date?) {
        let urls = allHistoryJSONLURLs()
        guard let oldest = urls.first, let newest = urls.last else {
            return (nil, lastSampleHint)
        }
        let first = firstSampleDate(in: oldest) ?? dateFromJSONLFileName(oldest)
        let fileLast = lastSampleDate(in: newest) ?? dateFromJSONLFileName(newest)
        if let hint = lastSampleHint, let fileLast {
            return (first, max(hint, fileLast))
        }
        return (first, lastSampleHint ?? fileLast)
    }

    private func allHistoryJSONLURLs() -> [URL] {
        let directory = historyDirectory
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("samples-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func firstSampleDate(in url: URL) -> Date? {
        sampleDate(fromText: readJSONLPrefix(url), preferLast: false)
    }

    private func lastSampleDate(in url: URL) -> Date? {
        sampleDate(fromText: readJSONLSuffix(url), preferLast: true)
    }

    private func readJSONLPrefix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16 * 1024)
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readJSONLSuffix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let maxBytes: UInt64 = 16 * 1024
        let start = size > maxBytes ? size - maxBytes : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sampleDate(fromText text: String?, preferLast: Bool) -> Date? {
        guard let text else { return nil }
        let decoder = JSONDecoder()
        var found: Date?
        text.enumerateLines { line, stop in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
            guard let sample = try? decoder.decode(HistorySample.self, from: data) else { return }
            found = sample.date
            if !preferLast {
                stop = true
            }
        }
        return found
    }

    /// 文件名 `samples-YYYY-MM-DD.jsonl` 的日期，解码失败时的兜底，仍是全部历史而非当前曲线。
    private func dateFromJSONLFileName(_ url: URL) -> Date? {
        let name = url.lastPathComponent
        guard name.hasPrefix("samples-"), name.hasSuffix(".jsonl") else { return nil }
        let stamp = name.dropFirst("samples-".count).dropLast(".jsonl".count)
        let parts = stamp.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// 三路时钟互不耦合：记录间隔只影响曲线密度，不得放松引擎轮询或 2 秒心跳。
    private var recordingClockValue: String {
        "\(engine.monitorSettings.historyIntervalSeconds) 秒 · \(Self.monitorDisplayPath)"
    }

    private var enginePollClockValue: String {
        "\(engine.config.pollSeconds) 秒 · \(Self.configDisplayPath) pollSeconds"
    }

    private var heartbeatClockValue: String {
        let seconds = Int(SamplingPolicy.heartbeatSeconds)
        return "\(seconds) 秒 · \(Self.guardianDisplayPath)，不可改"
    }

    private var threeClocksNote: String {
        "三路独立：记录间隔（本页，2–3600）只写入 monitor.json；引擎轮询 pollSeconds（5–60）只在「循环实验」改 config.json；守护心跳固定 2 秒，写 guardian.json。改记录间隔不会放松心跳，也不会改 pollSeconds。"
    }

    private func intervalLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        return "\(seconds / 60) 分钟"
    }

    private func applyCustomInterval() {
        let trimmed = customInterval.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Int(trimmed), MonitorSettings.intervalRange.contains(seconds) else {
            // 非法输入只提示、不调用 setHistoryInterval，避免被夹紧后静默写入。
            let message = "请输入 2 到 3600 之间的整数秒，未保存。"
            intervalError = message
            return
        }
        intervalError = nil
        engine.setHistoryInterval(seconds)
    }

    private func supportedRangeText(_ capability: Capability) -> String {
        guard let range = capability.supportedRange else { return "—" }
        let lower = formatRangeBound(range.lowerBound)
        let upper = formatRangeBound(range.upperBound)
        if capability.unit.isEmpty {
            return "\(lower)…\(upper)"
        }
        return "\(lower)…\(upper) \(capability.unit)"
    }

    private func formatRangeBound(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return MetricDisplay.numberZH(value)
    }

    private func riskZH(_ risk: CapabilityRisk) -> String {
        switch risk {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }

    private func capabilityDetail(_ capability: Capability) -> String? {
        let parts = [capability.unavailableReasonZH, capability.noteZH].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private func labeled(_ name: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name)，\(value)")
    }

    /// 展示用路径一律写 ~，不把本机用户名画进界面。
    private func privacyPathRow(_ purpose: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(purpose)
                .font(.caption)
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(purpose)，\(path)")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battcycle-history.csv"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try engine.exportHistoryCSV(to: url)
            } catch {
                engine.presentError("导出失败：\(error.localizedDescription)")
            }
        }
    }

    /// 本机展示路径：不展开 FileManager 主目录，避免界面泄露账号名。
    private static let supportDisplayRoot = "~/Library/Application Support/BattCycle"
    private static let configDisplayPath = "\(supportDisplayRoot)/config.json"
    private static let monitorDisplayPath = "\(supportDisplayRoot)/monitor.json"
    private static let historyDisplayPath = "\(supportDisplayRoot)/history"
    private static let guardianDisplayPath = "\(supportDisplayRoot)/guardian.json"
    private static let logsDisplayPath = "~/Library/Logs/BattCycle"

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

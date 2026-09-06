import AppKit
import BattCycleCore
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SwiftUI

/// 独立限时适配器命令的界面状态。不使用 stop/restore，以免误停循环引擎。
enum AdapterCommandState: Equatable {
    case idle
    case running
    case success
    case failed
    case timeout
    case unknown

    var statusTitleZH: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "执行中"
        case .success: return "成功"
        case .failed: return "失败"
        case .timeout: return "超时"
        case .unknown: return "未知"
        }
    }
}

final class EngineController: ObservableObject {
    @Published var config: CycleConfig
    @Published var snapshot: BatterySnapshot = .empty
    @Published var flow: EnergyFlow
    @Published var metrics: PowerMetrics
    @Published var trust: DataTrust = .unavailable
    @Published var battStatus: BattStatusSnapshot?
    @Published var capabilities: CapabilityInventory
    @Published var monitorSettings: MonitorSettings
    @Published var recordingState: RecordingController.State = .idle
    @Published var lastSampleAt: Date?
    @Published var nextHistorySampleAt: Date?
    @Published var lastHeartbeatAt: Date?
    @Published var historyRange: HistoryRange = .hours1
    @Published var chartResult = HistoryQueryResult(samples: [], chartPoints: [])
    @Published var energyEstimates: EnergyEstimates?
    @Published var advice: [Advice] = []
    @Published var adapterCommandState: AdapterCommandState = .idle
    @Published var adapterCommandMessageZH = "尚未执行适配器命令"
    @Published var adapterSuspendSeconds = 300
    @Published var adapterAutoEnableAt: Date?
    @Published var historySampleCount = 0
    @Published var historyByteCount = 0
    @Published var engine: EngineState = .idle
    @Published var lastError: String?
    @Published var lastMessage: String?
    @Published private(set) var busy = false
    /// restore 成功时递增；迟到的 suspend 完成必须对照此代次忽略。
    @Published private(set) var controlGeneration: UInt64 = 0
    @Published private(set) var controlTransaction: ControlTransaction = .idle
    @Published private(set) var environmentChecking = false
    @Published private(set) var environmentReady = false
    @Published private(set) var environmentMessage = "尚未检查运行环境"
    @Published private(set) var thermalSafe = false
    @Published private(set) var thermalMessage = "正在建立热状态守护…"
    @Published private(set) var running = false

    /// 每拍只调用 `batteryProvider.capture()` 一次，再交给 `SnapshotTick.derive`。
    /// 测试可注入带计数器的 Mock：第二次 capture 不得用于流向、指标、历史或信任。
    private let batteryProvider: any BatteryProviding
    private let historyStore: HistoryStore
    private let recordingController: RecordingController
    private let adviceEngine = AdviceEngine()
    private var lastAdviceForCooldown: [Advice] = []
    private var timer: Timer?
    private var tickInFlight = false
    private var lastPruneAt: Date?
    private var lastDerivedAt: Date?
    // 范围切换或清空后，拒绝迟到的历史计算结果。
    private var historyGeneration: UInt64 = 0
    // 只有清空会作废采样确认；切换图表范围不能丢掉已写入的采样或间隙确认。
    private var recordingClearGeneration: UInt64 = 0
    private var timedDisableSupported = false
    private var battVersionOk = false
    /// Restore 在其它事务进行中排队，当前事务结束后再执行。
    private var pendingRestore = false
    /// 倒计时归零后只警告一次，避免每拍刷 lastError。
    private var adapterExpiryWarned = false
    /// 截止复核进行中，避免每拍重复打 batt status。
    private var adapterExpiryVerifying = false
    /// 当前连续段。仅在 sleepGap 成功写入后换新，失败不推进。
    private var liveSegmentId: String?
    private let workQueue = DispatchQueue(label: "org.alfwuxy.BattCycle.tick", qos: .utility)

    init(batteryProvider: BatteryProviding = IOKitBatteryProvider()) {
        self.batteryProvider = batteryProvider
        let loadedConfig = Self.loadConfig()
        config = loadedConfig
        let settings = Self.loadMonitorSettings()
        monitorSettings = settings
        historyStore = HistoryStore(directory: SupportPaths.historyDirectory, settings: settings)
        recordingController = RecordingController(
            policy: SamplingPolicy(
                historyInterval: TimeInterval(settings.historyIntervalSeconds),
                enginePollSeconds: loadedConfig.pollSeconds
            )
        )
        flow = EnergyFlow.classify(.empty)
        metrics = PowerMetrics.assemble(snapshot: .empty)
        capabilities = CapabilityInventory.build(
            snapshot: nil,
            battVersionOk: false,
            timedDisableSupported: false,
            daemonReachable: false,
            cycleUpperPercent: loadedConfig.upperLimit,
            cycleLowerPercent: loadedConfig.lowerLimit
        )
        recordingController.start()
        if settings.recordingPaused {
            recordingController.pause()
        }
        recordingState = recordingController.state
    }

    func startPolling() {
        refreshReadOnlyProbes()
        pruneHistoryInBackground(force: true)
        tick()
        checkEnvironment()
        timer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // common 模式：菜单跟踪时仍写入 2 秒心跳，避免 guardian 过期。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isRunning: Bool { running }

    /// Stop：pid 仍在或循环判定运行中即可点；监测失败不得挡住停止。busy 时禁用。
    var canStop: Bool { hasActiveEngine && !busy }

    /// Restore 最高优先级：仅在已经执行 restore 时忽略重复请求。窗口若仍绑定 `busy`，菜单栏 Restore 仍可排队。
    var canRequestRestore: Bool {
        controlTransaction.restoreArrival() != .ignoreDuplicate
    }

    var phaseLabel: String {
        switch engine.phase {
        case "charging": return "充电中（到上限）"
        case "discharging": return "放电压测中（到下限）"
        case "init": return "启动中"
        case "failed": return "恢复失败"
        case "idle": return isRunning ? "循环运行中" : "空闲"
        default: return engine.phase.isEmpty ? (isRunning ? "循环运行中" : "空闲") : engine.phase
        }
    }

    var menuBarTitle: String {
        guard snapshot.isAvailable else { return "Batt" }
        var title = ""
        if snapshot.percentIsAvailable {
            title += "\(snapshot.percent)%"
        }
        switch flow.direction {
        case .charging: title += "↑"
        case .discharging: title += "↓"
        case .idle: title += "·"
        case .unknown: title += "?"
        }
        if monitorSettings.recordingPaused {
            title += "⏸"
        }
        return title.isEmpty ? "Batt" : title
    }

    var hasActiveEngine: Bool {
        busy || isRunning || Self.recordedPID() != nil
    }

    /// 循环占用适配器时禁止独立开关；Restore 不受此限制。
    var adapterManualControlBlockedReason: String? {
        if isRunning || Self.recordedPID() != nil {
            return "主动循环正在运行，适配器由循环引擎管理"
        }
        return nil
    }

    func systemWillSleep() {
        recordingController.systemWillSleep()
        recordingState = recordingController.state
    }

    func systemDidWake() {
        recordingController.systemDidWake()
        recordingState = recordingController.state
        updateNextSampleEstimate()
    }

    func checkEnvironment() {
        guard !environmentChecking else { return }
        environmentChecking = true
        environmentMessage = "正在检查 batt、stress-ng 与 MLX…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let readiness = try BattService.preflight()
                DispatchQueue.main.async {
                    self.environmentReady = true
                    self.environmentMessage = readiness.summary
                    self.environmentChecking = false
                    self.refreshReadOnlyProbes()
                }
            } catch {
                DispatchQueue.main.async {
                    self.environmentReady = false
                    self.environmentMessage = error.localizedDescription
                    self.environmentChecking = false
                    // 预检失败不阻止监测；仍刷新只读探针。
                    self.refreshReadOnlyProbes()
                }
            }
        }
    }

    @discardableResult
    func saveConfig() -> Bool {
        do {
            let valid = try config.validated()
            let data = try JSONEncoder.pretty.encode(valid)
            try SupportPaths.ensurePrivateDirectories()
            try data.write(to: SupportPaths.config, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: SupportPaths.config.path
            )
            config = valid
            applySamplingPolicy()
            rebuildCapabilities()
            return true
        } catch {
            lastError = "配置未保存：\(error.localizedDescription)"
            return false
        }
    }

    func restoreDefaultCycleConfig() {
        config = .default
        _ = saveConfig()
    }

    func restoreDefaultMonitorSettings() {
        monitorSettings = .default
        persistMonitorSettings()
        applySamplingPolicy()
        recordingController.start()
        recordingController.resume()
        recordingState = recordingController.state
        updateNextSampleEstimate()
    }

    func setHistoryInterval(_ seconds: Int) {
        let clamped = min(
            MonitorSettings.intervalRange.upperBound,
            max(MonitorSettings.intervalRange.lowerBound, seconds)
        )
        monitorSettings.historyIntervalSeconds = clamped
        persistMonitorSettings()
        applySamplingPolicy()
        updateNextSampleEstimate()
    }

    func pauseRecording() {
        monitorSettings.recordingPaused = true
        recordingController.pause()
        recordingState = recordingController.state
        persistMonitorSettings()
        updateNextSampleEstimate()
    }

    func resumeRecording() {
        monitorSettings.recordingPaused = false
        recordingController.resume()
        recordingState = recordingController.state
        persistMonitorSettings()
        updateNextSampleEstimate()
    }

    func setRetentionDays(_ days: Int) {
        guard MonitorSettings.allowedRetentionDays.contains(days) else { return }
        monitorSettings.retentionDays = days
        persistMonitorSettings()
        pruneHistoryInBackground(force: true)
    }

    func setHistoryRange(_ range: HistoryRange) {
        historyGeneration &+= 1
        historyRange = range
        chartResult = .empty
        energyEstimates = nil
        refreshDerivedInBackground(force: true)
    }

    func exportCSVText() -> String {
        HistoryCSV.export(samples: chartResult.samples, energy: energyEstimates)
    }

    /// 按当前 `HistoryRange` 流式导出全量 CSV，不经过图表 ≤1500 下采样。
    /// 空窗口仍写出表头；若已有该范围的能量估算则附带「估算」汇总。
    func exportHistoryCSV(to url: URL) throws {
        let range = historyRange
        let energy = energyEstimates
        try HistoryCSV.export(to: url, energy: energy) { yield in
            try HistoryQuery.forEachSample(store: self.historyStore, range: range) { sample in
                try yield(sample)
            }
        }
    }

    func presentError(_ message: String) {
        lastError = message
    }

    func clearHistoryAndReport() {
        do {
            try clearHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clearHistory() throws {
        try historyStore.clearHistory()
        historyGeneration &+= 1
        recordingClearGeneration &+= 1
        chartResult = HistoryQueryResult(samples: [], chartPoints: [])
        energyEstimates = nil
        advice = []
        lastAdviceForCooldown = []
        historySampleCount = 0
        historyByteCount = 0
        lastSampleAt = nil
        liveSegmentId = nil
        workQueue.async { [weak self] in
            self?.liveSegmentId = nil
        }
        updateNextSampleEstimate()
    }

    func suspendAdapterConfirmed() {
        if isRunning || Self.recordedPID() != nil {
            adapterCommandState = .failed
            adapterCommandMessageZH = "循环运行中请使用引擎或先停止"
            lastError = adapterCommandMessageZH
            return
        }
        guard beginTransaction(.suspend) else { return }
        let seconds = min(600, max(1, adapterSuspendSeconds))
        let generation = controlGeneration
        // 保守倒计时：在等待 batt 命令之前立刻显示，避免超时窗口空白。
        adapterAutoEnableAt = Date().addingTimeInterval(TimeInterval(seconds))
        adapterExpiryWarned = false
        adapterCommandState = .running
        adapterCommandMessageZH = "执行中"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.suspendAdapter(seconds: seconds)
                DispatchQueue.main.async {
                    self.finishSuspend(generation: generation, result: .success(result), status: nil)
                }
            } catch {
                let status = try? BattService.readStatusJSON()
                DispatchQueue.main.async {
                    self.finishSuspend(generation: generation, result: .failure(error), status: status)
                }
            }
        }
    }

    func resumeAdapterNow() {
        if isRunning || Self.recordedPID() != nil {
            adapterCommandState = .failed
            adapterCommandMessageZH = "主动循环正在运行，适配器由循环引擎管理"
            lastError = adapterCommandMessageZH
            return
        }
        guard beginTransaction(.resume) else { return }
        adapterCommandState = .running
        adapterCommandMessageZH = "执行中"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.resumeAdapter()
                DispatchQueue.main.async {
                    self.adapterCommandState = .success
                    self.adapterCommandMessageZH = result
                    self.adapterAutoEnableAt = nil
                    self.adapterExpiryWarned = false
                    self.lastMessage = result
                    self.endTransaction()
                    self.rereadBattStatus()
                }
            } catch {
                DispatchQueue.main.async {
                    self.applyAdapterError(error)
                    self.endTransaction()
                }
            }
        }
    }

    func start() {
        guard controlTransaction == .idle, !isRunning else { return }
        lastError = nil
        lastMessage = nil
        // 引擎以 guardian.json 超过 10 秒为 fail-closed；启动前必须先写入心跳。
        let thermal = ProcessInfo.processInfo.thermalState
        if let heartbeatError = Self.writeGuardianHeartbeat(thermalState: thermal) {
            lastError = heartbeatError
            thermalSafe = false
            thermalMessage = heartbeatError
            return
        }
        lastHeartbeatAt = Date()
        let thermalAllowed = thermal == .nominal || thermal == .fair
        thermalSafe = thermalAllowed
        thermalMessage = Self.thermalDescription(thermal)
        if !thermalAllowed {
            lastError = thermalMessage
            return
        }
        if BattService.shouldBlockEngineStart(status: battStatus) {
            lastError = "手动限时切断适配器仍在生效，请先恢复适配器后再启动循环"
            adapterCommandState = .unknown
            return
        }
        guard saveConfig() else { return }

        do {
            if FileManager.default.fileExists(atPath: SupportPaths.stopRequest.path) {
                try FileManager.default.removeItem(at: SupportPaths.stopRequest)
            }
        } catch {
            lastError = "无法清除旧停止请求：\(error.localizedDescription)"
            return
        }

        guard beginTransaction(.start) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BattService.start()
                var started = false
                for _ in 0..<50 {
                    Thread.sleep(forTimeInterval: 0.2)
                    if Self.pidFileAlive() != nil {
                        started = true
                        break
                    }
                }
                DispatchQueue.main.async {
                    self.tick()
                    if started {
                        self.environmentReady = true
                        self.lastMessage = "循环引擎已启动"
                    } else {
                        self.lastError = "启动脚本已返回，但引擎没有进入运行状态。\(Self.launchFailureHint())"
                    }
                    self.endTransaction()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.environmentReady = false
                    self.environmentMessage = error.localizedDescription
                    self.endTransaction()
                }
            }
        }
    }

    func stop() {
        stop(reason: nil)
    }

    private func stop(reason: String?) {
        guard beginTransaction(.stop) else { return }
        lastError = reason
        lastMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.stopCycle()
                DispatchQueue.main.async {
                    self.lastMessage = "循环已停止，适配器已验证恢复：\(result)"
                    self.endTransaction()
                    self.tick()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.endTransaction()
                    self.tick()
                }
            }
        }
    }

    func restorePower() {
        switch controlTransaction.restoreArrival() {
        case .ignoreDuplicate:
            return
        case .queuePending:
            // 切断进行中不启动第二次 disable；当前事务结束后再 restore。
            pendingRestore = true
            return
        case .beginNow:
            break
        }
        lastError = nil
        lastMessage = nil
        guard beginTransaction(.restore) else { return }
        adapterCommandState = .running
        adapterCommandMessageZH = "执行中"

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try BattService.restoreAdapter()
                DispatchQueue.main.async {
                    self.controlGeneration &+= 1
                    self.lastMessage = "适配器恢复成功：\(result)"
                    self.adapterAutoEnableAt = nil
                    self.adapterExpiryWarned = false
                    self.adapterCommandState = .success
                    self.adapterCommandMessageZH = result
                    self.endTransaction()
                    self.tick()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                    self.applyAdapterError(error)
                    self.endTransaction()
                }
            }
        }
    }

    func openLog() {
        revealLogs()
    }

    func revealLogs() {
        let latest = SupportPaths.latestLog
        if FileManager.default.fileExists(atPath: latest.path) {
            NSWorkspace.shared.open(latest)
        } else if !engine.log.isEmpty {
            let candidate = URL(fileURLWithPath: engine.log).standardizedFileURL
            let root = SupportPaths.logs.standardizedFileURL.path + "/"
            if candidate.path.hasPrefix(root), FileManager.default.fileExists(atPath: candidate.path) {
                NSWorkspace.shared.open(candidate)
            } else {
                NSWorkspace.shared.open(SupportPaths.logs)
            }
        } else {
            NSWorkspace.shared.open(SupportPaths.logs)
        }
    }

    func refresh() {
        tick()
    }

    /// 2 秒节拍：先写心跳，再采集与历史。历史 IO 不得拖住 guardian 新鲜度。
    private func tick() {
        let now = Date()
        let thermal = ProcessInfo.processInfo.thermalState
        let heartbeatError = Self.writeGuardianHeartbeat(thermalState: thermal)
        if heartbeatError == nil {
            lastHeartbeatAt = now
        }

        let thermalAllowed = thermal == .nominal || thermal == .fair
        thermalSafe = heartbeatError == nil && thermalAllowed
        thermalMessage = heartbeatError ?? Self.thermalDescription(thermal)
        if running, !thermalSafe, !busy {
            stop(reason: "热状态守护触发停止：\(thermalMessage)")
        }

        syncSamplingPolicyIfNeeded()
        expireAdapterCountdown(now: now)
        recordingState = recordingController.state

        let shouldRecord = recordingController.shouldRecordHistory(now: now, lastHistoryAt: lastSampleAt)
        let markGap = shouldRecord && recordingController.needsGap
        let lastSample = lastSampleAt
        let settings = monitorSettings
        let range = historyRange
        let generation = historyGeneration
        let clearGeneration = recordingClearGeneration
        let phase = engine.phase
        let paused = settings.recordingPaused
        let needDerived = shouldRefreshDerived(now: now) || shouldRecord
        let provider = batteryProvider
        let versionOk = battVersionOk
        let timedDisable = timedDisableSupported
        let upper = config.upperLimit
        let lower = config.lowerLimit
        let previousAdvice = lastAdviceForCooldown
        let pruneDue = lastPruneAt == nil || now.timeIntervalSince(lastPruneAt ?? .distantPast) >= 3_600
        let longRange = Self.isLongHistoryRange(range, now: now)
        // 长窗口不在 2 秒心跳里流式重读；范围切换或 ≥60s 慢节奏走 refreshDerived。
        if longRange {
            let cadence = max(TimeInterval(settings.historyIntervalSeconds), 60)
            if lastDerivedAt == nil || now.timeIntervalSince(lastDerivedAt!) >= cadence {
                lastDerivedAt = now
                refreshDerivedInBackground(force: true)
            }
        }

        if tickInFlight {
            return
        }
        tickInFlight = true

        workQueue.async { [weak self] in
            guard let self else { return }
            // 每拍对存储的 provider 恰好 capture 一次；适配器详情只读另采一次，不二次 capture 电池。
            let snapshot = provider.capture()
            let derived = SnapshotTick.derive(
                snapshot: snapshot,
                now: Date(),
                heartbeatInterval: SamplingPolicy.heartbeatSeconds
            )
            let adapterDetails = Self.readExternalAdapterDetailsOnce()
            let physicallyConnected = Self.readExternalConnectedOnce()
            let metrics = PowerMetrics.assemble(
                snapshot: snapshot,
                adapterDetails: adapterDetails,
                adapterPhysicallyConnected: physicallyConnected
            )
            let flow = derived.flow
            let trust = derived.trust
            let battStatus: BattStatusSnapshot?
            if FileManager.default.isExecutableFile(atPath: SupportPaths.battExecutable.path) {
                battStatus = try? BattService.readStatusJSON()
            } else {
                battStatus = nil
            }
            let state = Self.loadState()
            let running = Self.computeRunning(state)
            let recoveryNeeded = state.running && !running && Self.recordedPID() == state.pid

            var recordedAt: Date?
            var consumeGap = false
            if shouldRecord {
                // 间隙样本开启新段；连续样本沿用同一 id。失败不提交，以免空转 UUID。
                let segmentId = (markGap || self.liveSegmentId == nil)
                    ? UUID().uuidString
                    : self.liveSegmentId!
                let sample = HistorySample.makeLive(
                    at: now,
                    snapshot: snapshot,
                    direction: flow.direction,
                    battStatus: battStatus,
                    thermal: Self.thermalStateName(thermal),
                    enginePhase: state.phase.isEmpty ? phase : state.phase,
                    recordingPaused: paused,
                    intervalSeconds: settings.historyIntervalSeconds,
                    segmentId: segmentId,
                    sleepGap: markGap ? true : nil
                )
                // bestEffort 不抛错；仅 .written 才消费睡眠间隙并提交段 id。
                switch self.historyStore.bestEffortAppend(sample) {
                case .written:
                    recordedAt = now
                    consumeGap = markGap
                    self.liveSegmentId = segmentId
                case .skippedPaused, .failed:
                    consumeGap = false
                }
            }

            if pruneDue {
                try? self.historyStore.prune(now: now)
            }

            var chart: HistoryQueryResult?
            var estimates: EnergyEstimates?
            var energyFailure: String?
            var newAdvice: [Advice]?
            var sampleCount: Int?
            var byteCount: Int?
            if needDerived || recordedAt != nil {
                sampleCount = try? self.historyStore.sampleCount()
                byteCount = try? self.historyStore.estimatedBytes()
                // 建议只查约 1 小时；心跳不得 HistoryQuery.load 24h/7d/30d。
                let adviceLoaded = try? HistoryQuery.load(
                    store: self.historyStore,
                    range: SnapshotTick.adviceLookbackRange,
                    now: now,
                    intervalSeconds: settings.historyIntervalSeconds
                )
                let adviceSource = adviceLoaded?.samples ?? []
                // current = f(context)，空列表也要写回，条件结束后建议页不得残留。
                newAdvice = self.evaluateAdvice(
                    samples: adviceSource,
                    settings: settings,
                    sampleCount: sampleCount ?? adviceSource.count,
                    ratedWatts: metrics.adapterRatedMaxWatts.value,
                    previous: previousAdvice,
                    now: now
                )
                if !longRange {
                    if range == SnapshotTick.adviceLookbackRange, let adviceLoaded {
                        chart = adviceLoaded
                    } else {
                        chart = try? HistoryQuery.load(
                            store: self.historyStore,
                            range: range,
                            now: now,
                            intervalSeconds: settings.historyIntervalSeconds
                        )
                    }
                    do {
                        estimates = try EnergyEstimates.estimateHistory(
                            store: self.historyStore,
                            range: range,
                            now: now,
                            intervalSeconds: settings.historyIntervalSeconds
                        )
                    } catch {
                        energyFailure = "能量估算未完成：\(error.localizedDescription)"
                    }
                }
            }

            DispatchQueue.main.async {
                self.tickInFlight = false
                self.snapshot = snapshot
                self.flow = flow
                self.metrics = metrics
                self.trust = trust
                self.battStatus = battStatus
                self.engine = state
                self.running = running
                self.rebuildCapabilities(
                    snapshot: battStatus,
                    metrics: metrics,
                    upper: upper,
                    lower: lower,
                    versionOk: versionOk,
                    timedDisable: timedDisable
                )
                if self.recordingClearGeneration == clearGeneration {
                    if consumeGap {
                        self.recordingController.consumeGapIfNeeded()
                    }
                    if let recordedAt {
                        self.lastSampleAt = recordedAt
                    } else if lastSample != nil {
                        self.lastSampleAt = lastSample
                    }
                    self.updateNextSampleEstimate()
                    if let sampleCount {
                        self.historySampleCount = sampleCount
                    }
                    if let byteCount {
                        self.historyByteCount = byteCount
                    }
                }
                if self.historyGeneration == generation {
                    if let chart {
                        self.chartResult = chart
                        self.lastDerivedAt = now
                    }
                    if !longRange, needDerived || recordedAt != nil {
                        self.energyEstimates = estimates
                        if let energyFailure { self.lastError = energyFailure }
                    }
                    if let newAdvice {
                        self.advice = newAdvice
                        self.lastAdviceForCooldown = newAdvice
                    }
                }
                if pruneDue {
                    self.lastPruneAt = now
                }
                if let deadline = self.adapterAutoEnableAt, deadline <= now {
                    self.applyVerifiedAdapterExpiry(status: battStatus)
                }
                if recoveryNeeded, !self.busy {
                    self.stop(reason: "检测到引擎失联，正在终止残余负载并恢复适配器")
                }
            }
        }
    }

    private func refreshReadOnlyProbes() {
        DispatchQueue.global(qos: .utility).async {
            let timed = BattService.probeTimedDisableSupported()
            let versionOk = BattService.probeVersionOK()
            DispatchQueue.main.async {
                self.timedDisableSupported = timed
                self.battVersionOk = versionOk
                self.rebuildCapabilities()
            }
        }
    }

    private func rereadBattStatus() {
        DispatchQueue.global(qos: .utility).async {
            let status = try? BattService.readStatusJSON()
            DispatchQueue.main.async {
                self.adapterExpiryVerifying = false
                self.battStatus = status
                self.rebuildCapabilities()
                if let deadline = self.adapterAutoEnableAt, deadline <= Date() {
                    self.applyVerifiedAdapterExpiry(status: status)
                }
            }
        }
    }

    private func rebuildCapabilities(
        snapshot: BattStatusSnapshot? = nil,
        metrics: PowerMetrics? = nil,
        upper: Int? = nil,
        lower: Int? = nil,
        versionOk: Bool? = nil,
        timedDisable: Bool? = nil
    ) {
        let status = snapshot ?? battStatus
        capabilities = CapabilityInventory.build(
            snapshot: status,
            battVersionOk: versionOk ?? battVersionOk,
            timedDisableSupported: timedDisable ?? timedDisableSupported,
            daemonReachable: status != nil,
            cycleUpperPercent: upper ?? config.upperLimit,
            cycleLowerPercent: lower ?? config.lowerLimit,
            iokitMaxChargePowerWatts: (metrics ?? self.metrics).chargePowerLimitWatts.value
        )
    }

    private func applyAdapterError(_ error: Error) {
        if let serviceError = error as? BattService.ServiceError, case .timedOut(let message) = serviceError {
            adapterCommandState = .timeout
            adapterCommandMessageZH = message
        } else {
            adapterCommandState = .failed
            adapterCommandMessageZH = error.localizedDescription
        }
        lastError = adapterCommandMessageZH
    }

    @discardableResult
    private func beginTransaction(_ next: ControlTransaction) -> Bool {
        guard controlTransaction.canBegin(next) else { return false }
        controlTransaction = next
        busy = true
        return true
    }

    private func endTransaction() {
        let queuedRestore = pendingRestore
        pendingRestore = false
        controlTransaction = .idle
        busy = false
        if queuedRestore {
            restorePower()
        }
    }

    private func finishSuspend(
        generation: UInt64,
        result: Result<String, Error>,
        status: BattStatusSnapshot?
    ) {
        guard ControlTransaction.shouldApplySuspendResult(
            capturedGeneration: generation,
            currentGeneration: controlGeneration
        ) else {
            if controlTransaction == .suspend {
                endTransaction()
            }
            return
        }
        if let status {
            battStatus = status
            rebuildCapabilities(snapshot: status)
        }
        switch result {
        case .success(let message):
            adapterCommandState = .success
            adapterCommandMessageZH = message
            lastMessage = message
            rereadBattStatus()
        case .failure(let error):
            applySuspendFailure(error, status: status)
        }
        endTransaction()
    }

    private func applySuspendFailure(_ error: Error, status: BattStatusSnapshot?) {
        let useAdapter = status?.useAdapter ?? battStatus?.useAdapter
        switch useAdapter {
        case .some(false):
            applyAdapterError(error)
        case .some(true):
            adapterAutoEnableAt = nil
            adapterExpiryWarned = false
            applyAdapterError(error)
        case .none:
            adapterCommandState = .unknown
            adapterCommandMessageZH = "适配器状态未知，请使用恢复适配器"
            lastError = adapterCommandMessageZH
        }
    }

    private func evaluateAdvice(
        samples: [HistorySample],
        settings: MonitorSettings,
        sampleCount: Int,
        ratedWatts: Double?,
        previous: [Advice],
        now: Date
    ) -> [Advice] {
        let adviceSamples = samples.map { sample in
            AdviceSample(
                epoch: sample.epoch,
                watts: sample.integrableWatts,
                percent: sample.percent.map(Double.init),
                direction: sample.direction,
                pluggedIn: sample.pluggedIn,
                useAdapter: sample.useAdapter,
                thermal: sample.thermal,
                enginePhase: sample.enginePhase,
                sleepGap: sample.sleepGap
            )
        }
        return adviceEngine.evaluate(
            context: AdviceContext(
                samples: adviceSamples,
                historyIntervalSeconds: TimeInterval(settings.historyIntervalSeconds),
                recordingPaused: settings.recordingPaused,
                sampleCount: sampleCount,
                retentionDays: settings.retentionDays,
                adapterRatedMaxWatts: ratedWatts
            ),
            previous: previous,
            now: now
        )
    }

    private func persistMonitorSettings() {
        do {
            try SupportPaths.ensurePrivateDirectories()
            try monitorSettings.save(to: SupportPaths.monitor)
            historyStore.settings = monitorSettings
        } catch {
            lastError = "监测设置未保存：\(error.localizedDescription)"
        }
    }

    private func applySamplingPolicy() {
        recordingController.policy = SamplingPolicy(
            historyInterval: TimeInterval(monitorSettings.historyIntervalSeconds),
            enginePollSeconds: config.pollSeconds
        )
        historyStore.settings = monitorSettings
    }

    private func syncSamplingPolicyIfNeeded() {
        let interval = TimeInterval(monitorSettings.historyIntervalSeconds)
        if recordingController.policy.historyInterval != interval
            || recordingController.policy.enginePollSeconds != config.pollSeconds {
            applySamplingPolicy()
        }
    }

    private func updateNextSampleEstimate() {
        if monitorSettings.recordingPaused || recordingController.state != .recording {
            nextHistorySampleAt = nil
            return
        }
        if let last = lastSampleAt {
            nextHistorySampleAt = recordingController.nextSampleAt(from: last)
        } else {
            nextHistorySampleAt = Date()
        }
    }

    private func shouldRefreshDerived(now: Date) -> Bool {
        guard let lastDerivedAt else { return true }
        let cadence = min(TimeInterval(monitorSettings.historyIntervalSeconds), 5)
        return now.timeIntervalSince(lastDerivedAt) >= cadence
    }

    /// 6 小时及以上视为长窗口：心跳不得流式重读整段保留期。
    private static func isLongHistoryRange(_ range: HistoryRange, now: Date) -> Bool {
        switch range {
        case .minutes15, .hours1:
            return false
        case .hours6, .hours24, .days7, .days30:
            return true
        case .custom(let from, let to):
            return abs(to.timeIntervalSince(from)) >= 6 * 3_600
        }
    }

    /// 只读适配器详情。不调用 batteryProvider，不把电池瓦数填进适配器字段。
    private static func readExternalAdapterDetailsOnce() -> [String: Any]? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              !details.isEmpty else {
            return nil
        }
        return details
    }

    /// IOPM `ExternalConnected`，与 IOPS AC Power 不是同一键。不二次 capture 电池。
    private static func readExternalConnectedOnce() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(
            service,
            "ExternalConnected" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    private func expireAdapterCountdown(now: Date) {
        guard let deadline = adapterAutoEnableAt else {
            if battStatus?.useAdapter == true, controlTransaction != .suspend, controlTransaction != .resume {
                BattService.clearManualSuspendMarker()
            }
            return
        }
        guard deadline <= now else { return }
        // 归零不得凭缓存清倒计时。本拍 workQueue 会带新鲜 status；仅在节拍重叠时另读。
        guard tickInFlight, !adapterExpiryVerifying else { return }
        adapterExpiryVerifying = true
        rereadBattStatus()
    }

    /// 仅在新鲜 `useAdapter == true` 时清除倒计时；false / 未知只警告并保留截止。
    private func applyVerifiedAdapterExpiry(status: BattStatusSnapshot?) {
        switch status?.useAdapter {
        case .some(true):
            adapterAutoEnableAt = nil
            adapterExpiryWarned = false
            BattService.clearManualSuspendMarker()
        case .some(false):
            if !adapterExpiryWarned {
                adapterExpiryWarned = true
                adapterCommandState = .unknown
                adapterCommandMessageZH = "时限已到但适配器仍关闭，请使用恢复适配器"
                lastError = adapterCommandMessageZH
            }
        case .none:
            if !adapterExpiryWarned {
                adapterExpiryWarned = true
                adapterCommandState = .unknown
                adapterCommandMessageZH = "时限已到但适配器状态未知，请使用恢复适配器"
                lastError = adapterCommandMessageZH
            }
        }
    }

    private func pruneHistoryInBackground(force: Bool) {
        let now = Date()
        if !force, let lastPruneAt, now.timeIntervalSince(lastPruneAt) < 3_600 {
            return
        }
        workQueue.async { [weak self] in
            try? self?.historyStore.prune(now: now)
            DispatchQueue.main.async {
                self?.lastPruneAt = now
            }
        }
    }

    private func refreshDerivedInBackground(force: Bool) {
        let now = Date()
        guard force || shouldRefreshDerived(now: now) else { return }
        let settings = monitorSettings
        let range = historyRange
        let generation = historyGeneration
        let clearGeneration = recordingClearGeneration
        let previousAdvice = lastAdviceForCooldown
        let rated = metrics.adapterRatedMaxWatts.value
        workQueue.async { [weak self] in
            guard let self else { return }
            let loaded = try? HistoryQuery.load(
                store: self.historyStore,
                range: range,
                now: now,
                intervalSeconds: settings.historyIntervalSeconds
            )
            let count = try? self.historyStore.sampleCount()
            let bytes = try? self.historyStore.estimatedBytes()
            let estimates: EnergyEstimates?
            var energyFailure: String?
            do {
                estimates = try EnergyEstimates.estimateHistory(
                    store: self.historyStore,
                    range: range,
                    now: now,
                    intervalSeconds: settings.historyIntervalSeconds
                )
            } catch {
                estimates = nil
                energyFailure = "能量估算未完成：\(error.localizedDescription)"
            }
            let adviceSource: [HistorySample]
            if range == SnapshotTick.adviceLookbackRange, let loaded {
                adviceSource = loaded.samples
            } else {
                let adviceLoaded = try? HistoryQuery.load(
                    store: self.historyStore,
                    range: SnapshotTick.adviceLookbackRange,
                    now: now,
                    intervalSeconds: settings.historyIntervalSeconds
                )
                adviceSource = adviceLoaded?.samples ?? []
            }
            // 范围切换同样写回最新 current，空列表会清掉已结束的建议。
            let emitted = self.evaluateAdvice(
                samples: adviceSource,
                settings: settings,
                sampleCount: count ?? adviceSource.count,
                ratedWatts: rated,
                previous: previousAdvice,
                now: now
            )
            DispatchQueue.main.async {
                if self.recordingClearGeneration == clearGeneration {
                    if let count { self.historySampleCount = count }
                    if let bytes { self.historyByteCount = bytes }
                }
                guard self.historyGeneration == generation else { return }
                if let energyFailure { self.lastError = energyFailure }
                if let loaded {
                    self.chartResult = loaded
                }
                self.energyEstimates = estimates
                self.advice = emitted
                self.lastAdviceForCooldown = emitted
                self.lastDerivedAt = now
            }
        }
    }

    private static func writeGuardianHeartbeat(thermalState: ProcessInfo.ThermalState) -> String? {
        do {
            try SupportPaths.ensurePrivateDirectories()
            let payload: [String: Any] = [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "updatedEpoch": Int(Date().timeIntervalSince1970),
                "thermalState": thermalStateName(thermalState),
                "executablePath": Bundle.main.executablePath ?? ""
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: SupportPaths.guardianHeartbeat, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: SupportPaths.guardianHeartbeat.path
            )
            return nil
        } catch {
            return "无法写入安全心跳：\(error.localizedDescription)"
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func thermalDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "热状态正常"
        case .fair: return "热状态升高，系统仍允许运行"
        case .serious: return "热状态严重，已请求安全停止"
        case .critical: return "热状态临界，已请求安全停止"
        @unknown default: return "无法识别热状态，禁止启动"
        }
    }

    private static func computeRunning(_ state: EngineState) -> Bool {
        let age = Int(Date().timeIntervalSince1970) - state.updatedEpoch
        if state.running,
           state.pid > 1,
           state.pid <= Int(Int32.max),
           age >= 0,
           age <= 75,
           pidFileAlive() == state.pid,
           kill(pid_t(state.pid), 0) == 0 || errno == EPERM {
            return true
        }
        return false
    }

    private static func pidFileAlive() -> Int? {
        guard let pid = recordedPID() else { return nil }
        if kill(pid_t(pid), 0) == 0 || errno == EPERM { return pid }
        return nil
    }

    private static func recordedPID() -> Int? {
        guard let raw = try? String(contentsOf: SupportPaths.pid, encoding: .utf8),
              let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              pid <= Int(Int32.max) else { return nil }
        return pid
    }

    private static func launchFailureHint() -> String {
        let urls = [
            SupportPaths.logs.appendingPathComponent("engine.out"),
            SupportPaths.logs.appendingPathComponent("launch.log"),
            SupportPaths.latestLog
        ]
        for url in urls {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let last = text.split(separator: "\n").suffix(4).joined(separator: " / ")
                if !last.isEmpty { return "日志：\(last)" }
            }
        }
        return "请打开日志查看原因。"
    }

    private static func loadConfig() -> CycleConfig {
        guard let data = try? Data(contentsOf: SupportPaths.config),
              var decoded = try? JSONDecoder().decode(CycleConfig.self, from: data) else {
            return .default
        }
        decoded.applyDefaultStopIfNeeded()
        return (try? decoded.validated()) ?? .default
    }

    private static func loadMonitorSettings() -> MonitorSettings {
        let url = SupportPaths.monitor
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .default
        }
        return (try? MonitorSettings.load(from: url)) ?? .default
    }

    private static func loadState() -> EngineState {
        guard let data = try? Data(contentsOf: SupportPaths.state),
              let decoded = try? JSONDecoder().decode(EngineState.self, from: data) else {
            return .idle
        }
        return decoded
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

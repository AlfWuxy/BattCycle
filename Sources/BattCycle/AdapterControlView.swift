import BattCycleCore
import SwiftUI

struct AdapterControlView: View {
    @EnvironmentObject private var engine: EngineController
    @State private var showingSuspendConfirmation = false

    var body: some View {
        DashboardForm {
            // P1.3 / P3.15：未知或切断已生效但验证失败时，页内醒目警告 + 恢复适配器。
            if adapterStateIsUnknown {
                DashboardSection {
                    unknownAdapterBanner
                }
            } else if disableFailedButEffected {
                DashboardSection {
                    effectedAdapterBanner
                }
            }

            DashboardSection("控制") {
                if adapterWritesAllowed {
                    adapterWriteControls
                } else {
                    // 写入已隐藏时仍要展示缺测，不能让人以为适配器是关的。
                    if engine.battStatus?.useAdapter == nil {
                        labeled(
                            "使用电源适配器",
                            value: AdapterControlPresentation.useAdapterStatusZH(
                                useAdapter: nil,
                                commandUnknown: adapterStateIsUnknown
                            ),
                            source: "batt"
                        )
                    }
                    Text(adapterWritesHiddenReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                adapterCountdown
                adapterCommandStatus
            }

            DashboardSection("只读信息") {
                MetricRow(metric: engine.metrics.adapterPhysicallyConnected, format: MetricDisplay.boolZH)
                MetricRow(metric: engine.metrics.systemUsingAdapter, format: MetricDisplay.boolZH)
                MetricRow(metric: engine.metrics.isCharging, format: MetricDisplay.boolZH)
                labeled("充电功率", value: chargeRateText, source: "batt")
                labeled("电压", value: voltageText, source: "batt")
                // configuration.upperLimitPercent 只读；禁止画成可写，也不得当成循环上限。
                labeled("batt 充电上限", value: battUpperLimitText, source: "batt")
                Text("batt configuration.upperLimitPercent 只读，BattCycle 不会写入 batt limit。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // P3.15：逐项展示电流、名称、厂商/型号、协议、协商与额定功率；缺失不编造。
            DashboardSection("适配器详情") {
                MetricRow(metric: engine.metrics.adapterCurrentMilliamps, format: { String(format: "%.0f", $0) })
                MetricRow(metric: engine.metrics.adapterName, format: { $0 })
                manufacturerModelRow
                protocolRow
                MetricRow(metric: engine.metrics.adapterNegotiatedWatts, format: MetricDisplay.wattsZH)
                // 额定瓦数只要 PowerMetrics 提供就展示，不因其他字段缺失而丢弃。
                MetricRow(metric: engine.metrics.adapterRatedMaxWatts, format: MetricDisplay.wattsZH)
            }

            // P3.16：最大充电功率只读或不支持；禁止启用滑块，禁止 SMC 写入。
            DashboardSection("最大充电功率") {
                maxChargePowerContent
            }

            DashboardSection("能力") {
                ForEach(listedCapabilities) { capability in
                    capabilityRow(capability)
                }
            }


        }
        .confirmationDialog(
            "确认暂时关闭电源适配器？",
            isPresented: $showingSuspendConfirmation,
            titleVisibility: .visible
        ) {
            Button("关闭 \(clampedSuspendSeconds) 秒", role: .destructive) {
                // 只经现有 EngineController API；底层 BattService 会再夹紧 1...600 并带 --for。
                engine.adapterSuspendSeconds = clampedSuspendSeconds
                engine.suspendAdapterConfirmed()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将限时关闭电源适配器 \(clampedSuspendSeconds) 秒（batt --for）。时限结束后 batt 会自动恢复。不会停止循环引擎以外的监测。请确认已保存工作。")
        }
    }

    /// 能力列表去掉最大充电功率，该能力由专用区块只读展示。
    private var listedCapabilities: [Capability] {
        engine.capabilities.capabilities.filter { $0.id != CapabilityID.maxChargePowerWatts }
    }

    /// 枚举 `.unknown` 或其标题「未知」/ unknown。失败且 `useAdapter == nil` 不在此推断，以免误报。
    private var adapterStateIsUnknown: Bool {
        AdapterControlPresentation.isUnknown(state: engine.adapterCommandState)
    }

    private var unknownAdapterBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("适配器状态未知，请立即恢复")
                        .font(.headline)
                    Text(engine.adapterCommandMessageZH)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            Button("恢复适配器") {
                engine.restorePower()
            }
            // Restore 优先于 busy：suspend 进行中仍可排队 pendingRestore。
            .disabled(!engine.canRequestRestore)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("请求停止循环，再让 batt 恢复并验证电源适配器")
        }
        .foregroundStyle(.red)
        .padding(8)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("适配器状态未知，请立即恢复")
    }

    /// 切断已生效（EFFECTED）但后续验证失败/超时：不得只显示普通「失败」。
    private var disableFailedButEffected: Bool {
        AdapterControlPresentation.disableFailedButEffected(
            state: engine.adapterCommandState,
            useAdapter: engine.battStatus?.useAdapter,
            cycleOccupyingAdapter: engine.adapterManualControlBlockedReason != nil,
            messages: [
                engine.adapterCommandMessageZH,
                engine.lastMessage,
                engine.lastError
            ]
        )
    }

    private var effectedAdapterBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("适配器切断已生效，请立即恢复")
                        .font(.headline)
                    Text(effectedCommandDetail)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            Button("恢复适配器") {
                engine.restorePower()
            }
            .disabled(!engine.canRequestRestore)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help("切断已生效（EFFECTED）。请求 batt 恢复并验证电源适配器")
        }
        .foregroundStyle(.orange)
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("适配器切断已生效，请立即恢复")
    }

    /// 失败文案保留原错误，并标明 EFFECTED，避免只剩「失败」。
    private var effectedCommandDetail: String {
        let raw = engine.adapterCommandMessageZH.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.localizedCaseInsensitiveContains("EFFECTED") {
            return raw
        }
        if raw.isEmpty {
            return "切断已生效（EFFECTED）。验证失败或超时，适配器当前为关闭。"
        }
        return "切断已生效（EFFECTED）。\(raw)"
    }

    /// 版本 + daemon + 非 root + adapterControl：与 CapabilityInventory.adapterEnable 可写门槛一致。
    private var adapterWritesAllowed: Bool {
        engine.capabilities.capability(id: CapabilityID.adapterEnable)?.writable == true
    }

    private var adapterWritesHiddenReason: String {
        engine.capabilities.capability(id: CapabilityID.adapterEnable)?.unavailableReasonZH
            ?? engine.capabilities.capability(id: CapabilityID.adapterDisable)?.unavailableReasonZH
            ?? "当前不可写入适配器（需要版本、daemon、非 root 与 adapterControl）"
    }

    @ViewBuilder
    private var adapterWriteControls: some View {
        // useAdapter 缺测不得画成关闭；只在已读到 Bool 时才用开关。
        if let useAdapter = engine.battStatus?.useAdapter {
            Toggle(isOn: adapterToggleBinding(measured: useAdapter)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("使用电源适配器")
                    if let reason = adapterDisabledReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .disabled(adapterDisabledReason != nil || engine.adapterCommandState == .running)

            HStack {
                Text("切断时长")
                Spacer()
                Stepper(value: $engine.adapterSuspendSeconds, in: 1...600) {
                    Text("\(clampedSuspendSeconds) 秒")
                        .monospacedDigit()
                }
                .disabled(!timedDisableWritable || adapterDisabledReason != nil)
            }

            HStack {
                ForEach([60, 300, 600], id: \.self) { seconds in
                    Button("\(seconds)s") { engine.adapterSuspendSeconds = seconds }
                        .disabled(!timedDisableWritable || adapterDisabledReason != nil)
                }
            }

            Text("限时关闭由 batt 设定自动恢复（1–600 秒），执行前需要确认，实际状态以验证结果为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            adapterUseUnavailableRow
        }
    }

    /// `useAdapter == nil`：显示不可用/未知，并给出 Restore；不把缺测画成关闭。
    private var adapterUseUnavailableRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            labeled("使用电源适配器", value: AdapterControlPresentation.useAdapterStatusZH(
                useAdapter: nil,
                commandUnknown: adapterStateIsUnknown
            ), source: "batt")
            Text(adapterStateIsUnknown ? "适配器状态未知，请立即恢复" : "当前未读到 charging.useAdapter，不能当成已关闭。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("恢复适配器") {
                engine.restorePower()
            }
            .disabled(!engine.canRequestRestore)
        }
    }

    /// 限时切断能力：四项门槛之外还要帮助文本含 `--for`。
    private var timedDisableWritable: Bool {
        engine.capabilities.capability(id: CapabilityID.adapterDisable)?.controlState == .writable
    }

    private var clampedSuspendSeconds: Int {
        min(600, max(1, engine.adapterSuspendSeconds))
    }

    @ViewBuilder
    private var adapterCommandStatus: some View {
        LabeledContent("适配器命令") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(adapterCommandTitleZH)
                Text(adapterCommandDetailZH)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        if disableFailedButEffected || adapterStateIsUnknown || engine.battStatus?.useAdapter == nil {
            Button("恢复适配器") {
                engine.restorePower()
            }
            .disabled(!engine.canRequestRestore)
        }
    }

    private var adapterCommandTitleZH: String {
        if disableFailedButEffected {
            return "切断已生效"
        }
        return engine.adapterCommandState.statusTitleZH
    }

    private var adapterCommandDetailZH: String {
        if disableFailedButEffected {
            return effectedCommandDetail
        }
        return engine.adapterCommandMessageZH
    }

    /// 只要设置了自动恢复截止时间就显示；失败或未知不隐藏。
    @ViewBuilder
    private var adapterCountdown: some View {
        if let deadline = engine.adapterAutoEnableAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remain = max(0, Int(deadline.timeIntervalSince(context.date).rounded()))
                Text(remain > 0 ? "约 \(remain) 秒后自动恢复适配器" : "自动恢复时限已到，仍待确认适配器已恢复")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 仅在已测到 `useAdapter` 时使用。缺测不走此 Binding，避免 `?? false` 把未知画成关闭。
    private func adapterToggleBinding(measured: Bool) -> Binding<Bool> {
        Binding(
            get: { engine.battStatus?.useAdapter ?? measured },
            set: { newValue in
                guard engine.battStatus?.useAdapter != nil else { return }
                if newValue {
                    engine.resumeAdapterNow()
                } else {
                    showingSuspendConfirmation = true
                }
            }
        )
    }

    /// P1.4：循环占用、未插入、或对应能力不可写时禁用开关。
    private var adapterDisabledReason: String? {
        if let blocked = engine.adapterManualControlBlockedReason {
            return blocked
        }
        if adapterStateIsUnknown {
            return "适配器状态未知，请立即恢复"
        }
        if adapterIsUnplugged {
            return "适配器未连接"
        }
        if engine.battStatus?.useAdapter == nil {
            return "当前不可用"
        }
        if engine.battStatus?.useAdapter == true {
            let capability = engine.capabilities.capability(id: CapabilityID.adapterDisable)
            if capability?.controlState != .writable {
                return capability?.unavailableReasonZH ?? "当前不可用"
            }
        } else {
            let capability = engine.capabilities.capability(id: CapabilityID.adapterEnable)
            if capability?.controlState != .writable {
                return capability?.unavailableReasonZH ?? "当前不可用"
            }
        }
        return nil
    }

    /// 仅在明确读到未插入时禁用；缺字段不得当成未插入。
    private var adapterIsUnplugged: Bool {
        if engine.metrics.adapterPhysicallyConnected.availability == .available,
           engine.metrics.adapterPhysicallyConnected.value == false {
            return true
        }
        if engine.battStatus?.pluggedIn == false {
            return true
        }
        return false
    }

    private var chargeRateText: String {
        guard let watts = engine.battStatus?.chargeRateWatts else {
            return "当前不可用"
        }
        return String(format: "%+.1f W", watts)
    }

    private var voltageText: String {
        guard let volts = engine.battStatus?.voltageVolts else {
            return "当前不可用"
        }
        return String(format: "%.3f V", volts)
    }

    private var battUpperLimitText: String {
        guard let percent = engine.battStatus?.upperLimitPercent else {
            return "当前不可用"
        }
        return "\(percent)%"
    }

    @ViewBuilder
    private var manufacturerModelRow: some View {
        let manufacturer = engine.metrics.adapterManufacturer
        let model = engine.metrics.adapterModel
        let parts = [stringIfAvailable(manufacturer), stringIfAvailable(model)].compactMap { $0 }
        if !parts.isEmpty {
            labeled("厂商/型号", value: parts.joined(separator: " / "), source: "IOKit")
        } else {
            labeled("厂商/型号", value: missingPlaceholder(manufacturer.availability, model.availability))
        }
    }

    @ViewBuilder
    private var protocolRow: some View {
        let protocolMetric = engine.metrics.adapterProtocol
        let port = engine.metrics.adapterPortType
        let family = engine.metrics.adapterFamily
        if stringIfAvailable(protocolMetric) != nil {
            MetricRow(metric: protocolMetric, format: { $0 })
        } else if stringIfAvailable(port) != nil {
            MetricRow(metric: port, format: { $0 })
        } else if stringIfAvailable(family) != nil {
            MetricRow(metric: family, format: { $0 })
        } else {
            MetricRow(metric: protocolMetric, format: { $0 })
        }
    }

    @ViewBuilder
    private var maxChargePowerContent: some View {
        let capability = engine.capabilities.capability(id: CapabilityID.maxChargePowerWatts)
        switch capability?.controlState ?? .unsupported {
        case .readable:
            maxChargePowerReadOnly(capability)
        case .writable:
            // CapabilityInventory 禁止可写；即使误标可写也只读展示，不上滑块、不写 SMC。
            maxChargePowerReadOnly(capability)
            Text("当前接口未开放写入，已改为只读")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsupported:
            Text("当前硬件或接口未提供此能力")
                .foregroundStyle(.secondary)
            if let reason = capability?.unavailableReasonZH {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func maxChargePowerReadOnly(_ capability: Capability?) -> some View {
        let valueText = maxChargePowerValueText(capability)
        labeled("最大充电功率", value: valueText, source: capability.map { MetricDisplay.sourceZH($0.source) })
        HStack {
            Text("只读")
            if let note = capability?.noteZH, !note.isEmpty {
                Text(note)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// 只接受能力清单或 batt JSON 的明确最大充电功率键；不把充电功率、额定瓦数或 SMC 猜测填进来。
    private func maxChargePowerValueText(_ capability: Capability?) -> String {
        if let capability, capability.currentValue != .none {
            let text = MetricDisplay.capabilityValueZH(capability.currentValue)
            if capability.unit.isEmpty {
                return text
            }
            return "\(text) \(capability.unit)"
        }
        if let watts = engine.battStatus?.maxChargePowerWatts {
            return String(format: "%.1f W", watts)
        }
        return "当前不可用"
    }

    private func stringIfAvailable(_ metric: MetricValue<String>) -> String? {
        guard metric.availability == .available, let value = metric.value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func missingPlaceholder(_ first: MetricAvailability, _ second: MetricAvailability) -> String {
        if first == .currentlyUnavailable || second == .currentlyUnavailable {
            return "当前不可用"
        }
        let text = MetricDisplay.placeholder(first)
        return text.isEmpty ? "设备未提供" : text
    }

    private func labeled(_ name: String, value: String, source: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                if let source {
                    Text("来源 \(source)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(value.contains("不可用") || value.contains("未提供") ? Color.secondary : Color.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, value, source.map { "来源 \($0)" }].compactMap { $0 }.joined(separator: "，"))
    }

    private func capabilityRow(_ capability: Capability) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(capability.nameZH)
                Spacer()
                Text(MetricDisplay.capabilityValueZH(capability.currentValue))
                    .font(.body.monospacedDigit())
                if !capability.unit.isEmpty {
                    Text(capability.unit)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(controlStateZH(displayedControlState(capability)))
                Text("来源 \(MetricDisplay.sourceZH(capability.source))")
                if capabilityShowsWritable(capability) {
                    Text("可写")
                } else {
                    Text("只读")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let reason = capability.unavailableReasonZH {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let note = capability.noteZH {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func controlStateZH(_ state: ControlState) -> String {
        switch state {
        case .writable: return "可操作"
        case .readable: return "只读"
        case .unsupported: return "不支持"
        }
    }

    /// batt 上限与最大充电功率永不标可写；适配器写入还要过四项门槛。
    private func capabilityShowsWritable(_ capability: Capability) -> Bool {
        if capability.id == CapabilityID.chargePercentLimitBatt
            || capability.id == CapabilityID.maxChargePowerWatts {
            return false
        }
        if capability.id == CapabilityID.adapterDisable
            || capability.id == CapabilityID.adapterEnable {
            return adapterWritesAllowed && capability.writable
        }
        return capability.writable
    }

    private func displayedControlState(_ capability: Capability) -> ControlState {
        if capabilityShowsWritable(capability) {
            return .writable
        }
        if capability.readable {
            return .readable
        }
        return .unsupported
    }
}

/// 适配器页展示规则。不发硬件命令；只根据已有 EngineController 状态决定文案。
enum AdapterControlPresentation {
    /// 失败/超时且切断已生效：文案含 EFFECTED，或 useAdapter 已为 false。
    static func disableFailedButEffected(
        state: AdapterCommandState,
        useAdapter: Bool?,
        cycleOccupyingAdapter: Bool,
        messages: [String?]
    ) -> Bool {
        switch state {
        case .failed, .timeout:
            if messages.contains(where: { textMentionsEffected($0) }) {
                return true
            }
            // 循环放电阶段 useAdapter 也会是 false，不得当成独立切断 EFFECTED。
            if cycleOccupyingAdapter {
                return false
            }
            return useAdapter == false
        default:
            return false
        }
    }

    static func textMentionsEffected(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains("EFFECTED")
    }

    /// `.unknown` 或中英「未知」标题。不把普通失败推断成未知。
    static func isUnknown(state: AdapterCommandState) -> Bool {
        if state == .unknown {
            return true
        }
        let title = state.statusTitleZH.trimmingCharacters(in: .whitespacesAndNewlines)
        return title == "未知" || title.caseInsensitiveCompare("unknown") == .orderedSame
    }

    /// `useAdapter == nil` 显示不可用或未知，绝不返回「否」/关闭。
    static func useAdapterStatusZH(useAdapter: Bool?, commandUnknown: Bool) -> String {
        if commandUnknown || useAdapter == nil {
            return commandUnknown ? "未知" : "当前不可用"
        }
        return useAdapter == true ? "是" : "否"
    }
}

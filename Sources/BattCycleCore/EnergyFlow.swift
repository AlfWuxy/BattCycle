import Foundation

/// 能量流向。独立于引擎充放电阶段，只根据当前功率（及可选的充电标志覆盖）判断。
public enum PowerDirection: Equatable, Sendable {
    case charging
    case discharging
    case idle
    case unknown
}

public struct EnergyFlow: Equatable, Sendable {
    public var direction: PowerDirection
    public var labelZH: String
    public var symbolName: String
    public var accessibilityLabel: String

    /// 绝对值达到此阈值（瓦）即判定充电或放电；低于此值且无涓流覆盖时视为待机。
    public static let idlePowerThresholdWatts: Double = 1.0

    public init(
        direction: PowerDirection,
        labelZH: String,
        symbolName: String,
        accessibilityLabel: String
    ) {
        self.direction = direction
        self.labelZH = labelZH
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
    }

    /// 快照入口：缺 `IsCharging` / `Power Source State` 时走映射缺省，不当成测到的 false。
    public static func classify(_ snapshot: BatterySnapshot) -> EnergyFlow {
        snapshot.classifiedEnergyFlow()
    }

    /// 分类规则（按优先级）。`isCharging: Bool` 保持不变；调用方应传入 `mappedIsCharging`（缺键为 false）。
    /// 传入的 false 只表示「没有涓流覆盖」，不是测到的「未在充电」。流向仍由瓦数决定。
    /// 1. 快照不可用或缺少瓦数键 → unknown（捕获失败的兼容 0 不是待机，也不是 0W 充电）
    /// 2. `isCharging == true` 且瓦数 ≤ −阈值 → unknown（标志与瓦数冲突；映射缺省的 false 不会走这条）
    /// 3. 瓦数 ≤ −阈值 → discharging（电池供给系统负载，不是回馈墙上插头）
    /// 4. 瓦数 ≥ +阈值 → charging；近零时仅当 `isCharging == true` 才覆盖为涓流充电
    /// 5. 可用瓦数且 |W| < 阈值 → idle
    public static func classify(
        isAvailable: Bool,
        wattsIsAvailable: Bool,
        watts: Double,
        isCharging: Bool,
        drawingFrom: String,
        externalConnected: Bool
    ) -> EnergyFlow {
        let direction = direction(
            isAvailable: isAvailable,
            wattsIsAvailable: wattsIsAvailable,
            watts: watts,
            isCharging: isCharging
        )
        return make(direction: direction, drawingFrom: drawingFrom, externalConnected: externalConnected)
    }

    /// 瓦数优先。`isCharging` 只用于冲突检测与近零涓流覆盖。
    private static func direction(
        isAvailable: Bool,
        wattsIsAvailable: Bool,
        watts: Double,
        isCharging: Bool
    ) -> PowerDirection {
        if !isAvailable || !wattsIsAvailable {
            return .unknown
        }
        if isCharging && watts <= -idlePowerThresholdWatts {
            return .unknown
        }
        if watts <= -idlePowerThresholdWatts {
            return .discharging
        }
        if watts >= idlePowerThresholdWatts || isCharging {
            return .charging
        }
        return .idle
    }

    private static func make(
        direction: PowerDirection,
        drawingFrom: String,
        externalConnected: Bool
    ) -> EnergyFlow {
        let sourceNote = sourceDescriptionNote(drawingFrom)
        // 仅在明确为真时提及适配器；映射缺省的 false 不写成「未使用适配器」。
        let plugNote = externalConnected ? "，系统正在使用适配器" : ""
        switch direction {
        case .charging:
            return EnergyFlow(
                direction: .charging,
                labelZH: "充电",
                symbolName: "bolt.fill",
                accessibilityLabel: "电池正在充电，电能从适配器流向电池\(sourceNote)\(plugNote)"
            )
        case .discharging:
            // 放电只描述电池 → 系统负载；不提及插头或适配器，避免读成回馈电网。
            return EnergyFlow(
                direction: .discharging,
                labelZH: "放电",
                symbolName: "battery.25",
                accessibilityLabel: "电池正在向系统负载放电\(sourceNote)。电能供给本机，不是反向送回电源。"
            )
        case .idle:
            return EnergyFlow(
                direction: .idle,
                labelZH: "待机",
                symbolName: "pause.circle",
                accessibilityLabel: "电池功率接近零，处于待机\(sourceNote)\(plugNote)"
            )
        case .unknown:
            return EnergyFlow(
                direction: .unknown,
                labelZH: "未知",
                symbolName: "questionmark.circle",
                accessibilityLabel: "电池功率数据不可用或相互矛盾\(sourceNote)\(plugNote)"
            )
        }
    }

    /// `unknown` 是缺键占位，不是电源描述。
    private static func sourceDescriptionNote(_ drawingFrom: String) -> String {
        if drawingFrom.isEmpty || drawingFrom == "unknown" {
            return ""
        }
        return "，电源描述为\(drawingFrom)"
    }
}

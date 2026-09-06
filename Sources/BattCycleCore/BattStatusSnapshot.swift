import Foundation

/// `batt status --json` 的只读快照。缺失键为 nil（不可用），绝不以 0 / false 填充。
/// `configuration.upperLimitPercent` 只读观察，BattCycle 禁止据此写入 batt limit。
/// 额外未知键由 JSONDecoder 忽略，不得导致崩溃。本类型不执行 batt。
public struct BattStatusSnapshot: Equatable, Sendable, Decodable {
    /// 缺失为 nil，JSON `false` 才表示明确未接入。
    public let pluggedIn: Bool?
    public let useAdapter: Bool?
    public let allowCharging: Bool?
    public let allowNonRootAccess: Bool?
    public let adapterControl: Bool?

    public let currentChargePercent: Int?
    public let batteryState: String?
    public let chargeRateWatts: Double?

    /// batt 充电百分比上限，只读。缺失为 nil，不是 0。
    public let upperLimitPercent: Int?

    // 下列字段在官方 JSON 中可能出现；缺失保持 nil。
    public let timeToLimitMinutes: Int?
    public let fullCapacityMah: Int?
    public let voltageVolts: Double?
    public let lowerLimitPercent: Int?
    public let configurationEnabled: Bool?
    public let preventIdleSleep: Bool?
    public let disableChargingPreSleep: Bool?
    public let preventSystemSleep: Bool?

    /// 仅当 JSON 出现明确的最大充电功率键时才有值。batt CLI 无瓦数 setter。
    public let maxChargePowerWatts: Double?

    public init(
        pluggedIn: Bool? = nil,
        useAdapter: Bool? = nil,
        allowCharging: Bool? = nil,
        allowNonRootAccess: Bool? = nil,
        adapterControl: Bool? = nil,
        currentChargePercent: Int? = nil,
        batteryState: String? = nil,
        chargeRateWatts: Double? = nil,
        upperLimitPercent: Int? = nil,
        timeToLimitMinutes: Int? = nil,
        fullCapacityMah: Int? = nil,
        voltageVolts: Double? = nil,
        lowerLimitPercent: Int? = nil,
        configurationEnabled: Bool? = nil,
        preventIdleSleep: Bool? = nil,
        disableChargingPreSleep: Bool? = nil,
        preventSystemSleep: Bool? = nil,
        maxChargePowerWatts: Double? = nil
    ) {
        self.pluggedIn = pluggedIn
        self.useAdapter = useAdapter
        self.allowCharging = allowCharging
        self.allowNonRootAccess = allowNonRootAccess
        self.adapterControl = adapterControl
        self.currentChargePercent = currentChargePercent
        self.batteryState = batteryState
        self.chargeRateWatts = chargeRateWatts
        self.upperLimitPercent = upperLimitPercent
        self.timeToLimitMinutes = timeToLimitMinutes
        self.fullCapacityMah = fullCapacityMah
        self.voltageVolts = voltageVolts
        self.lowerLimitPercent = lowerLimitPercent
        self.configurationEnabled = configurationEnabled
        self.preventIdleSleep = preventIdleSleep
        self.disableChargingPreSleep = disableChargingPreSleep
        self.preventSystemSleep = preventSystemSleep
        self.maxChargePowerWatts = maxChargePowerWatts
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        let charging = try root.nestedContainerIfPresent(ChargingKey.self, forKey: .charging)
        let battery = try root.nestedContainerIfPresent(BatteryKey.self, forKey: .battery)
        let configuration = try root.nestedContainerIfPresent(ConfigurationKey.self, forKey: .configuration)
        let compatibility = try root.nestedContainerIfPresent(CompatibilityKey.self, forKey: .compatibility)

        pluggedIn = try charging?.decodeIfPresent(Bool.self, forKey: .pluggedIn)
        useAdapter = try charging?.decodeIfPresent(Bool.self, forKey: .useAdapter)
        allowCharging = try charging?.decodeIfPresent(Bool.self, forKey: .allowCharging)

        currentChargePercent = try battery?.decodeIfPresent(Int.self, forKey: .currentChargePercent)
        batteryState = try battery?.decodeIfPresent(String.self, forKey: .state)
        chargeRateWatts = try battery?.decodeIfPresent(Double.self, forKey: .chargeRateWatts)
        timeToLimitMinutes = try battery?.decodeIfPresent(Int.self, forKey: .timeToLimitMinutes)
        fullCapacityMah = try battery?.decodeIfPresent(Int.self, forKey: .fullCapacityMah)
        voltageVolts = try battery?.decodeIfPresent(Double.self, forKey: .voltageVolts)

        allowNonRootAccess = try configuration?.decodeIfPresent(Bool.self, forKey: .allowNonRootAccess)
        // 只读取，不提供 setter；缺键保持 nil。
        upperLimitPercent = try configuration?.decodeIfPresent(Int.self, forKey: .upperLimitPercent)
        lowerLimitPercent = try configuration?.decodeIfPresent(Int.self, forKey: .lowerLimitPercent)
        configurationEnabled = try configuration?.decodeIfPresent(Bool.self, forKey: .enabled)
        preventIdleSleep = try configuration?.decodeIfPresent(Bool.self, forKey: .preventIdleSleep)
        disableChargingPreSleep = try configuration?.decodeIfPresent(Bool.self, forKey: .disableChargingPreSleep)
        preventSystemSleep = try configuration?.decodeIfPresent(Bool.self, forKey: .preventSystemSleep)

        adapterControl = try compatibility?.decodeIfPresent(Bool.self, forKey: .adapterControl)

        // 未知键忽略。最大充电功率只接受明确键名，不把 chargeRateWatts 或适配器额定功率当成上限。
        let batteryMax = try battery?.decodeIfPresent(Double.self, forKey: .maxChargePowerWatts)
        let batteryMaxAlias = try battery?.decodeIfPresent(Double.self, forKey: .maxChargeRateWatts)
        let compatibilityMax = try compatibility?.decodeIfPresent(Double.self, forKey: .maxChargePowerWatts)
        maxChargePowerWatts = batteryMax ?? batteryMaxAlias ?? compatibilityMax
    }

    /// 解析 `batt status --json` 文本。本函数不执行 batt，也不写入任何控制。
    public static func parse(_ json: String) throws -> BattStatusSnapshot {
        try parse(Data(json.utf8))
    }

    public static func parse(_ data: Data) throws -> BattStatusSnapshot {
        try JSONDecoder().decode(BattStatusSnapshot.self, from: data)
    }

    private enum RootKey: String, CodingKey {
        case charging
        case battery
        case configuration
        case compatibility
        // calibration 等未知顶层键故意不声明，由解码器忽略。
    }

    private enum ChargingKey: String, CodingKey {
        case pluggedIn
        case useAdapter
        case allowCharging
    }

    private enum BatteryKey: String, CodingKey {
        case currentChargePercent
        case state
        case chargeRateWatts
        case timeToLimitMinutes
        case fullCapacityMah
        case voltageVolts
        case maxChargePowerWatts
        case maxChargeRateWatts
    }

    private enum ConfigurationKey: String, CodingKey {
        case allowNonRootAccess
        case upperLimitPercent
        case lowerLimitPercent
        case enabled
        case preventIdleSleep
        case disableChargingPreSleep
        case preventSystemSleep
    }

    private enum CompatibilityKey: String, CodingKey {
        case adapterControl
        case maxChargePowerWatts
    }
}

private extension KeyedDecodingContainer {
    func nestedContainerIfPresent<NestedKey: CodingKey>(
        _ type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey>? {
        guard contains(key), !(try decodeNil(forKey: key)) else {
            return nil
        }
        return try nestedContainer(keyedBy: type, forKey: key)
    }
}

import Foundation
import IOKit
import IOKit.ps

/// 单项读数的可用性。捕获失败不得被当成 0% / 0W 的真实测量。
public enum MetricAvailability: Equatable, Sendable {
    /// 设备提供了该键，且本次读到了值。
    case available
    /// 当前平台或本次查询未发布该键，不能凭空填数。
    case deviceDidNotProvide
    /// 本应可读，但这次捕获失败（例如 IOPS 列表为空）。
    case currentlyUnavailable
    /// 该指标不从 IOKit 读取（例如 batt 充电上限）。
    case unsupported
}

/// 与旧的非可选 `percent` / `watts` 并行的可选读数，避免把缺失当成 0。
public struct MeasurementReading<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value?
    public var isAvailable: Bool
    public var availability: MetricAvailability
    public var capturedAt: Date
    public var unavailableReason: String?

    public init(
        value: Value?,
        isAvailable: Bool,
        availability: MetricAvailability,
        capturedAt: Date,
        unavailableReason: String? = nil
    ) {
        self.value = value
        self.isAvailable = isAvailable
        self.availability = availability
        self.capturedAt = capturedAt
        self.unavailableReason = unavailableReason
    }

    public static func unavailable(
        availability: MetricAvailability,
        capturedAt: Date,
        reason: String?
    ) -> MeasurementReading {
        MeasurementReading(
            value: nil,
            isAvailable: false,
            availability: availability,
            capturedAt: capturedAt,
            unavailableReason: reason
        )
    }
}

public struct BatterySnapshot: Equatable, Sendable {
    /// 兼容字段：捕获失败时仍为 0，但 `percentIsAvailable` 为 false。
    public var percent: Int
    public var drawingFrom: String
    public var isCharging: Bool
    /// IOPS `Power Source State == AC Power`，表示系统正在用适配器，不是物理插口检测。
    public var externalConnected: Bool
    /// 兼容字段：捕获失败或缺键时仍为 0，但 `wattsIsAvailable` 为 false，不得当作真实 0W。
    public var watts: Double
    public var summary: String
    public var capturedAt: Date

    /// 是否捕获到内部电池电源；empty / IOPS 失败为 false。
    public var isAvailable: Bool
    public var availability: MetricAvailability
    public var percentIsAvailable: Bool
    public var wattsIsAvailable: Bool
    /// 功率键齐全且绝对值小于 `wattsTrueZeroEpsilon`。捕获失败的 0 不算。
    public var wattsIsTrueZero: Bool
    public var percentReading: MeasurementReading<Int>
    public var wattsReading: MeasurementReading<Double>
    /// 兼容字段 `isCharging` 在缺键时仍为 false，但本标志为 false 时不得当成「未在充电」。
    public var isChargingIsAvailable: Bool
    /// IOPS `Power Source State` 是否读到。缺键时 `externalConnected` 仍为 false，但不得当成「未用适配器」。
    public var externalConnectedIsAvailable: Bool
    /// 与 `externalConnectedIsAvailable` 同源；缺键时 `drawingFrom` 为 `"unknown"`，不得写成「电池供电」。
    public var drawingFromIsAvailable: Bool

    /// 判定「真实 0W」的绝对值阈值（瓦）。捕获失败的兼容 0 不走此判断。
    public static let wattsTrueZeroEpsilon: Double = 1e-6

    public init(
        percent: Int,
        drawingFrom: String,
        isCharging: Bool,
        externalConnected: Bool,
        watts: Double,
        summary: String,
        capturedAt: Date,
        isAvailable: Bool = true,
        availability: MetricAvailability = .available,
        percentIsAvailable: Bool? = nil,
        wattsIsAvailable: Bool? = nil,
        wattsIsTrueZero: Bool? = nil,
        percentReading: MeasurementReading<Int>? = nil,
        wattsReading: MeasurementReading<Double>? = nil,
        isChargingIsAvailable: Bool? = nil,
        externalConnectedIsAvailable: Bool? = nil,
        drawingFromIsAvailable: Bool? = nil
    ) {
        let resolvedPercentAvailable = percentIsAvailable ?? isAvailable
        let resolvedWattsAvailable = wattsIsAvailable ?? isAvailable
        let resolvedChargingAvailable = isChargingIsAvailable ?? isAvailable
        let resolvedExternalAvailable = externalConnectedIsAvailable ?? isAvailable
        let resolvedDrawingAvailable = drawingFromIsAvailable ?? resolvedExternalAvailable
        self.percent = percent
        self.drawingFrom = drawingFrom
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.watts = watts
        self.summary = summary
        self.capturedAt = capturedAt
        self.isAvailable = isAvailable
        self.availability = availability
        self.percentIsAvailable = resolvedPercentAvailable
        self.wattsIsAvailable = resolvedWattsAvailable
        self.wattsIsTrueZero = wattsIsTrueZero
            ?? (resolvedWattsAvailable && abs(watts) < Self.wattsTrueZeroEpsilon)
        self.percentReading = percentReading ?? MeasurementReading(
            value: resolvedPercentAvailable ? percent : nil,
            isAvailable: resolvedPercentAvailable,
            availability: resolvedPercentAvailable ? .available : (isAvailable ? .deviceDidNotProvide : .currentlyUnavailable),
            capturedAt: capturedAt,
            unavailableReason: resolvedPercentAvailable ? nil : "电量百分比不可用"
        )
        self.wattsReading = wattsReading ?? MeasurementReading(
            value: resolvedWattsAvailable ? watts : nil,
            isAvailable: resolvedWattsAvailable,
            availability: resolvedWattsAvailable ? .available : (isAvailable ? .deviceDidNotProvide : .currentlyUnavailable),
            capturedAt: capturedAt,
            unavailableReason: resolvedWattsAvailable ? nil : "电池侧功率不可用"
        )
        self.isChargingIsAvailable = resolvedChargingAvailable
        self.externalConnectedIsAvailable = resolvedExternalAvailable
        self.drawingFromIsAvailable = resolvedDrawingAvailable
    }

    /// 缺 `IsCharging` 或 `Power Source State` 时不得把快照标成 `.trusted`。
    public var isCompleteForDataTrust: Bool {
        isAvailable && isChargingIsAvailable && externalConnectedIsAvailable && drawingFromIsAvailable
    }

    /// `IsCharging` 可用性。电池在位但未发布该键 → `deviceDidNotProvide`，不是测到的 false。
    public var isChargingAvailability: MetricAvailability {
        if isChargingIsAvailable { return .available }
        return isAvailable ? .deviceDidNotProvide : .currentlyUnavailable
    }

    /// AC 状态可用性。缺 `Power Source State` → 不是「未使用适配器」。
    public var externalConnectedAvailability: MetricAvailability {
        if externalConnectedIsAvailable { return .available }
        return isAvailable ? .deviceDidNotProvide : .currentlyUnavailable
    }

    /// 缺充电键时映射为 false，供 `EnergyFlow.classify(Bool)` 使用；不把缺键当成正在充电。
    public var mappedIsCharging: Bool {
        isChargingIsAvailable && isCharging
    }

    /// 缺电源状态键时映射为 false；不把缺键当成系统未使用适配器。
    public var mappedExternalConnected: Bool {
        externalConnectedIsAvailable && externalConnected
    }

    /// 在不修改 `EnergyFlow.classify(Bool)` 的前提下，用映射默认值分类。瓦数规则不变。
    public func classifiedEnergyFlow() -> EnergyFlow {
        EnergyFlow.classify(
            isAvailable: isAvailable,
            wattsIsAvailable: wattsIsAvailable,
            watts: watts,
            isCharging: mappedIsCharging,
            drawingFrom: drawingFrom,
            externalConnected: mappedExternalConnected
        )
    }

    /// 捕获失败占位：`watts == 0` 仅兼容旧 UI，不得当成在线 0W。
    public static var empty: BatterySnapshot {
        let capturedAt = Date.distantPast
        return BatterySnapshot(
            percent: 0,
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: 0,
            summary: "",
            capturedAt: capturedAt,
            isAvailable: false,
            availability: .currentlyUnavailable,
            percentIsAvailable: false,
            wattsIsAvailable: false,
            wattsIsTrueZero: false,
            percentReading: .unavailable(
                availability: .currentlyUnavailable,
                capturedAt: capturedAt,
                reason: "未捕获到内部电池电源"
            ),
            wattsReading: .unavailable(
                availability: .currentlyUnavailable,
                capturedAt: capturedAt,
                reason: "未捕获到内部电池电源"
            ),
            isChargingIsAvailable: false,
            externalConnectedIsAvailable: false,
            drawingFromIsAvailable: false
        )
    }

    public static func capture() -> BatterySnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let description = sources.compactMap({ source in
                  IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
              }).first(where: { source in
                  source[kIOPSTypeKey as String] as? String == (kIOPSInternalBatteryType as String)
              }) else {
            return .empty
        }

        return makeSnapshot(description: description, capturedAt: Date(), power: smartBatteryPower())
    }

    /// 从 IOPS 电源描述字典构建快照。测试可注入缺 `IsCharging` / `Power Source State` 的 mock，避免打到本机 IOKit。
    /// - Parameter watts: 注入的电池侧净功率；`nil` 表示本次未提供瓦数（不是真实 0W）。
    public static func fromPowerSourceDescription(
        _ description: [String: Any],
        capturedAt: Date = Date(),
        watts: Double? = nil
    ) -> BatterySnapshot {
        let power: SmartBatteryPower
        if let watts {
            power = SmartBatteryPower(
                watts: watts,
                isAvailable: true,
                availability: .available,
                unavailableReason: nil
            )
        } else {
            power = SmartBatteryPower(
                watts: nil,
                isAvailable: false,
                availability: .currentlyUnavailable,
                unavailableReason: "未注入电池侧功率"
            )
        }
        return makeSnapshot(description: description, capturedAt: capturedAt, power: power)
    }

    private static func makeSnapshot(
        description: [String: Any],
        capturedAt: Date,
        power: SmartBatteryPower
    ) -> BatterySnapshot {
        let currentRaw = description[kIOPSCurrentCapacityKey as String]
        let maximumRaw = description[kIOPSMaxCapacityKey as String]
        let percentIsAvailable = currentRaw != nil && maximumRaw != nil
        let current = integer(currentRaw)
        let maximum = max(1, integer(maximumRaw))
        let percent = max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
        let powerSource = parsedPowerSource(description)
        let charging = parsedCharging(description)
        let watts = power.watts ?? 0
        let drawing = powerSource.drawingFrom
        let summary = "\(drawing)，电量 \(percent)%"

        return BatterySnapshot(
            percent: percent,
            drawingFrom: drawing,
            isCharging: charging.value,
            externalConnected: powerSource.externalConnected,
            watts: watts,
            summary: summary,
            capturedAt: capturedAt,
            isAvailable: true,
            availability: .available,
            percentIsAvailable: percentIsAvailable,
            wattsIsAvailable: power.isAvailable,
            wattsIsTrueZero: power.isAvailable && abs(watts) < wattsTrueZeroEpsilon,
            percentReading: MeasurementReading(
                value: percentIsAvailable ? percent : nil,
                isAvailable: percentIsAvailable,
                availability: percentIsAvailable ? .available : .deviceDidNotProvide,
                capturedAt: capturedAt,
                unavailableReason: percentIsAvailable ? nil : "IOPS 未提供 Current Capacity / Max Capacity"
            ),
            wattsReading: MeasurementReading(
                value: power.watts,
                isAvailable: power.isAvailable,
                availability: power.availability,
                capturedAt: capturedAt,
                unavailableReason: power.unavailableReason
            ),
            isChargingIsAvailable: charging.isAvailable,
            externalConnectedIsAvailable: powerSource.isAvailable,
            drawingFromIsAvailable: powerSource.isAvailable
        )
    }

    /// 缺 `Power Source State` 时返回 `"unknown"`，绝不把缺键标成「电池供电」。
    private static func parsedPowerSource(_ description: [String: Any]) -> (
        drawingFrom: String,
        externalConnected: Bool,
        isAvailable: Bool
    ) {
        guard description[kIOPSPowerSourceStateKey as String] != nil else {
            return ("unknown", false, false)
        }
        guard let powerState = description[kIOPSPowerSourceStateKey as String] as? String else {
            return ("unknown", false, false)
        }
        // IOPS AC Power 只说明系统正在用适配器，不能当作适配器物理在位。
        let onAC = powerState == (kIOPSACPowerValue as String)
        return (onAC ? "电源适配器" : "电池供电", onAC, true)
    }

    /// 缺 `Is Charging` 或无法解析时：兼容值为 false，可用性为 false。
    private static func parsedCharging(_ description: [String: Any]) -> (value: Bool, isAvailable: Bool) {
        guard description[kIOPSIsChargingKey as String] != nil else {
            return (false, false)
        }
        guard let value = bool(description[kIOPSIsChargingKey as String]) else {
            return (false, false)
        }
        return (value, true)
    }

    private static func integer(_ raw: Any?) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return 0
    }

    private static func bool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    /// AppleSmartBattery 的 V×I。这是电池侧净功率，不是适配器输出、也不是整机功耗。
    private static func smartBatteryPower() -> SmartBatteryPower {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return SmartBatteryPower(
                watts: nil,
                isAvailable: false,
                availability: .currentlyUnavailable,
                unavailableReason: "未找到 AppleSmartBattery"
            )
        }
        defer { IOObjectRelease(service) }

        let voltageNumber = registryNumber(service: service, key: "Voltage")
        let amperageNumber = registryNumber(service: service, key: "InstantAmperage")
            ?? registryNumber(service: service, key: "Amperage")

        // 缺 Voltage 或电流键时不得把功率写成 0W。
        guard let voltageNumber, let amperageNumber else {
            return SmartBatteryPower(
                watts: nil,
                isAvailable: false,
                availability: .deviceDidNotProvide,
                unavailableReason: "缺少 Voltage 或 InstantAmperage/Amperage"
            )
        }

        let voltageMilli = voltageNumber.doubleValue
        // InstantAmperage 在 IORegistry 里以 UInt64 发布，实际是有符号补码：
        // 正值表示电流流入电池（充电），负值表示电流流出电池（放电）。
        let amperageMilli = Double(Int64(bitPattern: amperageNumber.uint64Value))
        let watts = voltageMilli / 1000 * amperageMilli / 1000
        return SmartBatteryPower(
            watts: watts,
            isAvailable: true,
            availability: .available,
            unavailableReason: nil
        )
    }

    private static func registryNumber(service: io_service_t, key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber
    }
}

private struct SmartBatteryPower {
    var watts: Double?
    var isAvailable: Bool
    var availability: MetricAvailability
    var unavailableReason: String?
}

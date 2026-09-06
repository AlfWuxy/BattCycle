import Foundation
import IOKit
import IOKit.ps

public enum MetricSource: Equatable, Sendable {
    case iokit
    case batt
    case processInfo
    case derived
    case unavailable
}

/// 带名称的指标。各字段语义独立，禁止把电池侧瓦数填进适配器瓦数。
public struct MetricValue<Value: Equatable & Sendable>: Equatable, Sendable {
    public var displayNameZH: String
    public var unit: String
    public var source: MetricSource
    public var value: Value?
    public var availability: MetricAvailability
    public var capturedAt: Date

    public init(
        displayNameZH: String,
        unit: String,
        source: MetricSource,
        value: Value?,
        availability: MetricAvailability,
        capturedAt: Date
    ) {
        self.displayNameZH = displayNameZH
        self.unit = unit
        self.source = source
        self.value = value
        self.availability = availability
        self.capturedAt = capturedAt
    }

    public static func present(
        _ value: Value,
        displayNameZH: String,
        unit: String,
        source: MetricSource,
        capturedAt: Date
    ) -> MetricValue {
        MetricValue(
            displayNameZH: displayNameZH,
            unit: unit,
            source: source,
            value: value,
            availability: .available,
            capturedAt: capturedAt
        )
    }

    public static func missing(
        displayNameZH: String,
        unit: String,
        availability: MetricAvailability,
        source: MetricSource = .unavailable,
        capturedAt: Date
    ) -> MetricValue {
        MetricValue(
            displayNameZH: displayNameZH,
            unit: unit,
            source: source,
            value: nil,
            availability: availability,
            capturedAt: capturedAt
        )
    }
}

public struct PowerMetrics: Equatable, Sendable {
    public var batteryPercent: MetricValue<Int>
    /// 电池侧净功率（AppleSmartBattery Voltage × InstantAmperage），不是适配器功率。
    public var batteryNetPowerWatts: MetricValue<Double>
    /// 适配器物理在位。只接受 IOKit `ExternalConnected`，禁止用 IOPS AC Power 冒充。
    public var adapterPhysicallyConnected: MetricValue<Bool>
    /// IOPS `Power Source State == AC Power`。缺键时 value 为 nil，绝不以 false 冒充已测量。
    public var systemUsingAdapter: MetricValue<Bool>
    /// IOPS `Is Charging`。缺键时 value 为 nil，绝不以 false 冒充已测量。
    public var isCharging: MetricValue<Bool>
    /// 适配器瞬时输出功率。公共头文件没有独立瞬时输出键时保持未提供。
    public var adapterOutputWatts: MetricValue<Double>
    /// 适配器额定功率。来自 AdapterDetails / IOPS `Watts`，不是电池 V×I。
    public var adapterRatedMaxWatts: MetricValue<Double>
    /// 协商功率。仅当存在与 `Watts` 不同的键（例如 `AdapterPower`）时填写。
    public var adapterNegotiatedWatts: MetricValue<Double>
    /// 适配器电流（AdapterDetails `Current`，毫安）。不是电池 InstantAmperage。
    public var adapterCurrentMilliamps: MetricValue<Double>
    /// 适配器名称。
    public var adapterName: MetricValue<String>
    /// 适配器厂商。
    public var adapterManufacturer: MetricValue<String>
    /// 适配器型号。
    public var adapterModel: MetricValue<String>
    /// 适配器系列 / FamilyCode。
    public var adapterFamily: MetricValue<String>
    /// 适配器协议。
    public var adapterProtocol: MetricValue<String>
    /// 适配器接口 / 端口类型。
    public var adapterPortType: MetricValue<String>
    /// 整机功耗。IOKit 不提供，禁止用电池瓦数代替。
    public var systemPowerWatts: MetricValue<Double>
    /// 充电百分比上限。不从 IOKit 读取。
    public var chargePercentLimit: MetricValue<Int>
    /// 充电功率上限。公开 IOKit 无此键，保持不支持；本文件不提供写入 UI。
    public var chargePowerLimitWatts: MetricValue<Double>

    public init(
        batteryPercent: MetricValue<Int>,
        batteryNetPowerWatts: MetricValue<Double>,
        adapterPhysicallyConnected: MetricValue<Bool>,
        systemUsingAdapter: MetricValue<Bool>,
        isCharging: MetricValue<Bool>,
        adapterOutputWatts: MetricValue<Double>,
        adapterRatedMaxWatts: MetricValue<Double>,
        adapterNegotiatedWatts: MetricValue<Double>,
        adapterCurrentMilliamps: MetricValue<Double>,
        adapterName: MetricValue<String>,
        adapterManufacturer: MetricValue<String>,
        adapterModel: MetricValue<String>,
        adapterFamily: MetricValue<String>,
        adapterProtocol: MetricValue<String>,
        adapterPortType: MetricValue<String>,
        systemPowerWatts: MetricValue<Double>,
        chargePercentLimit: MetricValue<Int>,
        chargePowerLimitWatts: MetricValue<Double>
    ) {
        self.batteryPercent = batteryPercent
        self.batteryNetPowerWatts = batteryNetPowerWatts
        self.adapterPhysicallyConnected = adapterPhysicallyConnected
        self.systemUsingAdapter = systemUsingAdapter
        self.isCharging = isCharging
        self.adapterOutputWatts = adapterOutputWatts
        self.adapterRatedMaxWatts = adapterRatedMaxWatts
        self.adapterNegotiatedWatts = adapterNegotiatedWatts
        self.adapterCurrentMilliamps = adapterCurrentMilliamps
        self.adapterName = adapterName
        self.adapterManufacturer = adapterManufacturer
        self.adapterModel = adapterModel
        self.adapterFamily = adapterFamily
        self.adapterProtocol = adapterProtocol
        self.adapterPortType = adapterPortType
        self.systemPowerWatts = systemPowerWatts
        self.chargePercentLimit = chargePercentLimit
        self.chargePowerLimitWatts = chargePowerLimitWatts
    }

    /// 只读捕获。provider 只调用一次，随后把该快照交给 `assemble`。
    public static func capture(using provider: BatteryProviding = IOKitBatteryProvider()) -> PowerMetrics {
        let snapshot = provider.capture()
        return assemble(
            snapshot: snapshot,
            adapterDetails: readAdapterDetails(),
            capturedAt: snapshot.capturedAt,
            adapterPhysicallyConnected: readExternalConnected()
        )
    }

    /// 由已有快照与可选适配器字典组装。本函数不调用 `BatteryProviding.capture`。
    /// `adapterDetails` 缺席时适配器瓦数保持未提供，绝不复制电池瓦数。
    public static func assemble(
        snapshot: BatterySnapshot,
        adapterDetails: [String: Any]? = nil,
        capturedAt: Date? = nil,
        adapterPhysicallyConnected: Bool? = nil,
        adapterPresenceAvailability: MetricAvailability? = nil,
        systemUsingAdapterIsAvailable: Bool? = nil,
        isChargingIsAvailable: Bool? = nil
    ) -> PowerMetrics {
        let at = capturedAt ?? snapshot.capturedAt
        let snapshotMissing: MetricAvailability = snapshot.isAvailable ? .deviceDidNotProvide : .currentlyUnavailable

        let batteryPercent: MetricValue<Int>
        if snapshot.percentIsAvailable {
            batteryPercent = .present(
                snapshot.percent,
                displayNameZH: "电池电量",
                unit: "%",
                source: .iokit,
                capturedAt: at
            )
        } else {
            batteryPercent = .missing(
                displayNameZH: "电池电量",
                unit: "%",
                availability: snapshotMissing,
                source: .iokit,
                capturedAt: at
            )
        }

        let batteryNetPowerWatts: MetricValue<Double>
        if snapshot.wattsIsAvailable {
            batteryNetPowerWatts = .present(
                snapshot.watts,
                displayNameZH: "电池净功率",
                unit: "W",
                source: .iokit,
                capturedAt: at
            )
        } else {
            batteryNetPowerWatts = .missing(
                displayNameZH: "电池净功率",
                unit: "W",
                availability: snapshot.wattsReading.availability,
                source: .iokit,
                capturedAt: at
            )
        }

        let presenceAvailability = adapterPresenceAvailability
            ?? (adapterPhysicallyConnected == nil ? .deviceDidNotProvide : .available)
        let adapterPhysicallyConnectedMetric: MetricValue<Bool>
        if let adapterPhysicallyConnected, presenceAvailability == .available {
            adapterPhysicallyConnectedMetric = .present(
                adapterPhysicallyConnected,
                displayNameZH: "适配器物理连接",
                unit: "",
                source: .iokit,
                capturedAt: at
            )
        } else {
            adapterPhysicallyConnectedMetric = .missing(
                displayNameZH: "适配器物理连接",
                unit: "",
                availability: presenceAvailability,
                source: .iokit,
                capturedAt: at
            )
        }

        let systemUsingAvailable = systemUsingAdapterIsAvailable ?? snapshot.externalConnectedIsAvailable
        let systemUsingAdapter = boolFlagMetric(
            displayNameZH: "系统正在使用适配器",
            value: snapshot.externalConnected,
            flagIsAvailable: systemUsingAvailable,
            missingAvailability: snapshot.externalConnectedAvailability,
            capturedAt: at
        )

        let chargingAvailable = isChargingIsAvailable ?? snapshot.isChargingIsAvailable
        let isCharging = boolFlagMetric(
            displayNameZH: "正在充电",
            value: snapshot.isCharging,
            flagIsAvailable: chargingAvailable,
            missingAvailability: snapshot.isChargingAvailability,
            capturedAt: at
        )

        // AdapterDetails.Watts / kIOPSPowerAdapterWattsKey 是适配器额定瓦数，不是瞬时输出，也不是协商功率。
        let adapterRatedMaxWatts = doubleMetric(
            from: adapterDetails,
            keys: [kIOPSPowerAdapterWattsKey as String, "Watts"],
            displayNameZH: "适配器额定功率",
            unit: "W",
            capturedAt: at
        )
        // 仅接受与 Watts 不同的键。不得把额定功率复制到协商功率。
        let adapterNegotiatedWatts = doubleMetric(
            from: adapterDetails,
            keys: ["AdapterPower", "NegotiatedWatts", "Negotiated Power"],
            displayNameZH: "适配器协商功率",
            unit: "W",
            capturedAt: at
        )
        let adapterCurrentMilliamps = doubleMetric(
            from: adapterDetails,
            keys: [kIOPSPowerAdapterCurrentKey as String, "Current", "Amperage"],
            displayNameZH: "适配器电流",
            unit: "mA",
            capturedAt: at
        )
        let adapterName = stringMetric(
            from: adapterDetails,
            keys: ["Name", "DeviceName", "Description"],
            displayNameZH: "适配器名称",
            capturedAt: at
        )
        let adapterManufacturer = stringMetric(
            from: adapterDetails,
            keys: ["Manufacturer"],
            displayNameZH: "适配器厂商",
            capturedAt: at
        )
        let adapterModel = stringMetric(
            from: adapterDetails,
            keys: ["Model"],
            displayNameZH: "适配器型号",
            capturedAt: at
        )
        let adapterFamily = stringMetric(
            from: adapterDetails,
            keys: [kIOPSPowerAdapterFamilyKey as String, "FamilyCode", "AdapterFamily", "Family"],
            displayNameZH: "适配器系列",
            capturedAt: at
        )
        let adapterProtocol = stringMetric(
            from: adapterDetails,
            keys: ["AdapterProtocol", "Protocol"],
            displayNameZH: "适配器协议",
            capturedAt: at
        )
        let adapterPortType = stringMetric(
            from: adapterDetails,
            keys: ["PortType", "UsbPortType"],
            displayNameZH: "适配器接口",
            capturedAt: at
        )

        return PowerMetrics(
            batteryPercent: batteryPercent,
            batteryNetPowerWatts: batteryNetPowerWatts,
            adapterPhysicallyConnected: adapterPhysicallyConnectedMetric,
            systemUsingAdapter: systemUsingAdapter,
            isCharging: isCharging,
            adapterOutputWatts: .missing(
                displayNameZH: "适配器输出功率",
                unit: "W",
                availability: .deviceDidNotProvide,
                source: .iokit,
                capturedAt: at
            ),
            adapterRatedMaxWatts: adapterRatedMaxWatts,
            adapterNegotiatedWatts: adapterNegotiatedWatts,
            adapterCurrentMilliamps: adapterCurrentMilliamps,
            adapterName: adapterName,
            adapterManufacturer: adapterManufacturer,
            adapterModel: adapterModel,
            adapterFamily: adapterFamily,
            adapterProtocol: adapterProtocol,
            adapterPortType: adapterPortType,
            systemPowerWatts: .missing(
                displayNameZH: "整机功耗",
                unit: "W",
                availability: .deviceDidNotProvide,
                source: .unavailable,
                capturedAt: at
            ),
            chargePercentLimit: .missing(
                displayNameZH: "充电百分比上限",
                unit: "%",
                availability: .unsupported,
                source: .unavailable,
                capturedAt: at
            ),
            chargePowerLimitWatts: .missing(
                displayNameZH: "充电功率上限",
                unit: "W",
                availability: .unsupported,
                source: .unavailable,
                capturedAt: at
            )
        )
    }

    /// IOPS 布尔标志：缺键为 nil + currentlyUnavailable/deviceDidNotProvide，不用 false 冒充已测量。
    private static func boolFlagMetric(
        displayNameZH: String,
        value: Bool,
        flagIsAvailable: Bool,
        missingAvailability: MetricAvailability,
        capturedAt: Date
    ) -> MetricValue<Bool> {
        if flagIsAvailable {
            return .present(
                value,
                displayNameZH: displayNameZH,
                unit: "",
                source: .iokit,
                capturedAt: capturedAt
            )
        }
        return .missing(
            displayNameZH: displayNameZH,
            unit: "",
            availability: missingAvailability == .available ? .deviceDidNotProvide : missingAvailability,
            source: .iokit,
            capturedAt: capturedAt
        )
    }

    private static func doubleMetric(
        from details: [String: Any]?,
        keys: [String],
        displayNameZH: String,
        unit: String,
        capturedAt: Date
    ) -> MetricValue<Double> {
        if let value = firstDouble(in: details, keys: keys) {
            return .present(
                value,
                displayNameZH: displayNameZH,
                unit: unit,
                source: .iokit,
                capturedAt: capturedAt
            )
        }
        return .missing(
            displayNameZH: displayNameZH,
            unit: unit,
            availability: .deviceDidNotProvide,
            source: .iokit,
            capturedAt: capturedAt
        )
    }

    private static func stringMetric(
        from details: [String: Any]?,
        keys: [String],
        displayNameZH: String,
        capturedAt: Date
    ) -> MetricValue<String> {
        if let value = firstString(in: details, keys: keys) {
            return .present(
                value,
                displayNameZH: displayNameZH,
                unit: "",
                source: .iokit,
                capturedAt: capturedAt
            )
        }
        return .missing(
            displayNameZH: displayNameZH,
            unit: "",
            availability: .deviceDidNotProvide,
            source: .iokit,
            capturedAt: capturedAt
        )
    }

    private static func firstDouble(in details: [String: Any]?, keys: [String]) -> Double? {
        guard let details else { return nil }
        for key in keys {
            if let value = double(from: details[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstString(in details: [String: Any]?, keys: [String]) -> String? {
        guard let details else { return nil }
        for key in keys {
            if let value = string(from: details[key]) {
                return value
            }
        }
        return nil
    }

    /// 只读合并：IOPS 电池描述中的 AdapterDetails、IOPSCopyExternalPowerAdapterDetails、AppleSmartBattery AdapterDetails。
    /// 不把电池描述里的 Voltage / InstantAmperage / Current Capacity 当成适配器输出。
    private static func readAdapterDetails() -> [String: Any]? {
        var merged: [String: Any] = [:]

        if let description = iopsInternalBatteryDescription() {
            if let nested = description["AdapterDetails"] as? [String: Any] {
                merged.merge(nested) { _, new in new }
            }
            if let watts = description[kIOPSPowerAdapterWattsKey as String] ?? description["Watts"] {
                merged["Watts"] = watts
            }
        }

        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            merged.merge(details) { _, new in new }
        }

        if let nested = smartBatteryAdapterDetails() {
            merged.merge(nested) { _, new in new }
        }

        return merged.isEmpty ? nil : merged
    }

    /// IOPM `ExternalConnected`，与 IOPS AC Power 不是同一键。
    private static func readExternalConnected() -> Bool? {
        withSmartBatteryService { service in
            bool(registryProperty(service: service, key: "ExternalConnected"))
        }
    }

    private static func smartBatteryAdapterDetails() -> [String: Any]? {
        withSmartBatteryService { service in
            registryProperty(service: service, key: "AdapterDetails") as? [String: Any]
        }
    }

    private static func iopsInternalBatteryDescription() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        return sources.compactMap { source in
            IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
        }.first(where: { source in
            source[kIOPSTypeKey as String] as? String == (kIOPSInternalBatteryType as String)
        })
    }

    private static func withSmartBatteryService<T>(_ body: (io_service_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return body(service)
    }

    private static func registryProperty(service: io_service_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func bool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    private static func double(from raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    private static func string(from raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = raw as? NSNumber {
            let asDouble = number.doubleValue
            if asDouble.rounded() == asDouble {
                return String(number.intValue)
            }
            return String(asDouble)
        }
        return nil
    }
}

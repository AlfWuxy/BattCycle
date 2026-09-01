import Foundation
import IOKit
import IOKit.ps

public struct BatterySnapshot: Equatable, Sendable {
    public var percent: Int
    public var drawingFrom: String
    public var isCharging: Bool
    public var externalConnected: Bool
    public var watts: Double
    public var summary: String
    public var capturedAt: Date

    public static var empty: BatterySnapshot {
        BatterySnapshot(
            percent: 0,
            drawingFrom: "unknown",
            isCharging: false,
            externalConnected: false,
            watts: 0,
            summary: "",
            capturedAt: .distantPast
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

        let current = integer(description[kIOPSCurrentCapacityKey as String])
        let maximum = max(1, integer(description[kIOPSMaxCapacityKey as String]))
        let percent = max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
        let powerState = description[kIOPSPowerSourceStateKey as String] as? String ?? "unknown"
        let external = powerState == (kIOPSACPowerValue as String)
        let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let watts = smartBatteryWatts()
        let drawing = external ? "电源适配器" : "电池供电"
        let summary = "\(drawing)，电量 \(percent)%"

        return BatterySnapshot(
            percent: percent,
            drawingFrom: drawing,
            isCharging: charging,
            externalConnected: external,
            watts: watts,
            summary: summary,
            capturedAt: Date()
        )
    }

    private static func integer(_ raw: Any?) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let value = raw as? Int { return value }
        return 0
    }

    private static func smartBatteryWatts() -> Double {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        let voltage = registryNumber(service: service, key: "Voltage")?.doubleValue ?? 0
        guard let amperageNumber = registryNumber(service: service, key: "InstantAmperage")
            ?? registryNumber(service: service, key: "Amperage") else { return 0 }
        let amperage = Double(Int64(bitPattern: amperageNumber.uint64Value))
        return voltage / 1000 * amperage / 1000
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

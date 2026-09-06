import Foundation

/// 电池快照来源。测试注入 `MockBatteryProvider`，运行时用 `IOKitBatteryProvider`。
/// 与 Core 其余值类型一样跨隔离域传递；调用方每拍只应 `capture()` 一次。
public protocol BatteryProviding: Sendable {
    func capture() -> BatterySnapshot
}

/// 只读 IOKit：本类型不 import、不写入 IOKit，只把捕获委托给 `BatterySnapshot.capture()` 一次。
public struct IOKitBatteryProvider: BatteryProviding {
    public init() {}

    public func capture() -> BatterySnapshot {
        BatterySnapshot.capture()
    }
}

/// 测试注入源：原样返回给定快照，绝不调用 IOKit 或 `BatterySnapshot.capture()`。
public struct MockBatteryProvider: BatteryProviding {
    public var snapshot: BatterySnapshot

    public init(snapshot: BatterySnapshot) {
        self.snapshot = snapshot
    }

    public func capture() -> BatterySnapshot {
        snapshot
    }
}

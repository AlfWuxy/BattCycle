import Foundation

/// 引擎与适配器控制的单一事务锁。
///
/// 同一时刻只允许一个 start / stop / restore / suspend / resume。
/// `pendingRestore` 与 `controlGeneration` 由调用方持有；本类型只给出到达与代次判定。
/// 循环运行中拒绝独立 suspend/resume 由 EngineController 判定，此处不编码。
public enum ControlTransaction: Equatable, Sendable, CaseIterable {
    case idle
    case start
    case stop
    case restore
    case suspend
    case resume

    /// 互斥控制操作（不含 idle）。
    public static var exclusiveOperations: [ControlTransaction] {
        allCases.filter { $0 != .idle }
    }

    public var isBusy: Bool { self != .idle }

    /// Restore 最高优先级：空闲立即开始；已在 restore 则忽略重复；其它忙事务则排队（不启动第二次 disable）。
    public func restoreArrival() -> RestoreArrival {
        switch self {
        case .idle:
            return .beginNow
        case .restore:
            return .ignoreDuplicate
        case .start, .stop, .suspend, .resume:
            return .queuePending
        }
    }

    /// 非 Restore 在已有事务时必须拒绝（含重叠 start）。Restore 仅在空闲时可 begin，排队由 `restoreArrival` 表达。
    public func canBegin(_ next: ControlTransaction) -> Bool {
        guard next != .idle else { return false }
        if next == .restore {
            return restoreArrival() == .beginNow
        }
        return self == .idle
    }

    /// restore 成功后调用方递增 generation；迟到的 suspend 完成必须对照此代次忽略。
    public static func shouldApplySuspendResult(
        capturedGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        capturedGeneration == currentGeneration
    }
}

public enum RestoreArrival: Equatable, Sendable {
    case beginNow
    case ignoreDuplicate
    case queuePending
}

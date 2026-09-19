import BattCycleCore
import XCTest

final class ControlTransactionTests: XCTestCase {
    func testIdleIsNotBusyAndOthersAre() {
        XCTAssertFalse(ControlTransaction.idle.isBusy)
        for operation in ControlTransaction.exclusiveOperations {
            XCTAssertTrue(operation.isBusy)
        }
        XCTAssertEqual(
            ControlTransaction.exclusiveOperations,
            [.start, .stop, .restore, .suspend, .resume]
        )
    }

    func testOverlappingStartIsRejected() {
        XCTAssertTrue(ControlTransaction.idle.canBegin(.start))
        XCTAssertFalse(ControlTransaction.start.canBegin(.start))
        XCTAssertFalse(ControlTransaction.start.canBegin(.stop))
        XCTAssertFalse(ControlTransaction.start.canBegin(.suspend))
        XCTAssertFalse(ControlTransaction.start.canBegin(.resume))
        XCTAssertFalse(ControlTransaction.start.canBegin(.idle))
    }

    func testNonRestoreOperationsAreMutuallyExclusive() {
        for current in ControlTransaction.exclusiveOperations {
            for next in ControlTransaction.exclusiveOperations where next != .restore {
                XCTAssertFalse(
                    current.canBegin(next),
                    "\(current) 进行中不得再 begin \(next)"
                )
            }
        }
        XCTAssertTrue(ControlTransaction.idle.canBegin(.stop))
        XCTAssertTrue(ControlTransaction.idle.canBegin(.suspend))
        XCTAssertTrue(ControlTransaction.idle.canBegin(.resume))
        XCTAssertFalse(ControlTransaction.idle.canBegin(.idle))
    }

    func testRestoreFromIdleBeginsImmediately() {
        XCTAssertEqual(ControlTransaction.idle.restoreArrival(), .beginNow)
        XCTAssertTrue(ControlTransaction.idle.canBegin(.restore))
    }

    func testDuplicateRestoreIsIgnored() {
        XCTAssertEqual(ControlTransaction.restore.restoreArrival(), .ignoreDuplicate)
        XCTAssertFalse(ControlTransaction.restore.canBegin(.restore))
        XCTAssertFalse(ControlTransaction.restore.canBegin(.start))
        XCTAssertFalse(ControlTransaction.restore.canBegin(.suspend))
    }

    func testRestoreQueuesDuringAnyNonRestoreBusyTransaction() {
        let busyNonRestore: [ControlTransaction] = [.start, .stop, .suspend, .resume]
        for current in busyNonRestore {
            XCTAssertEqual(
                current.restoreArrival(),
                .queuePending,
                "\(current) 进行中 restore 应排队，不得立刻第二次 disable"
            )
            XCTAssertFalse(current.canBegin(.restore))
        }
    }

    func testRestoreDoesNotPreemptInFlightTransaction() {
        XCTAssertEqual(ControlTransaction.suspend.restoreArrival(), .queuePending)
        XCTAssertEqual(ControlTransaction.resume.restoreArrival(), .queuePending)
        XCTAssertFalse(ControlTransaction.suspend.canBegin(.suspend))
        XCTAssertFalse(ControlTransaction.suspend.canBegin(.resume))
        XCTAssertFalse(ControlTransaction.suspend.canBegin(.restore))
    }

    func testSuspendResultNoopsWhenGenerationChangedByRestoreSuccess() {
        XCTAssertTrue(
            ControlTransaction.shouldApplySuspendResult(capturedGeneration: 3, currentGeneration: 3)
        )
        XCTAssertFalse(
            ControlTransaction.shouldApplySuspendResult(capturedGeneration: 3, currentGeneration: 4)
        )
        XCTAssertTrue(
            ControlTransaction.shouldApplySuspendResult(capturedGeneration: 0, currentGeneration: 0)
        )
    }
}

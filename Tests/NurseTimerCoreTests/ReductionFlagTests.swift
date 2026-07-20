import XCTest
@testable import NurseTimerCore

/// Item 4: planWasReduced is true on ANY reduction (pre trim, chain shortening, or
/// coalescing at any tier/category), with per-kind counts.
final class ReductionFlagTests: XCTestCase {

    func test_belowCap_noReduction() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: UUID(), scheduleType: everyHr(4), nextDueAt: now + 600, leadTimeMinutes: 5)],
            settings: .default, now: now, calendar: cal)
        XCTAssertFalse(plan.planWasReduced)
        XCTAssertFalse(plan.reduction.any)
        XCTAssertEqual(plan.reduction.preAlertsTrimmed, 0)
    }

    func test_chainShortening_setsReduced_withDepthCount() {
        // 12 overdue at the same time → chains shorten to the floor (no grouping).
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 60
        let tasks = (0..<12).map { _ in TaskSnapshot(id: UUID(), scheduleType: everyHr(4), nextDueAt: due) }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.planWasReduced)
        XCTAssertGreaterThan(plan.reduction.chainDepthReduced, 0)
        XCTAssertEqual(plan.reduction.digestsFormed, 0)
    }

    func test_coalescing_setsReduced_withDigestCount() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<120).map { i in
            TaskSnapshot(id: UUID(), roomNumber: "R\(i % 8)", scheduleType: everyHr(4),
                         nextDueAt: now + Double((i % 24) * 30 * 60 + 60), leadTimeMinutes: 24 * 60)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.planWasReduced)
        XCTAssertGreaterThan(plan.reduction.digestsFormed, 0)
    }

    func test_repairDigest_countsAsReduction() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        let tasks = (0..<10).map { _ in
            TaskSnapshot(id: UUID(), roomNumber: "R", scheduleType: .needsRepair(rawPayload: Data("x".utf8)),
                         nextDueAt: now - 60)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.planWasReduced)          // repair digest is a reduction
        XCTAssertGreaterThanOrEqual(plan.reduction.digestsFormed, 1)
    }
}

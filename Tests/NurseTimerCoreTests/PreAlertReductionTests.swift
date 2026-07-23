import XCTest
@testable import NurseTimerCore

/// Pre-alert investigation (feedback pass 5, items 1–2). These encode the diagnosis and then the
/// redesigned reduction order that keeps workflow-critical pre-alerts.
final class PreAlertReductionTests: XCTestCase {

    private func preCount(_ plan: NotificationPlan) -> Int { plan.notifications.filter { $0.kind == .pre }.count }
    private func dueCount(_ plan: NotificationPlan) -> Int { plan.notifications.filter { $0.kind == .due }.count }

    /// A realistic shift: `n` upcoming interval tasks, each with a full pre-scheduled taper and a
    /// future pre-alert (default lead unless `explicitLead` given). Dues are spread 20 min apart.
    private func realisticShift(_ n: Int, now: Date, explicitLead: Int? = nil) -> [TaskSnapshot] {
        (0..<n).map { i in
            TaskSnapshot(id: UUID(), roomNumber: "R\(i)", scheduleType: everyHr(4),
                         nextDueAt: now + Double((i + 1) * 20 * 60), leadTimeMinutes: explicitLead)
        }
    }

    // MARK: Item 1a — realistic load currently trims the pre-alerts

    /// DIAGNOSIS (item 1a): with pre-scheduled tapers, an 8-task shift pushes baseline demand far
    /// past the 60-cap. Under the OLD reduction order (pre-alerts trimmed FIRST) every pre-alert
    /// is dropped even though trimming taper tails alone would have kept them — the reported bug.
    /// (This assertion is FLIPPED into the permanent guarantee below once the order is redesigned.)
    func test_item1a_diagnosis_realisticLoad_dropsAllPreAlerts_underOldOrder() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = realisticShift(8, now: now)
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertEqual(dueCount(plan), 8, "every due alert must survive")
        XCTAssertEqual(preCount(plan), 0, "DIAGNOSIS: old order drops all pre-alerts at realistic load")
        XCTAssertTrue(plan.wasTrimmed)
    }

    // MARK: Item 1b — near-due creation skips the pre-alert as past (not a budget problem)

    /// DIAGNOSIS (item 1b): a single task with `due − lead ≤ now` produces NO pre-alert regardless
    /// of budget — the pre instant is already in the past, so it's correctly skipped. This is a
    /// distinct, legitimate cause (surfaced in the form by item 3), NOT the reduction pipeline.
    func test_item1b_diagnosis_nearDueCreation_skipsPreAsPast_evenWithNoBudgetPressure() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let due = now + 30 * 60                      // due in 30 min
        let task = TaskSnapshot(id: UUID(), scheduleType: everyHr(4), nextDueAt: due, leadTimeMinutes: 30)
        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertFalse(plan.wasTrimmed, "single task — no budget pressure")
        XCTAssertEqual(dueCount(plan), 1)
        XCTAssertEqual(preCount(plan), 0, "pre instant (due − 30m = now) is past, so it's skipped")
    }
}

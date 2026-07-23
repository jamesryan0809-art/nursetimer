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

    // MARK: Item 2 — PERMANENT REGRESSION: realistic load retains ALL pre-alerts

    /// The redesigned order (item 2) trims taper tails to the 5-ping floor BEFORE any pre-alert,
    /// so a realistic 8-task shift keeps every pre-alert (8 × (pre+due+5) = 56 ≤ 60). This is the
    /// item-1a scenario flipped into a permanent guarantee — a 30-min ping must survive a full
    /// shift load.
    func test_item2_realisticLoad_retainsAllPreAlerts() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = realisticShift(8, now: now)
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertEqual(preCount(plan), 8, "every pre-alert must survive a realistic shift load")
        XCTAssertEqual(dueCount(plan), 8)
        XCTAssertFalse(plan.planWasCoalesced, "fits at the chain floor without grouping")
        XCTAssertEqual(plan.reduction.preAlertsTrimmed, 0)
        XCTAssertGreaterThan(plan.reduction.taperPingsTrimmed, 0, "tails were shed, not the pre-alerts")
    }

    /// Order proof (item 2a): reduction sheds taper tails before pre-alerts — a load where
    /// tail-trimming alone fits keeps all pre-alerts AND reports taper pings trimmed.
    func test_item2_trimsTaperTailsBeforePreAlerts() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let plan = NotificationPlanner.plan(tasks: realisticShift(8, now: now),
                                            settings: .default, now: now, calendar: cal)
        XCTAssertGreaterThan(plan.reduction.chainDepthReduced, 0)
        XCTAssertEqual(plan.reduction.preAlertsTrimmed, 0)
    }

    /// Protection (item 2b/2c): when pre-alerts MUST be trimmed after tails hit the floor,
    /// default-lead pre-alerts go first and explicit-lead ones are protected. 9 tasks at floor =
    /// 63 > 60 → exactly 3 pre-alerts trimmed, all from the default-lead group; every
    /// explicit-lead pre-alert survives.
    func test_item2_explicitLeadPreAlerts_protectedOverDefault() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        var tasks: [TaskSnapshot] = []
        var explicitIDs: Set<UUID> = []
        for i in 0..<9 {
            let id = UUID()
            let explicit = i >= 5                    // 5 default-lead, 4 explicit-lead
            if explicit { explicitIDs.insert(id) }
            tasks.append(TaskSnapshot(id: id, roomNumber: "R\(i)", scheduleType: everyHr(4),
                                      nextDueAt: now + Double((i + 1) * 20 * 60),
                                      leadTimeMinutes: explicit ? 20 : nil))
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertFalse(plan.planWasCoalesced, "trimming default pre-alerts is enough; no grouping")
        XCTAssertEqual(plan.reduction.preAlertsTrimmed, 3)
        XCTAssertEqual(plan.reduction.preAlertsProtectedKept, 4)
        // Every explicit-lead task keeps its pre-alert.
        let preIDs = Set(plan.notifications.filter { $0.kind == .pre }.compactMap { $0.taskID })
        XCTAssertTrue(explicitIDs.isSubset(of: preIDs), "explicit-lead pre-alerts must be protected")
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

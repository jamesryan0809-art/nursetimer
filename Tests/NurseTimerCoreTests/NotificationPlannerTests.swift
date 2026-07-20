import XCTest
@testable import NurseTimerCore

final class NotificationPlannerTests: XCTestCase {

    private let taskID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func slots(_ plan: NotificationPlan) -> [NotificationSlot] {
        plan.notifications.map { $0.slot }
    }

    // MARK: Deterministic identifiers (spec §4.3)

    func test_identifier_isDeterministicAndWellFormed() {
        let cal = utcCalendar()
        let due = dt(cal, 2024, 3, 9, 16, 0)   // 2024-03-09T16:00:00Z
        XCTAssertEqual(
            NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .due),
            "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|due")
        XCTAssertEqual(
            NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .pre),
            "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|pre")
        XCTAssertEqual(
            NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .snooze(3)),
            "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|snooze-3")
    }

    func test_identifier_sameInputsProduceSameString() {
        // Both devices must derive identical IDs for cross-device dedup (spec §5.4).
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 17, 7)
        XCTAssertEqual(
            NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .snooze(7)),
            NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .snooze(7)))
    }

    // MARK: Upcoming tasks → pre + due (spec §4.3)

    func test_upcomingTask_schedulesPreThenDue() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let due = dt(cal, 2026, 7, 19, 16, 30)   // 30 min out, lead 15 → pre in future
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4), nextDueAt: due)

        let plan = NotificationPlanner.plan(
            tasks: [task], settings: .default, now: now, calendar: cal)

        XCTAssertEqual(slots(plan), [.pre, .due])
        XCTAssertFalse(plan.trimmed)
        let pre = plan.notifications[0]
        XCTAssertEqual(pre.fireDate, dt(cal, 2026, 7, 19, 16, 15))   // due − 15
        XCTAssertEqual(plan.notifications[1].fireDate, due)
    }

    func test_upcomingTask_preAlreadyPast_schedulesDueOnly() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let due = dt(cal, 2026, 7, 19, 16, 5)    // 5 min out, lead 15 → pre already past
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4), nextDueAt: due)

        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertEqual(slots(plan), [.due])
    }

    // MARK: 12h horizon (spec §4.3 / §8)

    func test_taskBeyond12hHorizon_isNotScheduled() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let due = now.addingTimeInterval(13 * 3600)   // beyond horizon
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4), nextDueAt: due)
        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    func test_taskJustInsideHorizon_isScheduled() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let due = now.addingTimeInterval(11 * 3600)
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4), nextDueAt: due)
        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertEqual(slots(plan), [.pre, .due])
    }

    // MARK: Overdue → snooze chain, and action cancels it (spec §4.2 / §5.3)

    func test_overdueTask_schedulesSnoozeChainOnly() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due.addingTimeInterval(60)     // 1 min overdue
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4), nextDueAt: due)

        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.count, 20)               // full chain, within horizon
        XCTAssertTrue(plan.notifications.allSatisfy {
            if case .snooze = $0.slot { return true } else { return false } })
        // All anchored to the same due date → cancelling the task kills them all.
        XCTAssertTrue(plan.notifications.allSatisfy { $0.dueDate == due })
    }

    func test_actingOnTask_movesDueToFuture_dropsSnoozeChain() {
        // Simulate GIVEN: engine recomputes nextDueAt to the future; a re-plan then
        // contains pre+due and NO snooze slots — i.e. the chain is cancelled (spec §5.3).
        let cal = utcCalendar()
        let overdueDue = dt(cal, 2026, 7, 19, 16, 0)
        let now = overdueDue.addingTimeInterval(120)
        let newDue = SchedulingEngine.nextDueAfterCompletion(
            schedule: .interval(hours: 4), completedAt: now, calendar: cal)!
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4),
                                lastCompletedAt: now, nextDueAt: newDue)

        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertEqual(slots(plan), [.pre, .due])
        XCTAssertFalse(plan.notifications.contains {
            if case .snooze = $0.slot { return true } else { return false } })
    }

    func test_explicitSnooze_reAnchorsChainToTapTime() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due.addingTimeInterval(5 * 60)          // 5 min overdue
        let tapped = now                                   // nurse taps Snooze now
        let task = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4),
                                nextDueAt: due, explicitSnoozeAt: tapped)

        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        // First ping is now + 3 min, not due + k·3.
        XCTAssertEqual(plan.notifications.first?.fireDate, tapped.addingTimeInterval(3 * 60))
    }

    // MARK: Paused / unscheduled contribute nothing

    func test_pausedTask_andPRN_produceNoNotifications() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let paused = TaskSnapshot(id: taskID1, scheduleType: .interval(hours: 4),
                                  nextDueAt: now.addingTimeInterval(1800), isPaused: true)
        let prn = TaskSnapshot(scheduleType: .prn, nextDueAt: nil)
        let plan = NotificationPlanner.plan(tasks: [paused, prn], settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    // MARK: 64-cap trimming (spec §4.3)

    func test_budgetTrim_dropsFurthestPreAlertsFirst_keepsAllDueAlerts() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        // 30 tasks → 30 pre + 30 due = 60 notifications, over the soft limit of 55.
        // lead 5 keeps every pre in the future; due times spread 10..300 min out.
        var tasks: [TaskSnapshot] = []
        for i in 0..<30 {
            let due = now.addingTimeInterval(Double((i + 1) * 10) * 60)
            tasks.append(TaskSnapshot(
                id: UUID(), scheduleType: .interval(hours: 4), nextDueAt: due, leadTimeMinutes: 5))
        }

        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)

        XCTAssertTrue(plan.trimmed)
        XCTAssertEqual(plan.notifications.count, 55)      // trimmed down to soft limit
        let dueCount = plan.notifications.filter { $0.slot == .due }.count
        let preCount = plan.notifications.filter { $0.slot == .pre }.count
        XCTAssertEqual(dueCount, 30)                       // no due alert ever dropped
        XCTAssertEqual(preCount, 25)                       // 5 furthest pre-alerts trimmed

        // The 5 furthest-out tasks lost their pre-alert; the nearest kept theirs.
        let latestDue = tasks.max { $0.nextDueAt! < $1.nextDueAt! }!
        let earliestDue = tasks.min { $0.nextDueAt! < $1.nextDueAt! }!
        XCTAssertFalse(plan.notifications.contains { $0.taskID == latestDue.id && $0.slot == .pre })
        XCTAssertTrue(plan.notifications.contains { $0.taskID == earliestDue.id && $0.slot == .pre })
    }

    func test_belowSoftLimit_isNotTrimmed() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<10).map { i in
            TaskSnapshot(id: UUID(), scheduleType: .interval(hours: 4),
                         nextDueAt: now.addingTimeInterval(Double((i + 1) * 10) * 60),
                         leadTimeMinutes: 5)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertFalse(plan.trimmed)
        XCTAssertEqual(plan.notifications.count, 20)
    }

    // MARK: Output ordering

    func test_planIsSortedByFireDate() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<5).map { i in
            TaskSnapshot(id: UUID(), scheduleType: .interval(hours: 4),
                         nextDueAt: now.addingTimeInterval(Double((5 - i) * 20) * 60))
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        let fireDates = plan.notifications.map { $0.fireDate }
        XCTAssertEqual(fireDates, fireDates.sorted())
    }
}

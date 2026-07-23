import XCTest
@testable import NurseTimerCore

final class NotificationPlannerTests: XCTestCase {

    private let taskID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func kinds(_ plan: NotificationPlan) -> [PlannedKind] { plan.notifications.map { $0.kind } }

    /// Every task id represented in the plan, whether as an individual alert or a group member.
    private func represented(_ plan: NotificationPlan) -> Set<UUID> {
        var s = Set<UUID>()
        for n in plan.notifications {
            if let t = n.taskID { s.insert(t) }
            if let g = n.group { g.memberTaskIDs.forEach { s.insert($0) } }
        }
        return s
    }

    /// N upcoming tasks that each produce exactly one `due` alert (no pre-alert),
    /// spread across `windows` fixed 30-min windows and `rooms` rooms.
    private func upcomingNoPre(_ n: Int, now: Date, rooms: Int, windows: Int) -> [TaskSnapshot] {
        (0..<n).map { i in
            let w = i % windows
            let due = now.addingTimeInterval(Double(w) * 30 * 60 + 60)   // 1 min into window w
            return TaskSnapshot(id: UUID(), roomNumber: "R\(i % rooms)", scheduleType: everyHr(4),
                                nextDueAt: due, leadTimeMinutes: 24 * 60)   // huge lead → pre suppressed
        }
    }

    // MARK: Deterministic identifiers (spec §4.3)

    func test_identifier_isDeterministicAndWellFormed() {
        let cal = utcCalendar()
        let due = dt(cal, 2024, 3, 9, 16, 0)   // 2024-03-09T16:00:00Z
        XCTAssertEqual(NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .due),
                       "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|due")
        XCTAssertEqual(NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .pre),
                       "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|pre")
        XCTAssertEqual(NotificationPlanner.identifier(taskID: taskID1, due: due, slot: .snooze(3)),
                       "00000000-0000-0000-0000-000000000001|2024-03-09T16:00:00Z|snooze-3")
    }

    func test_groupIdentifier_deterministic() {
        let cal = utcCalendar()
        let win = dt(cal, 2024, 3, 9, 16, 0)
        XCTAssertEqual(NotificationPlanner.groupIdentifier(room: "422", windowStart: win),
                       "group|422|2024-03-09T16:00:00Z")
        XCTAssertEqual(NotificationPlanner.groupIdentifier(room: nil, windowStart: win),
                       "group|*|2024-03-09T16:00:00Z")
    }

    // MARK: Upcoming → pre + due

    func test_upcomingTask_schedulesPreThenDue() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let due = dt(cal, 2026, 7, 19, 16, 30)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due)],
            settings: .default, now: now, calendar: cal)
        // Item 3: an upcoming task emits pre, due, AND its pre-scheduled post-due taper.
        XCTAssertEqual(plan.notifications[0].fireDate, dt(cal, 2026, 7, 19, 16, 15))   // pre = due − 15
        XCTAssertEqual(plan.notifications[0].kind, .pre)
        XCTAssertEqual(plan.notifications[1].fireDate, due)                            // due
        XCTAssertEqual(plan.notifications[1].kind, .due)
        XCTAssertTrue(plan.notifications.contains { $0.kind == .snooze })              // taper pre-scheduled
        XCTAssertTrue(plan.notifications.allSatisfy { $0.taskID == taskID1 })
        XCTAssertFalse(plan.planWasCoalesced)                                          // one task fits
    }

    func test_futureDueTask_emitsPreDueAndTaperPings() {
        // Item 3: a future-due task is planned WITH its post-due taper at replan time —
        // pre, due, then Phase-1 pings at due+3/6/9… (no need to foreground first).
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let due = dt(cal, 2026, 7, 19, 16, 30)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due)],
            settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.first { $0.kind == .pre }?.fireDate, due - 15 * 60)
        XCTAssertEqual(plan.notifications.first { $0.kind == .due }?.fireDate, due)
        let taper = plan.notifications.filter { $0.kind == .snooze }.map { $0.fireDate }.sorted()
        XCTAssertEqual(Array(taper.prefix(3)), (1...3).map { due + Double($0) * 3 * 60 })
        XCTAssertTrue(plan.notifications.filter { $0.kind == .snooze }.allSatisfy { $0.dueDate == due })
    }

    func test_upcomingTask_preAlreadyPast_schedulesDueOnly() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: dt(cal, 2026, 7, 19, 16, 5))],
            settings: .default, now: now, calendar: cal)
        XCTAssertFalse(plan.notifications.contains { $0.kind == .pre })   // pre already past
        XCTAssertEqual(plan.notifications.first?.kind, .due)
        XCTAssertTrue(plan.notifications.contains { $0.kind == .snooze }) // taper still pre-scheduled
    }

    // MARK: 12h horizon

    func test_taskBeyond12hHorizon_isNotScheduled() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: now + 13 * 3600)],
            settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    func test_taskJustInsideHorizon_isScheduled() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: now + 11 * 3600)],
            settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.contains { $0.kind == .pre })
        XCTAssertTrue(plan.notifications.contains { $0.kind == .due })
    }

    // MARK: Overdue snooze chain + action cancels it

    func test_overdueTask_schedulesSnoozeChainOnly() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 60
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due)],
            settings: .default, now: now, calendar: cal)
        // Overdue task → tapered chain only (no pre/due). First ping is due + 3 min (Phase 1).
        XCTAssertTrue(plan.notifications.allSatisfy { $0.kind == .snooze })
        XCTAssertTrue(plan.notifications.allSatisfy { $0.dueDate == due })
        XCTAssertGreaterThanOrEqual(plan.notifications.count, 5)     // at least the floor
        XCTAssertEqual(plan.notifications.first?.fireDate, due + 3 * 60)
    }

    func test_actingOnTask_reAnchorsToNewFutureDue() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0) + 120
        let newDue = SchedulingEngine.nextDueAfterCompletion(schedule: everyHr(4), completedAt: now, calendar: cal)!
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), lastCompletedAt: now, nextDueAt: newDue)],
            settings: .default, now: now, calendar: cal)
        // The old overdue chain is gone; everything is anchored to the NEW future due.
        XCTAssertTrue(plan.notifications.contains { $0.kind == .pre })
        XCTAssertTrue(plan.notifications.contains { $0.kind == .due })
        XCTAssertTrue(plan.notifications.allSatisfy { $0.dueDate == newDue })
    }

    func test_explicitSnooze_reAnchorsChainToTapTime() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 5 * 60
        let plan = NotificationPlanner.plan(
            tasks: [TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due, explicitSnoozeAt: now)],
            settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.first?.fireDate, now + 3 * 60)
    }

    // MARK: Paused / PRN

    func test_pausedTask_andPRN_produceNoNotifications() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let plan = NotificationPlanner.plan(tasks: [
            TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: now + 1800, isPaused: true),
            TaskSnapshot(scheduleType: .prn, nextDueAt: nil),
        ], settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.isEmpty)
    }

    /// Feedback item 2: a muted task is excluded from planning exactly like a paused one —
    /// no notifications of any kind — while an otherwise-identical unmuted task schedules.
    func test_mutedTask_producesNoNotifications() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let due = dt(cal, 2026, 7, 19, 16, 30)
        let muted = NotificationPlanner.plan(tasks: [
            TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due, notificationsEnabled: false),
        ], settings: .default, now: now, calendar: cal)
        XCTAssertTrue(muted.notifications.isEmpty)

        // Control: the same task with notifications ON does schedule.
        let live = NotificationPlanner.plan(tasks: [
            TaskSnapshot(id: taskID1, scheduleType: everyHr(4), nextDueAt: due, notificationsEnabled: true),
        ], settings: .default, now: now, calendar: cal)
        XCTAssertFalse(live.notifications.isEmpty)
    }

    func test_planIsSortedByFireDate() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<5).map { i in
            TaskSnapshot(id: UUID(), scheduleType: everyHr(4), nextDueAt: now + Double((5 - i) * 20 * 60))
        }
        let fire = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
            .notifications.map { $0.fireDate }
        XCTAssertEqual(fire, fire.sorted())
    }

    func test_belowCap_notTrimmedNotCoalesced() {
        // One task's pre + due + full taper stays under the cap → no reduction at all.
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let task = TaskSnapshot(id: taskID1, scheduleType: everyHr(4),
                                nextDueAt: now + 10 * 60, leadTimeMinutes: 5)
        let plan = NotificationPlanner.plan(tasks: [task], settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertFalse(plan.wasTrimmed)
        XCTAssertFalse(plan.planWasCoalesced)
        XCTAssertTrue(plan.notifications.contains { $0.kind == .pre })
        XCTAssertTrue(plan.notifications.contains { $0.kind == .due })
        XCTAssertTrue(plan.notifications.contains { $0.kind == .snooze })
    }

    // MARK: Hard 60-cap invariant (spec §4.3)

    func test_hardCap_neverExceeded_atVariousLoads() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        // With pre-scheduled tapers the baseline is high, so the cap + representation
        // invariants are what matter at every load (grouping timing is load-dependent).
        for n in [0, 59, 60, 61, 120, 500] {
            let tasks = upcomingNoPre(n, now: now, rooms: 7, windows: 24)
            let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
            XCTAssertLessThanOrEqual(plan.notifications.count, 60, "load \(n) exceeded cap")
            XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }), "load \(n) lost a task")
        }
    }

    func test_absurdLoad_500_holdsInvariantAndRepresentsAll() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = upcomingNoPre(500, now: now, rooms: 12, windows: 24)
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
        XCTAssertTrue(plan.planWasCoalesced)
    }

    // MARK: Reduction order a → d

    func test_reductionOrder_preAlertsTrimmedBeforeGrouping() {
        // Grouping is the last escape valve: all pre-alerts (default- then explicit-lead) are
        // trimmed before ANY coalescing — so if the plan coalesced, no pre-alert survives
        // (feedback pass 5 reduction order: tails → default pre → explicit pre → grouping).
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<40).map { i in
            TaskSnapshot(id: UUID(), roomNumber: "R\(i % 6)", scheduleType: everyHr(4),
                         nextDueAt: now + Double((i + 1) * 5 * 60), leadTimeMinutes: 5)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.planWasCoalesced)                                   // this load must group
        XCTAssertFalse(plan.notifications.contains { $0.kind == .pre })        // pre trimmed first
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }

    func test_stepB_reducesSnoozeDepthUniformly_downToFloor() {
        // 12 overdue tasks × 20 pings = 240. Uniform depth reduces to the floor (5) → 60.
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 60
        let tasks = (0..<12).map { _ in
            TaskSnapshot(id: UUID(), scheduleType: everyHr(4), nextDueAt: due)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.count, 60)
        XCTAssertTrue(plan.wasTrimmed)
        XCTAssertFalse(plan.planWasCoalesced)
        XCTAssertTrue(plan.notifications.allSatisfy { $0.kind == .snooze })
        // Uniform depth of exactly 5 pings per task (12 × 5 = 60).
        for task in tasks {
            XCTAssertEqual(plan.notifications.filter { $0.taskID == task.id }.count, 5)
        }
    }

    func test_stepC_coalescesSameRoom_withoutCrossRoom() {
        // 70 tasks all in one room → same-room window grouping is enough (no cross-room).
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        let tasks = (0..<70).map { i -> TaskSnapshot in
            let w = i % 24
            return TaskSnapshot(id: UUID(), roomNumber: "A", scheduleType: everyHr(4),
                                nextDueAt: now + Double(w) * 30 * 60 + 60, leadTimeMinutes: 24 * 60)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertTrue(plan.planWasCoalesced)
        // Every group is same-room "A" — step d (cross-room) was never needed.
        let groups = plan.notifications.compactMap { $0.group }
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.allSatisfy { $0.room == "A" })
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }

    func test_stepD_coalescesCrossRoom_byWindow() {
        // 24 windows × 5 rooms, one task each → no same-room pair exists, so only
        // cross-room window grouping can reduce the plan.
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        var tasks: [TaskSnapshot] = []
        for w in 0..<24 {
            for r in 0..<5 {
                tasks.append(TaskSnapshot(id: UUID(), roomNumber: "R\(r)", scheduleType: everyHr(4),
                                          nextDueAt: now + Double(w) * 30 * 60 + 60, leadTimeMinutes: 24 * 60))
            }
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertTrue(plan.planWasCoalesced)
        let crossRoom = plan.notifications.compactMap { $0.group }.filter { $0.room == nil }
        XCTAssertFalse(crossRoom.isEmpty, "expected at least one cross-room digest")
        // Furthest window (w=23 → 19:30–20:00) is grouped first: 5 tasks, 5 rooms, "by 20:00".
        XCTAssertTrue(plan.notifications.contains {
            $0.group?.title == "5 tasks due · 5 rooms · by 20:00" })
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }

    func test_sameRoomDigest_titleAndMembers() {
        // Three tasks, same room, same window → a same-room digest with a routed title.
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 8, 0)
        // Put them in the furthest window so step c (furthest-first) coalesces them.
        var tasks = (0..<3).map { _ in
            TaskSnapshot(id: UUID(), roomNumber: "422", scheduleType: everyHr(4),
                         nextDueAt: now + 23 * 30 * 60 + 300, leadTimeMinutes: 24 * 60)
        }
        tasks += upcomingNoPre(80, now: now, rooms: 6, windows: 24)   // filler to blow the budget
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        let group422 = plan.notifications.compactMap { $0.group }.first { $0.room == "422" }
        XCTAssertNotNil(group422)
        XCTAssertEqual(group422?.title, "3 tasks due · Rm 422 · next 30 min")
        XCTAssertEqual(group422?.memberTaskIDs.count, 3)
    }
}

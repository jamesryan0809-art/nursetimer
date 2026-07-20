import XCTest
@testable import NurseTimerCore

/// Item 1 (audit finding 2): the planner must guarantee that **every task's due time
/// is represented by at least one notification** at ANY load, and never exceed the cap.
/// These were written fail-first against the pre-fix planner.
final class PlannerRepresentationTests: XCTestCase {

    private let cap = 60

    /// All task ids the plan represents — individually or as a digest member.
    private func represented(_ plan: NotificationPlan) -> Set<UUID> {
        var s = Set<UUID>()
        for n in plan.notifications {
            if let t = n.taskID { s.insert(t) }
            if let g = n.group { g.memberTaskIDs.forEach { s.insert($0) } }
        }
        return s
    }

    // (1) 61+ simultaneously overdue tasks.
    func test_manyOverdue_allRepresented_underCap() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 60   // all 1 min overdue
        let tasks = (0..<61).map { i in
            TaskSnapshot(id: UUID(), roomNumber: "R\(i % 9)", scheduleType: everyHr(4), nextDueAt: due)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, cap)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
        XCTAssertFalse(plan.notifications.isEmpty)   // never empty while tasks are overdue
    }

    // (2) Mixed load: 40 overdue + 30 upcoming.
    func test_mixedLoad_allRepresented_underCap() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        var tasks: [TaskSnapshot] = []
        for i in 0..<40 {
            tasks.append(TaskSnapshot(id: UUID(), roomNumber: "R\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now - Double((i + 1) * 60)))   // overdue
        }
        for i in 0..<30 {
            tasks.append(TaskSnapshot(id: UUID(), roomNumber: "U\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now + Double((i + 1) * 5 * 60)))   // upcoming
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, cap)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }

    // (a) Global escape valve: overdue spread across many rooms AND many historical
    //     30-minute windows (not a single simultaneous burst).
    func test_overdueAcrossManyRoomsAndWindows_allRepresented() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        var tasks: [TaskSnapshot] = []
        // 8 historical windows × 10 rooms = 80 overdue tasks at distinct (room, window).
        for w in 0..<8 {
            for r in 0..<10 {
                let due = now - Double(w * 30 * 60 + 5 * 60)   // w windows back
                tasks.append(TaskSnapshot(id: UUID(), roomNumber: "R\(r)", scheduleType: everyHr(4), nextDueAt: due))
            }
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, cap)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }

    // (b) Combined saturation: repair + overdue + upcoming at high load. Overdue/upcoming
    //     must all be represented in notifications; repair tasks reported (as a list in
    //     item 1; item 2 promotes them to planner payloads).
    func test_combinedSaturation_allCategoriesRepresented() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        var tasks: [TaskSnapshot] = []
        var repairIDs: [UUID] = []
        for i in 0..<20 {
            let id = UUID(); repairIDs.append(id)
            tasks.append(TaskSnapshot(id: id, roomNumber: "X\(i % 5)",
                                      scheduleType: .needsRepair(rawPayload: Data("x".utf8)),
                                      nextDueAt: now - 60))
        }
        for i in 0..<40 {
            tasks.append(TaskSnapshot(id: UUID(), roomNumber: "R\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now - Double((i + 1) * 60)))
        }
        for i in 0..<40 {
            tasks.append(TaskSnapshot(id: UUID(), roomNumber: "U\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now + Double((i + 1) * 5 * 60)))
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, cap)
        let nonRepair = Set(tasks.filter { !$0.scheduleType.isNeedsRepair }.map { $0.id })
        XCTAssertTrue(represented(plan).isSuperset(of: nonRepair))
        XCTAssertEqual(Set(plan.tasksNeedingRepair), Set(repairIDs))
    }

    // Invalid settings must not crash or empty the plan — safe defaults, flagged.
    func test_invalidSettings_useSafeDefaults_andFlag() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 16, 0)
        let now = due + 60
        var bad = SchedulerSettings.default
        bad.maxPlanNotifications = 0     // nonsense
        bad.minSnoozeDepth = -3
        bad.horizonHours = 0
        let tasks = (0..<70).map { i in
            TaskSnapshot(id: UUID(), roomNumber: "R\(i % 9)", scheduleType: everyHr(4), nextDueAt: due)
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: bad, now: now, calendar: cal)
        XCTAssertTrue(plan.settingsAdjusted)
        XCTAssertFalse(plan.notifications.isEmpty)            // never empty while tasks overdue
        XCTAssertLessThanOrEqual(plan.notifications.count, 64)
        XCTAssertEqual(represented(plan), Set(tasks.map { $0.id }))
    }
}

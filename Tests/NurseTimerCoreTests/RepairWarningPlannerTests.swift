import XCTest
@testable import NurseTimerCore

/// Item 2 (audit finding 3): repair warnings are planned by the planner itself — planned
/// FIRST against the cap, exempt from trimming but coalesced into a digest above the
/// threshold so unbounded repair counts can't breach the cap.
final class RepairWarningPlannerTests: XCTestCase {

    private func represented(_ plan: NotificationPlan) -> Set<UUID> {
        var s = Set<UUID>()
        for n in plan.notifications {
            if let t = n.taskID { s.insert(t) }
            if let g = n.group { g.memberTaskIDs.forEach { s.insert($0) } }
        }
        return s
    }

    private func repairTask(_ id: UUID, room: String, now: Date) -> TaskSnapshot {
        TaskSnapshot(id: id, roomNumber: room, scheduleType: .needsRepair(rawPayload: Data("x".utf8)),
                     nextDueAt: now - 60)
    }

    func test_belowThreshold_individualWarnings() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        let ids = (0..<3).map { _ in UUID() }
        let tasks = ids.map { repairTask($0, room: "R", now: now) }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.count, 3)
        XCTAssertTrue(plan.notifications.allSatisfy { $0.kind == .repairWarning })
        XCTAssertEqual(Set(plan.notifications.compactMap { $0.taskID }), Set(ids))
        // Immediate trigger.
        XCTAssertTrue(plan.notifications.allSatisfy { $0.fireDate == now })
    }

    func test_aboveThreshold_singleRepairDigest() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        let ids = (0..<10).map { _ in UUID() }
        let tasks = ids.map { repairTask($0, room: "R", now: now) }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.count, 1)
        let digest = plan.notifications.first?.group
        XCTAssertEqual(digest?.category, .repair)
        XCTAssertEqual(digest?.memberTaskIDs.count, 10)
        XCTAssertEqual(digest?.title, "10 tasks need schedule repair — tap to fix")
        XCTAssertEqual(represented(plan), Set(ids))
    }

    // 61 repair tasks alone -> one digest, <= 60, all represented.
    func test_61RepairAlone_digest_underCap_allRepresented() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        let ids = (0..<61).map { _ in UUID() }
        let tasks = ids.enumerated().map { repairTask($0.element, room: "R\($0.offset % 9)", now: now) }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        XCTAssertEqual(represented(plan), Set(ids))
        XCTAssertEqual(Set(plan.tasksNeedingRepair), Set(ids))
    }

    // Full task load + 5 warnings -> <= 60, every category represented.
    func test_fiveWarnings_plusFullLoad_underCap_allRepresented() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 12, 0)
        var tasks: [TaskSnapshot] = []
        let repairIDs = (0..<5).map { _ in UUID() }
        tasks += repairIDs.map { repairTask($0, room: "X", now: now) }
        var upcomingIDs: [UUID] = [], overdueIDs: [UUID] = []
        for i in 0..<100 {
            let id = UUID(); upcomingIDs.append(id)
            tasks.append(TaskSnapshot(id: id, roomNumber: "U\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now + Double((i + 1) * 5 * 60)))
        }
        for i in 0..<50 {
            let id = UUID(); overdueIDs.append(id)
            tasks.append(TaskSnapshot(id: id, roomNumber: "R\(i % 8)", scheduleType: everyHr(4),
                                      nextDueAt: now - Double((i + 1) * 60)))
        }
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(plan.notifications.count, 60)
        // Repair warnings individual (5), and everything represented.
        XCTAssertEqual(plan.notifications.filter { $0.kind == .repairWarning }.count, 5)
        let everything = Set(repairIDs + upcomingIDs + overdueIDs)
        XCTAssertEqual(represented(plan), everything)
    }
}

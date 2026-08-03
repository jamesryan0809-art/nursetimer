import XCTest
@testable import NurseTimerCore

/// Shift Review discharge (BUILD_SPEC §6.4) soft-archives a patient rather than hard-deleting it,
/// reusing the task-level `isArchived` exclusion so the discharged patient's tasks contribute NO
/// reminders while their records/history survive. This pins the Core exclusion invariant the
/// discharge path relies on: archived tasks are excluded from the plan exactly like paused ones,
/// and only the remaining active tasks are represented.
final class PatientArchiveExclusionTests: XCTestCase {

    private let cal = Calendar(identifier: .gregorian)

    private func dueTask(_ room: String, archived: Bool, dueIn seconds: TimeInterval, now: Date) -> TaskSnapshot {
        TaskSnapshot(
            id: UUID(), roomNumber: room,
            scheduleType: .interval(IntervalMinutes(minutes: 240)!),
            nextDueAt: now.addingTimeInterval(seconds), isArchived: archived)
    }

    func testDischargedPatientsTasksProduceNoNotifications() {
        let now = Date()
        // "Discharged" patient (Rm 400) — all its tasks archived; kept patient (Rm 401) active.
        let discharged = [dueTask("400", archived: true, dueIn: -600, now: now),
                          dueTask("400", archived: true, dueIn: 300, now: now)]
        let kept = dueTask("401", archived: false, dueIn: 120, now: now)

        let plan = NotificationPlanner.plan(
            tasks: discharged + [kept], settings: .default, now: now, calendar: cal)

        let represented = Set(plan.notifications.compactMap { $0.taskID }
            + plan.notifications.flatMap { $0.group?.memberTaskIDs ?? [] })
        XCTAssertTrue(represented.contains(kept.id), "The kept patient's task must still be planned.")
        for t in discharged {
            XCTAssertFalse(represented.contains(t.id), "A discharged patient's tasks must fire nothing.")
        }
    }

    func testAllArchivedYieldsNoTaskNotifications() {
        let now = Date()
        let tasks = [dueTask("400", archived: true, dueIn: -600, now: now),
                     dueTask("400", archived: true, dueIn: 120, now: now)]
        let plan = NotificationPlanner.plan(tasks: tasks, settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.notifications.filter { !$0.isRepair }.isEmpty)
    }
}

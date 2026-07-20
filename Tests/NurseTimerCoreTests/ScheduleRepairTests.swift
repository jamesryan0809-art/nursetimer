import XCTest
@testable import NurseTimerCore

/// Change 3: schedule decoding fails LOUD. An undecodable payload becomes
/// `.needsRepair` (never a silent `.prn`), quarantined per-task, surfaced to the
/// planner, and produces zero reminders until repaired.
final class ScheduleRepairTests: XCTestCase {

    private let id1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    // MARK: Decode fails loud → needsRepair, never PRN

    func test_corruptPayload_decodesToNeedsRepair_neverPRN() {
        let corrupt = Data("this is not a schedule".utf8)
        let schedule = ScheduleType.decode(fromStore: corrupt)
        guard case .needsRepair(let raw) = schedule else {
            return XCTFail("expected .needsRepair, got \(schedule)")
        }
        XCTAssertEqual(raw, corrupt)               // raw bytes preserved for diagnostics
        XCTAssertNotEqual(schedule, .prn)          // the dangerous silent fallback is gone
    }

    func test_outOfRangeIntervalPayload_decodesToNeedsRepair() throws {
        // A structurally-valid interval whose minutes are out of range must NOT come
        // back as a valid interval — IntervalMinutes decode throws → needsRepair.
        // Derive the real on-disk shape from a valid encoding, then tamper the value.
        let validData = try JSONEncoder().encode(everyHr(4))          // 240 minutes
        let str = String(data: validData, encoding: .utf8)!
        XCTAssertTrue(str.contains("240"))
        let tampered = Data(str.replacingOccurrences(of: "240", with: "2").utf8)  // 2 min < floor
        XCTAssertTrue(ScheduleType.decode(fromStore: tampered).isNeedsRepair)
        XCTAssertFalse(ScheduleType.decode(fromStore: validData).isNeedsRepair)   // sanity
    }

    func test_validPayloadsDecodeNormally() throws {
        let cal = utcCalendar()
        for valid in [ScheduleType.prn,
                      everyHr(4),
                      everyMin(30),
                      .once(dt(cal, 2026, 7, 19, 9, 0)),
                      .fixedTimes([time(9, 0), time(21, 0)])] {
            let data = try JSONEncoder().encode(valid)
            let decoded = ScheduleType.decode(fromStore: data)
            XCTAssertEqual(decoded, valid)
            XCTAssertFalse(decoded.isNeedsRepair)
        }
    }

    // MARK: needsRepair itself round-trips stably

    func test_needsRepairRoundTripIsStable() throws {
        let original = ScheduleType.needsRepair(rawPayload: Data("xyz".utf8))
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleType.self, from: data), original)
        XCTAssertEqual(ScheduleType.decode(fromStore: data), original)
    }

    // MARK: Planner — zero notifications, but reported; nextDueAt untrusted

    func test_needsRepair_producesNoNotifications_butAppearsInFlag() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        // Deliberately give it a *future* nextDueAt to prove it is NOT trusted.
        let broken = TaskSnapshot(id: id1,
                                  scheduleType: .needsRepair(rawPayload: Data("bad".utf8)),
                                  nextDueAt: now.addingTimeInterval(30 * 60))
        let plan = NotificationPlanner.plan(tasks: [broken], settings: .default, now: now, calendar: cal)
        // Item 2: a needsRepair task emits exactly one repair WARNING (no task alerts) and
        // is still reported in tasksNeedingRepair. Its untrusted nextDueAt is never used.
        XCTAssertEqual(plan.notifications.count, 1)
        XCTAssertEqual(plan.notifications.first?.kind, .repairWarning)
        XCTAssertEqual(plan.notifications.first?.taskID, id1)
        XCTAssertFalse(plan.notifications.contains { [.pre, .due, .snooze].contains($0.kind) })
        XCTAssertEqual(plan.tasksNeedingRepair, [id1])
    }

    func test_needsRepair_flaggedEvenWhenPaused() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let broken = TaskSnapshot(id: id1,
                                  scheduleType: .needsRepair(rawPayload: Data("bad".utf8)),
                                  nextDueAt: now.addingTimeInterval(30 * 60),
                                  isPaused: true)
        let plan = NotificationPlanner.plan(tasks: [broken], settings: .default, now: now, calendar: cal)
        XCTAssertEqual(plan.notifications.count, 1)
        XCTAssertEqual(plan.notifications.first?.kind, .repairWarning)
        XCTAssertEqual(plan.tasksNeedingRepair, [id1])
    }

    // MARK: One bad task never blocks the rest (quarantine)

    func test_siblingTasksLoadUnaffected() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        let goodID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let broken = TaskSnapshot(id: id1,
                                  scheduleType: .needsRepair(rawPayload: Data("bad".utf8)),
                                  nextDueAt: now.addingTimeInterval(5 * 60))
        let good = TaskSnapshot(id: goodID, scheduleType: everyHr(4),
                                nextDueAt: dt(cal, 2026, 7, 19, 16, 30))   // 30 min out

        let plan = NotificationPlanner.plan(tasks: [broken, good], settings: .default, now: now, calendar: cal)
        // The healthy sibling still schedules its pre + due; the broken one gets a warning.
        let goodKinds = plan.notifications.filter { $0.taskID == goodID }.map { $0.kind }
        XCTAssertTrue(goodKinds.contains(.pre) && goodKinds.contains(.due))
        XCTAssertTrue(plan.notifications.contains { $0.kind == .repairWarning && $0.taskID == id1 })
        XCTAssertEqual(plan.tasksNeedingRepair, [id1])
    }

    // MARK: Repair restores scheduling with a FRESH nextDueAt

    func test_firstDue_perScheduleKind() {
        let cal = utcCalendar()
        let anchor = dt(cal, 2026, 7, 19, 13, 7)
        XCTAssertEqual(SchedulingEngine.firstDue(for: everyHr(4), anchor: anchor, calendar: cal),
                       dt(cal, 2026, 7, 19, 17, 7))
        let onceDate = dt(cal, 2026, 7, 19, 20, 0)
        XCTAssertEqual(SchedulingEngine.firstDue(for: .once(onceDate), anchor: anchor, calendar: cal), onceDate)
        XCTAssertEqual(SchedulingEngine.firstDue(for: .fixedTimes([time(21, 0)]), anchor: anchor, calendar: cal),
                       dt(cal, 2026, 7, 19, 21, 0))
        XCTAssertNil(SchedulingEngine.firstDue(for: .prn, anchor: anchor, calendar: cal))
        XCTAssertNil(SchedulingEngine.firstDue(
            for: .needsRepair(rawPayload: Data()), anchor: anchor, calendar: cal))
    }

    func test_repairedTask_schedulesNormally_andLeavesRepairSet() {
        let cal = utcCalendar()
        let now = dt(cal, 2026, 7, 19, 16, 0)
        // Repair == choose a valid schedule + anchor, compute a fresh nextDueAt.
        let newSchedule = everyHr(4)
        let freshDue = SchedulingEngine.firstDue(for: newSchedule, anchor: now, calendar: cal)!  // 20:00
        let repaired = TaskSnapshot(id: id1, scheduleType: newSchedule, nextDueAt: freshDue)

        let plan = NotificationPlanner.plan(tasks: [repaired], settings: .default, now: now, calendar: cal)
        XCTAssertTrue(plan.tasksNeedingRepair.isEmpty)                // no longer flagged
        XCTAssertTrue(plan.notifications.contains { $0.kind == .pre })
        XCTAssertEqual(plan.notifications.first { $0.kind == .due }?.fireDate, freshDue)  // due at the fresh time
    }

    // MARK: Deterministic repair-warning identifier

    func test_repairWarningIdentifier_deterministicPerTask() {
        XCTAssertEqual(NotificationPlanner.repairWarningIdentifier(taskID: id1),
                       "repair|00000000-0000-0000-0000-0000000000AA")
        XCTAssertEqual(NotificationPlanner.repairWarningIdentifier(taskID: id1),
                       NotificationPlanner.repairWarningIdentifier(taskID: id1))   // stable
        let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        XCTAssertNotEqual(NotificationPlanner.repairWarningIdentifier(taskID: id1),
                          NotificationPlanner.repairWarningIdentifier(taskID: other))
    }
}

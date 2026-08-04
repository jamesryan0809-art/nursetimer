import XCTest
@testable import NurseTimerCore

/// Sync snapshot/action schema (BUILD_SPEC §5.3): versioning, round-trip fidelity, corrupt-
/// schedule quarantine parity, planner reuse, and conflict ordering.
final class SyncModelsTests: XCTestCase {

    private let taskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let cal = Calendar(identifier: .gregorian)

    private func makeTask(schedule: ScheduleType, nextDue: Date?) -> SyncTask {
        let data = (try? JSONEncoder().encode(schedule)) ?? Data()
        return SyncTask(
            id: taskID, room: "412B", firstName: "Maria", title: "Metoprolol", dosage: "25 mg PO",
            route: "PO", kind: .medication, scheduleData: data, lastCompletedAt: nil, nextDueAt: nextDue,
            leadTimeMinutes: nil, snoozeMinutes: nil, isPaused: false, notificationsEnabled: true,
            isArchived: false, explicitSnoozeAt: nil, colorTagRaw: "none", prnFrequencyText: "")
    }

    // MARK: Round-trip + versioning

    func testSnapshotRoundTrips() throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let snap = SyncSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_799_000_000),
            tasks: [makeTask(schedule: .interval(IntervalMinutes(minutes: 240)!), nextDue: due)],
            privacyMode: true, settings: .default)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(SyncSnapshot.self, from: data)
        XCTAssertEqual(back, snap)
        XCTAssertEqual(back.schemaVersion, SyncSchema.currentVersion)
        XCTAssertFalse(back.isNewerThanSupported)
    }

    func testNewerSchemaVersionIsFlaggedNotCrashed() {
        let snap = SyncSnapshot(generatedAt: Date(), tasks: [], privacyMode: true,
                                settings: .default, schemaVersion: SyncSchema.currentVersion + 1)
        XCTAssertTrue(snap.isNewerThanSupported,
                      "A snapshot from a newer app must be flagged so the watch shows an update state.")
    }

    // MARK: Corrupt-schedule quarantine parity

    func testCorruptScheduleDataQuarantinesToNeedsRepair() {
        // Garbage bytes must decode to .needsRepair on the watch exactly as on the phone —
        // never a silent coercion to a valid-looking schedule.
        let task = SyncTask(
            id: taskID, room: "1", firstName: nil, title: "x", dosage: nil, route: nil,
            kind: .medication, scheduleData: Data([0xDE, 0xAD, 0xBE, 0xEF]), lastCompletedAt: nil,
            nextDueAt: nil, leadTimeMinutes: nil, snoozeMinutes: nil, isPaused: false,
            notificationsEnabled: true, isArchived: false, explicitSnoozeAt: nil,
            colorTagRaw: "none", prnFrequencyText: "")
        XCTAssertTrue(task.scheduleType.isNeedsRepair)
        XCTAssertTrue(task.schedulable.scheduleType.isNeedsRepair)
    }

    // MARK: Planner reuse

    func testSnapshotSchedulablesFeedTheSharedPlanner() {
        let due = Date().addingTimeInterval(60)   // due in ~1 min
        let snap = SyncSnapshot(
            generatedAt: Date(),
            tasks: [makeTask(schedule: .interval(IntervalMinutes(minutes: 240)!), nextDue: due)],
            privacyMode: true, settings: .default)
        let plan = NotificationPlanner.plan(
            tasks: snap.schedulables, settings: snap.settings, now: Date(), calendar: cal)
        // The watch plan must represent the due task with the SAME deterministic identifier the
        // phone would emit for that (taskID, due, .due) — dedup across devices depends on it.
        let expected = NotificationPlanner.identifier(taskID: taskID, due: due, slot: .due)
        XCTAssertTrue(plan.notifications.contains { $0.identifier == expected })
    }

    // MARK: Conflict ordering (§5.3)

    func testGivenSupersedesSnoozeAtEqualTimestamp() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let snooze = SyncAction(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                taskID: taskID, kind: .snooze, timestamp: t)
        let given = SyncAction(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                               taskID: taskID, kind: .given, timestamp: t)
        // Pass in the "wrong" order to prove the resolver reorders, not just preserves input.
        let ordered = SyncConflictResolver.applicationOrder([given, snooze])
        XCTAssertEqual(ordered.map(\.kind), [.snooze, .given],
                       "At an equal timestamp the Given must apply LAST so it wins.")
    }

    func testLastActionWinsByTimestamp() {
        let early = SyncAction(taskID: taskID, kind: .given, timestamp: Date(timeIntervalSince1970: 100))
        let late  = SyncAction(taskID: taskID, kind: .snooze, timestamp: Date(timeIntervalSince1970: 200))
        let ordered = SyncConflictResolver.applicationOrder([late, early])
        XCTAssertEqual(ordered.map(\.timestamp), [early.timestamp, late.timestamp])
    }
}

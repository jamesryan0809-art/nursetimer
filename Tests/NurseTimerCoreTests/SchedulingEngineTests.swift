import XCTest
@testable import NurseTimerCore

final class SchedulingEngineTests: XCTestCase {

    // MARK: Interval anchoring (spec §4.1, acceptance §10)

    func test_interval_anchorsToActualGivenTime_q4hGiven1307DueAt1707() {
        let cal = utcCalendar()
        let given = dt(cal, 2026, 7, 19, 13, 7)
        let next = SchedulingEngine.nextDueAfterCompletion(
            schedule: everyHr(4), completedAt: given, calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 19, 17, 7))
    }

    func test_interval_lateDose_shiftsNextDoseToActualTime() {
        // Due 17:00 but actually given 17:45 → next due 21:45, not 21:00 (spec §6.5).
        let cal = utcCalendar()
        let givenLate = dt(cal, 2026, 7, 19, 17, 45)
        let next = SchedulingEngine.nextDueAfterCompletion(
            schedule: everyHr(4), completedAt: givenLate, calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 19, 21, 45))
    }

    func test_interval_fractionalHours_q6h() {
        let cal = utcCalendar()
        let given = dt(cal, 2026, 7, 19, 8, 0)
        let next = SchedulingEngine.nextDueAfterCompletion(
            schedule: everyHr(6), completedAt: given, calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 19, 14, 0))
    }

    // MARK: Fixed times + midnight crossing (spec §4.1 / §8)

    func test_fixedTimes_picksNextTimeLaterToday() {
        let cal = utcCalendar()
        let ref = dt(cal, 2026, 7, 19, 8, 0)
        let next = SchedulingEngine.nextFixedTime(
            after: ref, times: [time(9, 0), time(21, 0)], calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 19, 9, 0))
    }

    func test_fixedTimes_crossesMidnightToNextDay() {
        let cal = utcCalendar()
        let ref = dt(cal, 2026, 7, 19, 22, 0)   // after both of today's times
        let next = SchedulingEngine.nextFixedTime(
            after: ref, times: [time(9, 0), time(21, 0)], calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 20, 9, 0))
    }

    func test_fixedTimes_isStrictlyAfterReference() {
        // Exactly at 21:00 must roll to the next occurrence, not return 21:00.
        let cal = utcCalendar()
        let ref = dt(cal, 2026, 7, 19, 21, 0)
        let next = SchedulingEngine.nextFixedTime(
            after: ref, times: [time(9, 0), time(21, 0)], calendar: cal)
        XCTAssertEqual(next, dt(cal, 2026, 7, 20, 9, 0))
    }

    func test_fixedTimes_empty_returnsNil() {
        XCTAssertNil(SchedulingEngine.nextFixedTime(
            after: Date(timeIntervalSince1970: 0), times: [], calendar: utcCalendar()))
    }

    // MARK: .once auto-pause & PRN (spec §4.1)

    func test_once_returnsNilAndAutoPauses() {
        let cal = utcCalendar()
        let fireAt = dt(cal, 2026, 7, 19, 10, 0)
        XCTAssertNil(SchedulingEngine.nextDueAfterCompletion(
            schedule: .once(fireAt), completedAt: fireAt, calendar: cal))
        XCTAssertTrue(SchedulingEngine.shouldAutoPauseAfterCompletion(.once(fireAt)))
    }

    func test_interval_andPRN_doNotAutoPause() {
        XCTAssertFalse(SchedulingEngine.shouldAutoPauseAfterCompletion(everyHr(4)))
        XCTAssertFalse(SchedulingEngine.shouldAutoPauseAfterCompletion(.prn))
    }

    func test_prn_neverAutoSchedules() {
        let cal = utcCalendar()
        XCTAssertNil(SchedulingEngine.nextDueAfterCompletion(
            schedule: .prn, completedAt: dt(cal, 2026, 7, 19, 12, 0), calendar: cal))
    }

    // MARK: Effective overrides (spec §3.2 / §3.4)

    func test_effectiveLeadAndSnooze_useOverrideThenDefault() {
        let s = SchedulerSettings.default   // lead 15, snooze 3
        let withOverride = TaskSnapshot(scheduleType: .prn, leadTimeMinutes: 30, snoozeMinutes: 5)
        let noOverride = TaskSnapshot(scheduleType: .prn)
        XCTAssertEqual(SchedulingEngine.effectiveLeadMinutes(withOverride, s), 30)
        XCTAssertEqual(SchedulingEngine.effectiveSnoozeMinutes(withOverride, s), 5)
        XCTAssertEqual(SchedulingEngine.effectiveLeadMinutes(noOverride, s), 15)
        XCTAssertEqual(SchedulingEngine.effectiveSnoozeMinutes(noOverride, s), 3)
    }

    func test_preAlertDate_isDueMinusLead() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 17, 7)
        XCTAssertEqual(SchedulingEngine.preAlertDate(due: due, leadMinutes: 15),
                       dt(cal, 2026, 7, 19, 16, 52))   // acceptance §10
    }

    // MARK: Snooze chains (spec §4.2)

    func test_snoozeChain_freshOverdue_startsAtDuePlusS() {
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 17, 7)
        // now == due (just went overdue). First ping at D+3, chain of 20.
        let chain = SchedulingEngine.snoozeChain(anchor: due, snoozeMinutes: 3, after: due, count: 20)
        XCTAssertEqual(chain.count, 20)
        XCTAssertEqual(chain.first?.index, 1)
        XCTAssertEqual(chain.first?.date, due.addingTimeInterval(3 * 60))
        XCTAssertEqual(chain.last?.index, 20)
        XCTAssertEqual(chain.last?.date, due.addingTimeInterval(20 * 3 * 60))
        // Strictly increasing, contiguous indices.
        for (i, ping) in chain.enumerated() { XCTAssertEqual(ping.index, i + 1) }
    }

    func test_snoozeChain_defaultChangeFrom3To5_widensSpacing() {
        // "changing the global default to 5 changes new chains to 5" (acceptance §10).
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 17, 7)
        let chain = SchedulingEngine.snoozeChain(anchor: due, snoozeMinutes: 5, after: due, count: 3)
        XCTAssertEqual(chain.map { $0.date }, [
            due.addingTimeInterval(5 * 60),
            due.addingTimeInterval(10 * 60),
            due.addingTimeInterval(15 * 60),
        ])
    }

    func test_snoozeChain_explicitSnooze_reAnchorsToNow() {
        // Explicit Snooze: new chain starts at now + S (spec §4.2 step 4).
        let cal = utcCalendar()
        let tappedAt = dt(cal, 2026, 7, 19, 18, 0)
        let chain = SchedulingEngine.snoozeChain(anchor: tappedAt, snoozeMinutes: 3, after: tappedAt, count: 20)
        XCTAssertEqual(chain.first?.date, tappedAt.addingTimeInterval(3 * 60))
        XCTAssertEqual(chain.count, 20)
    }

    func test_snoozeChain_longOverdue_slidesWindowForwardAndStaysFull() {
        // Auto-extension (spec §4.2 step 3): a task overdue by 100 min still yields
        // a full 20-ping buffer, all strictly in the future.
        let cal = utcCalendar()
        let due = dt(cal, 2026, 7, 19, 17, 0)
        let now = due.addingTimeInterval(100 * 60)   // 100 min overdue, S = 3
        let chain = SchedulingEngine.snoozeChain(anchor: due, snoozeMinutes: 3, after: now, count: 20)
        XCTAssertEqual(chain.count, 20)
        // Smallest k with due + 3k min > 100 min → 3k > 100 → k = 34.
        XCTAssertEqual(chain.first?.index, 34)
        XCTAssertEqual(chain.first?.date, due.addingTimeInterval(34 * 3 * 60))
        for ping in chain { XCTAssertGreaterThan(ping.date, now) }
    }

    func test_snoozeChain_zeroCountOrInterval_returnsEmpty() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(SchedulingEngine.snoozeChain(anchor: now, snoozeMinutes: 3, after: now, count: 0).isEmpty)
        XCTAssertTrue(SchedulingEngine.snoozeChain(anchor: now, snoozeMinutes: 0, after: now, count: 20).isEmpty)
    }

    // MARK: DST (spec §8)

    func test_interval_acrossSpringForward_isAbsoluteOffset() {
        // America/New_York springs forward 2026-03-08 02:00 → 03:00.
        // 01:30 EST + 4h REAL time = 06:30 EDT (clock jumps an hour), but the
        // absolute offset is exactly 4h — interval meds are unaffected by DST.
        let cal = nyCalendar()
        let given = dt(cal, 2026, 3, 8, 1, 30)
        let next = SchedulingEngine.nextDueAfterCompletion(
            schedule: everyHr(4), completedAt: given, calendar: cal)!
        XCTAssertEqual(next.timeIntervalSince(given), 4 * 3600, accuracy: 0.5)
        let comps = at(cal, next)
        XCTAssertEqual(comps.hour, 6)
        XCTAssertEqual(comps.minute, 30)
    }

    func test_fixedTime_acrossSpringForward_followsWallClock() {
        // A 09:00 fixed dose lands at 09:00 wall-clock even on the DST day.
        let cal = nyCalendar()
        let ref = dt(cal, 2026, 3, 8, 0, 30)
        let next = SchedulingEngine.nextFixedTime(after: ref, times: [time(9, 0)], calendar: cal)!
        XCTAssertEqual(at(cal, next).hour, 9)
        XCTAssertEqual(at(cal, next).minute, 0)
    }
}

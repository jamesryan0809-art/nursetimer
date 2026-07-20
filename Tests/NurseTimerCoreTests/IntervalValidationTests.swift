import XCTest
@testable import NurseTimerCore

/// Change 2: interval intervals validated at the type level — non-positive and
/// nonsense values are unrepresentable; unit is minutes so q30min is legitimate.
final class IntervalValidationTests: XCTestCase {

    // MARK: Rejection

    func test_rejectsNonPositiveAndOutOfRange() {
        XCTAssertNil(IntervalMinutes(minutes: 0))            // zero
        XCTAssertNil(IntervalMinutes(minutes: -30))          // negative
        XCTAssertNil(IntervalMinutes(minutes: 4))            // sub-5-minute
        XCTAssertNil(IntervalMinutes(minutes: 24 * 60 + 1))  // > 24h
    }

    func test_acceptsWithinBounds() {
        XCTAssertEqual(IntervalMinutes(minutes: 5)?.minutes, 5)        // floor
        XCTAssertEqual(IntervalMinutes(minutes: 30)?.minutes, 30)      // q30min
        XCTAssertEqual(IntervalMinutes(minutes: 240)?.minutes, 240)    // q4h
        XCTAssertEqual(IntervalMinutes(minutes: 24 * 60)?.minutes, 1440) // ceiling
    }

    func test_hoursMinutesInit() {
        XCTAssertNil(IntervalMinutes(hours: 25))                       // > 24h
        XCTAssertNil(IntervalMinutes(hours: 0, minutes: 4))            // sub-5
        XCTAssertEqual(IntervalMinutes(hours: 24)?.minutes, 1440)
        XCTAssertEqual(IntervalMinutes(hours: 0, minutes: 30)?.minutes, 30)
        XCTAssertEqual(IntervalMinutes(hours: 4)?.minutes, 240)
    }

    func test_everyFactory() {
        XCTAssertNotNil(ScheduleType.every(hours: 4))
        XCTAssertNil(ScheduleType.every(minutes: 0))
        XCTAssertNil(ScheduleType.every(hours: 25))
        XCTAssertNil(ScheduleType.every(minutes: 4))
        guard case .interval(let iv)? = ScheduleType.every(minutes: 30) else { return XCTFail("expected interval") }
        XCTAssertEqual(iv.minutes, 30)
    }

    func test_accessors() {
        XCTAssertEqual(IntervalMinutes(minutes: 240)!.timeInterval, 240 * 60)
        XCTAssertEqual(IntervalMinutes(minutes: 30)!.hours, 0.5, accuracy: 1e-9)
    }

    // MARK: Scheduling with the new unit

    func test_thirtyMinuteIntervalSchedules() {
        let cal = utcCalendar()
        let given = dt(cal, 2026, 7, 19, 8, 0)
        XCTAssertEqual(
            SchedulingEngine.nextDueAfterCompletion(schedule: everyMin(30), completedAt: given, calendar: cal),
            dt(cal, 2026, 7, 19, 8, 30))
    }

    func test_fourHourIntervalStillWorks() {
        let cal = utcCalendar()
        let given = dt(cal, 2026, 7, 19, 13, 7)
        XCTAssertEqual(
            SchedulingEngine.nextDueAfterCompletion(schedule: everyHr(4), completedAt: given, calendar: cal),
            dt(cal, 2026, 7, 19, 17, 7))
    }

    // MARK: Codable re-validates

    func test_intervalCodableRoundTripAsBareInt() throws {
        let iv = IntervalMinutes(minutes: 240)!
        let data = try JSONEncoder().encode(iv)
        XCTAssertEqual(String(data: data, encoding: .utf8), "240")     // bare int
        XCTAssertEqual(try JSONDecoder().decode(IntervalMinutes.self, from: data), iv)
    }

    func test_intervalDecodeRejectsOutOfRange() {
        XCTAssertThrowsError(try JSONDecoder().decode(IntervalMinutes.self, from: Data("2".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(IntervalMinutes.self, from: Data("1441".utf8)))
    }

    func test_scheduleTypeIntervalRoundTrip() throws {
        let s = ScheduleType.interval(IntervalMinutes(minutes: 30)!)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ScheduleType.self, from: data), s)
    }
}

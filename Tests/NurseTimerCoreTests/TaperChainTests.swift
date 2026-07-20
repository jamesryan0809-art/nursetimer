import XCTest
@testable import NurseTimerCore

/// Item 3: the tapered post-due chain (Phase 1 at S, Phase 2 at 15m, Phase 3 at 30m),
/// a pure function of (anchor, S, now, horizon, settings).
final class TaperChainTests: XCTestCase {

    private let settings = SchedulerSettings.default   // fast 5, mid 15/5, slow 30

    func test_phases_fromDueTime() {
        let cal = utcCalendar()
        let d = dt(cal, 2026, 7, 19, 12, 0)
        let horizon = d.addingTimeInterval(12 * 3600)
        let chain = SchedulingEngine.taperChain(anchor: d, snoozeMinutes: 3, after: d, until: horizon, settings: settings)
        let dates = chain.map { $0.date }
        // Phase 1: 5 pings at 3 min.
        XCTAssertEqual(Array(dates.prefix(5)), (1...5).map { d.addingTimeInterval(Double($0) * 3 * 60) })
        // Phase 2: 5 pings at 15 min after +15.
        let base1 = d.addingTimeInterval(15 * 60)
        XCTAssertEqual(Array(dates[5..<10]), (1...5).map { base1.addingTimeInterval(Double($0) * 15 * 60) })
        // Phase 3: 30 min spacing.
        let base2 = base1.addingTimeInterval(75 * 60)
        XCTAssertEqual(dates[10], base2.addingTimeInterval(30 * 60))
        XCTAssertEqual(dates[11], base2.addingTimeInterval(60 * 60))
        // Indices are 1-based from the anchor.
        XCTAssertEqual(chain.first?.index, 1)
        XCTAssertEqual(chain[10].index, 11)
    }

    func test_threeHoursOverdue_S3_exactTimes() {
        let cal = utcCalendar()
        let d = dt(cal, 2026, 7, 19, 12, 0)
        let now = d.addingTimeInterval(180 * 60)   // 3h overdue
        let horizon = now.addingTimeInterval(12 * 3600)
        let chain = SchedulingEngine.taperChain(anchor: d, snoozeMinutes: 3, after: now, until: horizon, settings: settings)
        // Phases 1 & 2 elapsed; the next pings are the 30-min slow phase.
        // Absolute times: …, D+150, D+180 (==now, excluded), D+210, D+240, D+270…
        XCTAssertEqual(Array(chain.prefix(3)).map { $0.date },
                       [210, 240, 270].map { d.addingTimeInterval(Double($0) * 60) })
        XCTAssertEqual(chain.first?.index, 14)   // stable absolute index
        XCTAssertTrue(chain.allSatisfy { $0.date > now })
    }

    func test_explicitSnooze_reAnchorsToPhase1FromTap() {
        let cal = utcCalendar()
        let d = dt(cal, 2026, 7, 19, 12, 0)
        let tap = d.addingTimeInterval(40 * 60)    // snoozed 40 min after due
        let horizon = tap.addingTimeInterval(12 * 3600)
        let chain = SchedulingEngine.taperChain(anchor: tap, snoozeMinutes: 3, after: tap, until: horizon, settings: settings)
        XCTAssertEqual(chain.first?.index, 1)                       // restarts at Phase 1
        XCTAssertEqual(chain.first?.date, tap.addingTimeInterval(3 * 60))
    }

    func test_respectsHorizon() {
        let cal = utcCalendar()
        let d = dt(cal, 2026, 7, 19, 12, 0)
        let horizon = d.addingTimeInterval(20 * 60)   // only Phase 1 fits
        let chain = SchedulingEngine.taperChain(anchor: d, snoozeMinutes: 3, after: d, until: horizon, settings: settings)
        XCTAssertTrue(chain.allSatisfy { $0.date <= horizon })
        XCTAssertEqual(chain.count, 5)   // D+3..D+15
    }

    func test_zeroSnooze_isEmpty() {
        let cal = utcCalendar()
        let d = dt(cal, 2026, 7, 19, 12, 0)
        XCTAssertTrue(SchedulingEngine.taperChain(anchor: d, snoozeMinutes: 0, after: d,
                                                  until: d.addingTimeInterval(3600), settings: settings).isEmpty)
    }
}

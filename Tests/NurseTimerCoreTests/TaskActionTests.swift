import XCTest
@testable import NurseTimerCore

/// Covers the `.paused` TaskAction added for the in-app Pause action (Core change,
/// flagged in the report).
final class TaskActionTests: XCTestCase {

    func test_pausedRawValueIsStable() {
        XCTAssertEqual(TaskAction.paused.rawValue, "paused")
        XCTAssertEqual(TaskAction(rawValue: "paused"), .paused)
    }

    func test_pausedCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(TaskAction.paused)
        XCTAssertEqual(try JSONDecoder().decode(TaskAction.self, from: data), .paused)
    }

    func test_pausedIsDistinctFromOtherActions() {
        let others: [TaskAction] = [.given, .done, .skipped, .snoozed, .missedAcknowledged]
        XCTAssertFalse(others.contains(.paused))
    }

    // Undo support (feedback pass 4, item 4): .resumed + .undone.

    func test_resumedAndUndone_rawValuesAreStable() {
        XCTAssertEqual(TaskAction.resumed.rawValue, "resumed")
        XCTAssertEqual(TaskAction.undone.rawValue, "undone")
        XCTAssertEqual(TaskAction(rawValue: "resumed"), .resumed)
        XCTAssertEqual(TaskAction(rawValue: "undone"), .undone)
    }

    func test_resumedAndUndone_codableRoundTrip() throws {
        for action in [TaskAction.resumed, .undone] {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(TaskAction.self, from: data), action)
        }
    }

    func test_allActionsDistinct() {
        let all: [TaskAction] = [.given, .done, .skipped, .snoozed, .missedAcknowledged, .paused, .resumed, .undone]
        XCTAssertEqual(Set(all).count, all.count)
    }
}

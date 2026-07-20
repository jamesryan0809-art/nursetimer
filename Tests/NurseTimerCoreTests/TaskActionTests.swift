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
}

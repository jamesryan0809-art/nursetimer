import XCTest
@testable import NurseTimerCore

/// TaskKind round-trip + distinctness, incl. the `.reminder` addition (feedback pass 4, item 3).
final class TaskKindTests: XCTestCase {

    func test_rawValuesAreStable() {
        XCTAssertEqual(TaskKind.medication.rawValue, "medication")
        XCTAssertEqual(TaskKind.generic.rawValue, "generic")
        XCTAssertEqual(TaskKind.reminder.rawValue, "reminder")
    }

    func test_reminderCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(TaskKind.reminder)
        XCTAssertEqual(try JSONDecoder().decode(TaskKind.self, from: data), .reminder)
    }

    func test_allKindsDistinct() {
        XCTAssertEqual(Set([TaskKind.medication, .generic, .reminder]).count, 3)
    }

    func test_unknownRawValueIsNil_soModelCanFallBack() {
        // The SwiftData bridge maps an unknown stored raw value to `.generic`; here we assert the
        // enum itself rejects unknown values (the fallback lives in the model layer).
        XCTAssertNil(TaskKind(rawValue: "surgery"))
    }
}

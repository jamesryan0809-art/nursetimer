import Foundation
import SwiftUI
import NurseTimerCore

/// Watch-facing display model (built on Foundation + Core value types only — the Watch
/// UI never touches phone persistence internals).
struct WatchTask: Identifiable, Sendable, Hashable {
    let id: UUID
    let room: String
    let firstName: String?
    let title: String
    let dosage: String?
    let kind: TaskKind          // Core type
    let dueDate: Date?

    var isMedication: Bool { kind == .medication }

    func urgency(now: Date = .now, leadMinutes: Int = 15) -> WatchUrgency {
        guard let dueDate else { return .upcoming }
        if dueDate <= now { return .overdue }
        if dueDate <= now.addingTimeInterval(Double(leadMinutes) * 60) { return .dueSoon }
        return .upcoming
    }

    var dueText: String {
        guard let dueDate else { return "PRN" }
        let delta = dueDate.timeIntervalSinceNow
        let mins = Int(abs(delta) / 60)
        if delta < 0 { return mins < 60 ? "\(mins) min overdue" : dueDate.formatted(date: .omitted, time: .shortened) }
        return mins < 60 ? "in \(mins) min" : dueDate.formatted(date: .omitted, time: .shortened)
    }
}

enum WatchUrgency: Int, Comparable {
    case overdue = 0, dueSoon = 1, upcoming = 2
    static func < (a: WatchUrgency, b: WatchUrgency) -> Bool { a.rawValue < b.rawValue }
    var color: Color {
        switch self { case .overdue: .red; case .dueSoon: .orange; case .upcoming: .primary }
    }
}

/// Connection state to the paired iPhone.
enum SyncState: Equatable {
    case notSynced
    case syncing
    case synced(Date)
}

struct WatchSnapshot: Sendable {
    var tasks: [WatchTask]
    var generatedAt: Date?
    static let empty = WatchSnapshot(tasks: [], generatedAt: nil)
}

/// Actions a nurse takes on the watch, destined for the phone (source of truth).
enum WatchAction: Sendable {
    case given(UUID)
    case snooze(UUID)
    case skip(UUID, reason: String?)
}

/// The eventual phone↔watch channel. Production implementation (WatchConnectivity)
/// is a LATER milestone; this pass ships only the abstraction + a stub.
protocol SyncTransport: AnyObject {
    var state: SyncState { get }
    var snapshot: WatchSnapshot { get }
    var onChange: (() -> Void)? { get set }
    func refresh()
    func send(_ action: WatchAction)
}

/// A no-op / in-memory `SyncTransport`. It performs **no networking**, makes **no
/// `WCSession` calls**, and never claims to be synced — the phone link does not exist
/// yet. It supplies sample data for previews and an honest "not synced" demo, and
/// applies actions to its local snapshot only (so the UI responds) without sending
/// anything anywhere.
final class StubSyncTransport: SyncTransport {
    private(set) var state: SyncState
    private(set) var snapshot: WatchSnapshot
    var onChange: (() -> Void)?

    init(state: SyncState = .notSynced, snapshot: WatchSnapshot = .empty) {
        self.state = state
        self.snapshot = snapshot
    }

    func refresh() {
        // No real transport: this never transitions to `.synced`. WatchConnectivity
        // will replace this in a later milestone.
        onChange?()
    }

    func send(_ action: WatchAction) {
        // Optimistic LOCAL update only — explicitly not transmitted to the phone.
        switch action {
        case .given(let id), .skip(let id, _):
            snapshot.tasks.removeAll { $0.id == id }
        case .snooze:
            break   // a real transport would push the snooze to the phone
        }
        onChange?()
    }

    /// Sample data for SwiftUI previews and the honest "not synced · sample data" demo.
    static func sample() -> StubSyncTransport {
        StubSyncTransport(state: .notSynced,
                          snapshot: WatchSnapshot(tasks: WatchTask.samples, generatedAt: nil))
    }
}

extension WatchTask {
    static let samples: [WatchTask] = [
        WatchTask(id: UUID(), room: "412B", firstName: "Maria", title: "Metoprolol",
                  dosage: "25 mg PO", kind: .medication, dueDate: Date().addingTimeInterval(-8 * 60)),
        WatchTask(id: UUID(), room: "414", firstName: nil, title: "Vitals",
                  dosage: nil, kind: .generic, dueDate: Date().addingTimeInterval(6 * 60)),
        WatchTask(id: UUID(), room: "409", firstName: "Sam", title: "Insulin",
                  dosage: "6 units SC", kind: .medication, dueDate: Date().addingTimeInterval(40 * 60)),
    ]
}

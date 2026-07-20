import Foundation
import Observation

/// Watch presentation state, built on the `SyncTransport` abstraction (never coupled
/// to phone persistence). Sorts by urgency: OVERDUE → DUE≤15m → upcoming.
@MainActor
@Observable
final class WatchModel {
    private let transport: SyncTransport
    var snapshot: WatchSnapshot
    var state: SyncState

    init(transport: SyncTransport) {
        self.transport = transport
        self.snapshot = transport.snapshot
        self.state = transport.state
        transport.onChange = { [weak self] in self?.pull() }
    }

    private func pull() {
        snapshot = transport.snapshot
        state = transport.state
    }

    func refresh() { transport.refresh() }

    var isSynced: Bool { if case .synced = state { return true }; return false }

    var sortedTasks: [WatchTask] {
        snapshot.tasks.sorted { a, b in
            let ua = a.urgency(), ub = b.urgency()
            if ua != ub { return ua < ub }
            return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
        }
    }

    var overdueCount: Int { snapshot.tasks.filter { $0.urgency() == .overdue }.count }

    func given(_ task: WatchTask)    { transport.send(.given(task.id)) }
    func snooze(_ task: WatchTask)   { transport.send(.snooze(task.id)) }
    func skipOnce(_ task: WatchTask) { transport.send(.skipOnce(task.id)) }
    func pause(_ task: WatchTask)    { transport.send(.pause(task.id)) }
}

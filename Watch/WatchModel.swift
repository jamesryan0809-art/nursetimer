import Foundation
import Observation

/// Watch presentation state, built on the `SyncTransport` abstraction (never coupled to phone
/// persistence). Sorts by urgency: OVERDUE → DUE≤15m → upcoming.
@MainActor
@Observable
final class WatchModel {
    private let transport: SyncTransport
    var snapshot: WatchSnapshot
    var state: SyncState

    /// A snapshot older than this reads as stale (item 2) — the phone likely hasn't pushed in a
    /// while (backgrounded / out of range).
    static let staleThreshold: TimeInterval = 2 * 3600

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

    /// The phone sent a newer schema than this build understands — show an "update the app" state.
    var needsAppUpdate: Bool { state == .needsUpdate }

    /// True when we have a real snapshot but it's old, or the phone is currently unreachable.
    func isStale(now: Date = .now) -> Bool {
        guard isSynced else { return false }
        if transport.phoneUnreachable { return true }
        guard let generatedAt = snapshot.generatedAt else { return false }
        return now.timeIntervalSince(generatedAt) > Self.staleThreshold
    }

    var lastSyncedAt: Date? { snapshot.generatedAt }

    /// A row with an unconfirmed local action (§5.3) — the view shows a subtle pending mark.
    func isPending(_ task: WatchTask) -> Bool { transport.pendingTaskIDs.contains(task.id) }

    /// Active, actionable rows for the Now list — parity with the phone Board: paused, completed-
    /// terminal, and needs-repair tasks don't clutter the "what to do now" list.
    var sortedTasks: [WatchTask] {
        snapshot.tasks
            .filter { $0.status != .paused && $0.status != .completed && $0.status != .needsRepair }
            .sorted { a, b in
                let ua = a.urgency(), ub = b.urgency()
                if ua != ub { return ua < ub }
                return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
            }
    }

    var overdueCount: Int { snapshot.tasks.filter { $0.status == .overdue }.count }

    func given(_ task: WatchTask)    { transport.send(.given(task.id)) }
    func snooze(_ task: WatchTask)   { transport.send(.snooze(task.id)) }
    func skipOnce(_ task: WatchTask) { transport.send(.skipOnce(task.id)) }
}

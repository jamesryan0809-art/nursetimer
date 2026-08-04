import Foundation
import SwiftUI
import NurseTimerCore
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - Watch presentation model (built on Core value types only)

/// Status parity with the phone's `TaskStatus` (spec §7), derived on the watch from the synced
/// `SyncTask`. Color stays status-only.
enum WatchStatus {
    case needsRepair, overdue, dueSoon, upcoming, paused, prn, unscheduled, completed

    var color: Color {
        switch self {
        case .needsRepair, .overdue: return .red
        case .dueSoon:               return .orange
        case .upcoming:              return .primary
        case .paused, .prn, .unscheduled: return .secondary
        case .completed:             return .green
        }
    }
    /// Overdue / repair — the row is pinned and colored for attention.
    var isAttention: Bool { self == .overdue || self == .needsRepair }
}

/// Watch-facing display row. Carries the fields the Now view / detail need for phone-parity
/// rendering (status color, muted badge, color tag, PRN last-given), built from the synced
/// `SyncTask`. Foundation/Core only — never touches phone persistence.
struct WatchTask: Identifiable, Sendable, Hashable {
    let id: UUID
    let room: String
    let firstName: String?
    let title: String
    let dosage: String?
    let kind: TaskKind
    let dueDate: Date?
    let status: WatchStatus
    let isMuted: Bool
    let colorTagRaw: String
    let lastCompletedAt: Date?
    let prnFrequencyText: String

    var isMedication: Bool { kind == .medication }
    var isPRN: Bool { status == .prn }
    var isUnscheduled: Bool { status == .unscheduled }

    static func == (a: WatchTask, b: WatchTask) -> Bool { a.id == b.id && a.dueDate == b.dueDate && a.status == b.status }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func urgency(now: Date = .now, leadMinutes: Int = 15) -> WatchUrgency {
        guard let dueDate else { return .upcoming }
        if dueDate <= now { return .overdue }
        if dueDate <= now.addingTimeInterval(Double(leadMinutes) * 60) { return .dueSoon }
        return .upcoming
    }

    var dueText: String {
        guard let dueDate else { return isUnscheduled ? "No time" : "PRN" }
        let delta = dueDate.timeIntervalSinceNow
        let mins = Int(abs(delta) / 60)
        if delta < 0 { return mins < 60 ? "\(mins) min overdue" : dueDate.formatted(date: .omitted, time: .shortened) }
        return mins < 60 ? "in \(mins) min" : dueDate.formatted(date: .omitted, time: .shortened)
    }

    /// Build from a synced task, deriving parity status.
    init(_ t: SyncTask, now: Date, defaultLead: Int) {
        self.id = t.id
        self.room = t.room
        self.firstName = t.firstName
        self.title = t.title
        self.dosage = t.dosage
        self.kind = t.kind
        self.dueDate = t.nextDueAt
        self.isMuted = !t.notificationsEnabled
        self.colorTagRaw = t.colorTagRaw
        self.lastCompletedAt = t.lastCompletedAt
        self.prnFrequencyText = t.prnFrequencyText
        self.status = Self.status(for: t, now: now, defaultLead: defaultLead)
    }

    /// Direct memberwise init (previews / sample data).
    init(id: UUID, room: String, firstName: String?, title: String, dosage: String?, kind: TaskKind,
         dueDate: Date?, status: WatchStatus, isMuted: Bool = false, colorTagRaw: String = "none",
         lastCompletedAt: Date? = nil, prnFrequencyText: String = "") {
        self.id = id; self.room = room; self.firstName = firstName; self.title = title
        self.dosage = dosage; self.kind = kind; self.dueDate = dueDate; self.status = status
        self.isMuted = isMuted; self.colorTagRaw = colorTagRaw
        self.lastCompletedAt = lastCompletedAt; self.prnFrequencyText = prnFrequencyText
    }

    /// Mirrors the phone's `status(of:)` ordering so the watch and phone never disagree.
    private static func status(for t: SyncTask, now: Date, defaultLead: Int) -> WatchStatus {
        if t.scheduleType.isNeedsRepair { return .needsRepair }
        if SchedulingEngine.isCompletedTerminal(schedule: t.scheduleType, nextDueAt: t.nextDueAt,
                                                lastCompletedAt: t.lastCompletedAt) { return .completed }
        if t.isPaused { return .paused }
        if case .unscheduled = t.scheduleType { return .unscheduled }
        guard let due = t.nextDueAt else { return .prn }
        if due <= now { return .overdue }
        let lead = t.leadTimeMinutes ?? defaultLead
        if due <= now.addingTimeInterval(Double(lead) * 60) { return .dueSoon }
        return .upcoming
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
    case synced(Date)              // last snapshot's generatedAt
    case needsUpdate               // phone sent a NEWER schema than this build understands
}

/// The watch's local view of synced state. `tasks` are already parity-mapped; `generatedAt`
/// drives the staleness indicator (item 2).
struct WatchSnapshot: Sendable {
    var tasks: [WatchTask]
    var generatedAt: Date?
    static let empty = WatchSnapshot(tasks: [], generatedAt: nil)
}

/// Actions a nurse takes on the watch, destined for the phone (source of truth). Pause is
/// phone-only per the established design, so it is NOT part of the sync action set.
enum WatchAction: Sendable {
    case given(UUID)
    case snooze(UUID)
    case skipOnce(UUID)
}

/// The phone↔watch channel abstraction. `WCSessionSyncTransport` is the production
/// implementation; `StubSyncTransport` supplies sample data for previews.
protocol SyncTransport: AnyObject {
    var state: SyncState { get }
    var snapshot: WatchSnapshot { get }
    /// Task IDs with an unconfirmed local action — drives the per-row pending indicator (§5.3).
    var pendingTaskIDs: Set<UUID> { get }
    /// True when the phone is currently unreachable (drives the staleness treatment).
    var phoneUnreachable: Bool { get }
    var onChange: (() -> Void)? { get set }
    func refresh()
    func send(_ action: WatchAction)
}

extension SyncTransport {
    var pendingTaskIDs: Set<UUID> { [] }
    var phoneUnreachable: Bool { false }
}

#if canImport(WatchConnectivity)
/// Production transport (BUILD_SPEC §5.3):
///  - Receives the phone's `SyncSnapshot` via `applicationContext` / `transferUserInfo`, guards
///    the schema version, parity-maps it, and reschedules local notifications from it (item 3).
///  - Sends watch actions via `sendMessage` when reachable, `transferUserInfo` (durable, retried
///    by the OS) when not. Unconfirmed actions are applied optimistically, persisted, and kept in
///    a pending set until a newer snapshot confirms them — a failed/unsent action is never lost.
final class WCSessionSyncTransport: NSObject, SyncTransport {
    private(set) var state: SyncState = .notSynced
    private(set) var snapshot: WatchSnapshot = .empty
    private(set) var pendingTaskIDs: Set<UUID> = []
    var phoneUnreachable: Bool {
        #if os(watchOS)
        WCSession.isSupported() ? !WCSession.default.isReachable : true
        #else
        true
        #endif
    }
    var onChange: (() -> Void)?

    /// Snooze/skip/lead defaults last seen from the phone — used to derive parity status when a
    /// task has no per-task override.
    private var defaultLead = 15
    /// Queued, unconfirmed actions (persisted so the indicator survives relaunch until confirmed).
    private var pendingActions: [SyncAction] = []
    private let reschedule: (SyncSnapshot) -> Void

    private static let pendingKey = "nt.pendingActions.v1"

    /// `reschedule` is called after each accepted snapshot so the watch keeps its own local
    /// notifications in sync (item 3). Injected to keep this file free of UserNotifications.
    init(reschedule: @escaping (SyncSnapshot) -> Void = { _ in }) {
        self.reschedule = reschedule
        super.init()
        loadPendingActions()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() { onChange?() }

    // MARK: Sending actions

    func send(_ action: WatchAction) {
        let sync = syncAction(for: action)
        pendingActions.append(sync)
        pendingTaskIDs.insert(sync.taskID)
        savePendingActions()
        applyOptimistically(action)
        transmit(sync)
        onChange?()
    }

    private func syncAction(for action: WatchAction) -> SyncAction {
        switch action {
        case .given(let id):    return SyncAction(taskID: id, kind: .given, timestamp: .now)
        case .snooze(let id):   return SyncAction(taskID: id, kind: .snooze, timestamp: .now)
        case .skipOnce(let id): return SyncAction(taskID: id, kind: .skipOnce, timestamp: .now)
        }
    }

    /// Optimistic local edit so the UI responds instantly; reconciled when the authoritative
    /// snapshot returns. Given/Skip remove the row; Snooze keeps it (still due) but pending.
    private func applyOptimistically(_ action: WatchAction) {
        switch action {
        case .given(let id), .skipOnce(let id):
            snapshot.tasks.removeAll { $0.id == id }
        case .snooze:
            break
        }
    }

    private func transmit(_ action: SyncAction) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard let data = try? JSONEncoder().encode(SyncActionBatch(actions: [action])) else { return }
        let payload = [WCSessionKeys.actions: data]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: { _ in
                // Delivered; confirmation of APPLICATION still comes from the next snapshot.
            }, errorHandler: { [weak self] _ in
                // Live send failed — fall back to the durable queue so it is never lost.
                self?.queueDurably(payload)
            })
        } else {
            queueDurably(payload)   // not reachable → durable transfer (OS retries across launches)
        }
    }

    private func queueDurably(_ payload: [String: Any]) {
        guard WCSession.isSupported() else { return }
        WCSession.default.transferUserInfo(payload)
    }

    // MARK: Receiving snapshots

    private func ingest(_ data: Data) {
        guard let snap = try? JSONDecoder().decode(SyncSnapshot.self, from: data) else { return }
        if snap.isNewerThanSupported {
            // Never render partial/unknown data — surface an "update the app" state instead.
            state = .needsUpdate
            onChange?()
            return
        }
        defaultLead = snap.settings.defaultLeadTimeMinutes
        let now = Date()
        snapshot = WatchSnapshot(
            tasks: snap.tasks.map { WatchTask($0, now: now, defaultLead: defaultLead) },
            generatedAt: snap.generatedAt)
        state = .synced(snap.generatedAt)
        // Confirm pending actions the phone has now processed (its snapshot postdates them).
        reconcilePending(against: snap)
        // Keep the watch's own local notifications in step with the fresh snapshot (item 3).
        reschedule(snap)
        onChange?()
    }

    /// An action is confirmed once a snapshot generated AFTER it arrives — the phone applied it
    /// and re-pushed. Drop confirmed actions from the pending set/indicator.
    private func reconcilePending(against snap: SyncSnapshot) {
        pendingActions.removeAll { snap.generatedAt >= $0.timestamp }
        pendingTaskIDs = Set(pendingActions.map(\.taskID))
        savePendingActions()
    }

    // MARK: Pending persistence

    private func loadPendingActions() {
        guard let data = UserDefaults.standard.data(forKey: Self.pendingKey),
              let actions = try? JSONDecoder().decode([SyncAction].self, from: data) else { return }
        pendingActions = actions
        pendingTaskIDs = Set(actions.map(\.taskID))
    }

    private func savePendingActions() {
        let data = try? JSONEncoder().encode(pendingActions)
        UserDefaults.standard.set(data, forKey: Self.pendingKey)
    }
}

enum WCSessionKeys {
    static let snapshot = "snapshot"
    static let actions = "actions"
}

extension WCSessionSyncTransport: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        // On activation the phone re-pushes; also pick up any applicationContext already waiting.
        if let data = session.receivedApplicationContext[WCSessionKeys.snapshot] as? Data {
            DispatchQueue.main.async { self.ingest(data) }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let data = applicationContext[WCSessionKeys.snapshot] as? Data {
            DispatchQueue.main.async { self.ingest(data) }
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[WCSessionKeys.snapshot] as? Data {
            DispatchQueue.main.async { self.ingest(data) }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.onChange?() }
    }
}
#endif

/// A no-op / in-memory `SyncTransport` for SwiftUI previews and the honest "not synced" demo.
/// Performs no networking and never claims to be synced.
final class StubSyncTransport: SyncTransport {
    private(set) var state: SyncState
    private(set) var snapshot: WatchSnapshot
    var onChange: (() -> Void)?

    init(state: SyncState = .notSynced, snapshot: WatchSnapshot = .empty) {
        self.state = state
        self.snapshot = snapshot
    }

    func refresh() { onChange?() }

    func send(_ action: WatchAction) {
        switch action {
        case .given(let id), .skipOnce(let id):
            snapshot.tasks.removeAll { $0.id == id }
        case .snooze:
            break
        }
        onChange?()
    }

    static func sample() -> StubSyncTransport {
        StubSyncTransport(state: .notSynced,
                          snapshot: WatchSnapshot(tasks: WatchTask.samples, generatedAt: nil))
    }
}

extension WatchTask {
    static let samples: [WatchTask] = [
        WatchTask(id: UUID(), room: "412B", firstName: "Maria", title: "Metoprolol",
                  dosage: "25 mg PO", kind: .medication, dueDate: Date().addingTimeInterval(-8 * 60),
                  status: .overdue),
        WatchTask(id: UUID(), room: "414", firstName: nil, title: "Vitals",
                  dosage: nil, kind: .generic, dueDate: Date().addingTimeInterval(6 * 60),
                  status: .dueSoon),
        WatchTask(id: UUID(), room: "409", firstName: "Sam", title: "Insulin",
                  dosage: "6 units SC", kind: .medication, dueDate: Date().addingTimeInterval(40 * 60),
                  status: .upcoming, isMuted: true),
    ]
}

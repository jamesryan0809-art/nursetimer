import Foundation

// MARK: - Versioned phone↔watch sync schema (BUILD_SPEC §5.3)
//
// ONE definition, shared by the phone app, the watch app, and the tested Core — the watch
// never re-implements the wire shape. Everything here is Foundation-only + Codable + Sendable
// so it crosses the WatchConnectivity boundary and stays unit-testable.

public enum SyncSchema {
    /// Current wire-schema version. BUMP when the snapshot/action shape changes in a way an
    /// older build can't render. A watch that receives a snapshot whose `schemaVersion` exceeds
    /// this shows an "update the app" state (see `SyncSnapshot.isNewerThanSupported`) rather than
    /// crashing or silently misrendering unknown data.
    public static let currentVersion = 1
}

/// One task flattened for the watch: everything needed to (a) render with phone parity and
/// (b) re-run the SAME `NotificationPlanner` locally with identical inputs.
public struct SyncTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let room: String
    public let firstName: String?
    public let title: String
    public let dosage: String?
    public let route: String?
    public let kind: TaskKind
    /// The encoded `ScheduleType` bytes — decoded on the watch via `ScheduleType.decode(fromStore:)`
    /// so a corrupt payload quarantines to `.needsRepair` EXACTLY like the phone, never a silent
    /// coercion. Carrying raw bytes (not a decoded case) keeps the wire shape stable across
    /// additive enum-case changes.
    public let scheduleData: Data
    public let lastCompletedAt: Date?
    public let nextDueAt: Date?
    public let leadTimeMinutes: Int?
    public let snoozeMinutes: Int?
    public let isPaused: Bool
    public let notificationsEnabled: Bool
    public let isArchived: Bool
    public let explicitSnoozeAt: Date?
    /// Display-only channels carried for render parity (status color is derived, not sent).
    public let colorTagRaw: String
    public let prnFrequencyText: String

    public init(
        id: UUID, room: String, firstName: String?, title: String, dosage: String?, route: String?,
        kind: TaskKind, scheduleData: Data, lastCompletedAt: Date?, nextDueAt: Date?,
        leadTimeMinutes: Int?, snoozeMinutes: Int?, isPaused: Bool, notificationsEnabled: Bool,
        isArchived: Bool, explicitSnoozeAt: Date?, colorTagRaw: String, prnFrequencyText: String
    ) {
        self.id = id
        self.room = room
        self.firstName = firstName
        self.title = title
        self.dosage = dosage
        self.route = route
        self.kind = kind
        self.scheduleData = scheduleData
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.leadTimeMinutes = leadTimeMinutes
        self.snoozeMinutes = snoozeMinutes
        self.isPaused = isPaused
        self.notificationsEnabled = notificationsEnabled
        self.isArchived = isArchived
        self.explicitSnoozeAt = explicitSnoozeAt
        self.colorTagRaw = colorTagRaw
        self.prnFrequencyText = prnFrequencyText
    }

    /// The decoded schedule, quarantining a corrupt payload to `.needsRepair` (parity with phone).
    public var scheduleType: ScheduleType { ScheduleType.decode(fromStore: scheduleData) }

    /// A Core `SchedulableTask` value so the watch feeds the shared `NotificationPlanner` the
    /// identical inputs the phone used — same deterministic identifiers, same plan (item 3).
    public var schedulable: TaskSnapshot {
        TaskSnapshot(
            id: id, kind: kind, roomNumber: room, scheduleType: scheduleType,
            lastCompletedAt: lastCompletedAt, nextDueAt: nextDueAt,
            leadTimeMinutes: leadTimeMinutes, snoozeMinutes: snoozeMinutes,
            isPaused: isPaused, notificationsEnabled: notificationsEnabled,
            isArchived: isArchived, explicitSnoozeAt: explicitSnoozeAt)
    }
}

/// The full phone→watch state snapshot (BUILD_SPEC §5.3). The phone is the source of truth and
/// pushes this on every store commit; the watch renders + schedules from it and reconciles its
/// optimistic local edits against it. Versioned for graceful cross-build degradation.
public struct SyncSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let tasks: [SyncTask]
    /// Lock-screen redaction preference — so watch-scheduled notifications redact identically
    /// to the phone (item 3 / §6.3).
    public let privacyMode: Bool
    /// Scheduler parameters, so the watch's `NotificationPlanner.plan` matches the phone's.
    public let settings: SchedulerSettings

    public init(
        generatedAt: Date, tasks: [SyncTask], privacyMode: Bool,
        settings: SchedulerSettings, schemaVersion: Int = SyncSchema.currentVersion
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.privacyMode = privacyMode
        self.settings = settings
    }

    /// True when this snapshot was produced by a NEWER app than the reader understands. The watch
    /// must then show an "update the app" state — never attempt to render partial/unknown data.
    public var isNewerThanSupported: Bool { schemaVersion > SyncSchema.currentVersion }

    /// Tasks as Core value types for the shared planner.
    public var schedulables: [TaskSnapshot] { tasks.map(\.schedulable) }
}

// MARK: - Watch → phone actions (BUILD_SPEC §5.3)

/// A watch-originated action destined for the phone (source of truth). Carries a unique id so a
/// resend is idempotent, a task id, the action, the tap timestamp, and the source ("via watch").
public struct SyncAction: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case given          // Given / Done — the phone routes to the kind-correct record
        case snooze
        case skipOnce
    }
    public let id: UUID
    public let taskID: UUID
    public let kind: Kind
    public let timestamp: Date
    public let source: String

    public init(id: UUID = UUID(), taskID: UUID, kind: Kind, timestamp: Date, source: String = "via watch") {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.timestamp = timestamp
        self.source = source
    }
}

/// A batch of queued watch actions, packed for one `transferUserInfo` / `sendMessage` payload.
public struct SyncActionBatch: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let actions: [SyncAction]
    public init(actions: [SyncAction], schemaVersion: Int = SyncSchema.currentVersion) {
        self.schemaVersion = schemaVersion
        self.actions = actions
    }
}

/// Conflict resolution for a batch of actions applied on the phone (BUILD_SPEC §5.3).
public enum SyncConflictResolver {
    /// Order actions so the LAST-applied per task is authoritative — "last action wins by
    /// timestamp." Ties break so a completion (Given/Skip) is applied AFTER a Snooze at the
    /// SAME timestamp, i.e. "a Given always supersedes a Snooze at the same time." The action
    /// id gives a deterministic final tiebreak so the order is stable across resends.
    public static func applicationOrder(_ actions: [SyncAction]) -> [SyncAction] {
        actions.sorted { a, b in
            if a.timestamp != b.timestamp { return a.timestamp < b.timestamp }
            let pa = priority(a.kind), pb = priority(b.kind)
            if pa != pb { return pa < pb }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Snooze is subordinate to completions at an equal timestamp (applied first → overwritten).
    private static func priority(_ kind: SyncAction.Kind) -> Int {
        switch kind {
        case .snooze:            return 0
        case .given, .skipOnce:  return 1
        }
    }
}

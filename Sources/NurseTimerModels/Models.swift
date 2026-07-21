// SwiftData persistence layer (spec §3).
//
// IMPORTANT: This whole file is guarded by `#if canImport(SwiftData)` so it is
// completely inert on non-Apple toolchains (Linux/Windows CI). The tested
// scheduling code (NurseTimerCore) NEVER imports this target — the engine works
// on the `SchedulableTask` protocol / `TaskSnapshot` value type instead.
//
// On Apple platforms these @Model classes are the source of truth; `CareTask`
// conforms to `SchedulableTask` so the same engine drives real persisted data.

#if canImport(SwiftData)
import Foundation
import SwiftData
import NurseTimerCore

// MARK: - Patient (spec §3.1)

@Model
public final class Patient {
    @Attribute(.unique) public var id: UUID
    public var roomNumber: String
    public var firstName: String?
    public var notes: String?
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CareTask.patient)
    public var tasks: [CareTask]

    public init(
        id: UUID = UUID(),
        roomNumber: String,
        firstName: String? = nil,
        notes: String? = nil,
        isActive: Bool = true,
        createdAt: Date,
        updatedAt: Date,
        tasks: [CareTask] = []
    ) {
        self.id = id
        self.roomNumber = roomNumber
        self.firstName = firstName
        self.notes = notes
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tasks = tasks
    }

    /// Display name, e.g. "Rm 412B · Maria" (spec §3.1).
    public var displayName: String {
        "Rm \(roomNumber)" + (firstName.map { " · \($0)" } ?? "")
    }
}

// MARK: - CareTask (spec §3.2)

@Model
public final class CareTask {
    @Attribute(.unique) public var id: UUID
    public var kindRaw: String
    public var title: String
    public var dosage: String?
    public var route: String?
    /// Encoded `ScheduleType` (SwiftData stores primitives cleanly; we bridge to
    /// the Core enum via `scheduleType`).
    public var scheduleData: Data
    public var lastCompletedAt: Date?
    public var nextDueAt: Date?
    public var leadTimeMinutes: Int?
    public var snoozeMinutes: Int?
    public var isPaused: Bool
    public var explicitSnoozeAt: Date?
    // Timestamps consistent with Patient. Property-level defaults let SwiftData add these
    // new attributes to an existing store via lightweight migration (item 6 — repair/
    // pause/resume assign updatedAt).
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    /// Optional per-med color tag (raw name of an app-layer palette entry, "none" default).
    /// A display-only channel SEPARATE from status color (spec §7); NOT a scheduling input.
    /// Property-level default keeps this migration-safe for an existing store.
    public var colorTagRaw: String = "none"
    /// Per-task notifications switch (feedback item 2). When false the task is MUTED — it
    /// keeps its schedule and stays visible everywhere, but the planner excludes it exactly
    /// like a paused task, so it fires no reminders. Property-level default `true` keeps this
    /// migration-safe for an existing store (existing tasks stay unmuted).
    public var notificationsEnabled: Bool = true
    /// Free-text PRN frequency guidance (feedback item 3), e.g. "every 4–6 hrs as needed".
    /// STRICTLY display-only: the app never parses it, computes next-allowed times, validates
    /// against it, or alerts from it — that would be dose-timing calculation (spec §1.2 non-goal).
    /// The nurse reads it alongside last-given and decides. Migration-safe default empty.
    public var prnFrequencyText: String = ""

    public var patient: Patient?

    @Relationship(deleteRule: .cascade, inverse: \TaskEvent.task)
    public var history: [TaskEvent]

    public init(
        id: UUID = UUID(),
        kind: TaskKind,
        title: String,
        dosage: String? = nil,
        route: String? = nil,
        scheduleType: ScheduleType,
        lastCompletedAt: Date? = nil,
        nextDueAt: Date? = nil,
        leadTimeMinutes: Int? = nil,
        snoozeMinutes: Int? = nil,
        isPaused: Bool = false,
        explicitSnoozeAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        colorTagRaw: String = "none",
        notificationsEnabled: Bool = true,
        prnFrequencyText: String = "",
        history: [TaskEvent] = []
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.title = title
        self.dosage = dosage
        self.route = route
        self.scheduleData = (try? JSONEncoder().encode(scheduleType)) ?? Data()
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.leadTimeMinutes = leadTimeMinutes
        self.snoozeMinutes = snoozeMinutes
        self.isPaused = isPaused
        self.explicitSnoozeAt = explicitSnoozeAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.colorTagRaw = colorTagRaw
        self.notificationsEnabled = notificationsEnabled
        self.prnFrequencyText = prnFrequencyText
        self.history = history
    }
}

extension CareTask: SchedulableTask {
    public var kind: TaskKind { TaskKind(rawValue: kindRaw) ?? .generic }

    /// Room of this task's patient ("" if detached). Drives the planner's digest
    /// grouping (spec §4.3).
    public var roomNumber: String { patient?.roomNumber ?? "" }

    public var scheduleType: ScheduleType {
        // Fail LOUD: an undecodable payload becomes `.needsRepair` (carrying the raw
        // bytes), never a silent `.prn`. Quarantined per-task (spec §4.1).
        get { ScheduleType.decode(fromStore: scheduleData) }
        set { scheduleData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

extension CareTask {
    /// True iff the persisted schedule failed to decode and awaits manual repair.
    public var scheduleNeedsRepair: Bool { scheduleType.isNeedsRepair }

    /// True iff this is an as-needed (PRN) task — drives the last-given + frequency display
    /// (feedback item 3). Lets views branch without importing the Core `ScheduleType` enum.
    public var isPRN: Bool { if case .prn = scheduleType { return true }; return false }

    /// Apply a nurse-selected repair: set a new valid schedule and establish a FRESH
    /// `nextDueAt` from `anchor` (last-given time, or now). Clears the repair state
    /// (the schedule is valid again) and never reuses the old, untrusted `nextDueAt`
    /// (spec §6.2). The app then removes the task's pending repair warning.
    public func repair(with schedule: ScheduleType, anchor: Date, calendar: Calendar = .current) {
        precondition(!schedule.isNeedsRepair, "Repair schedule must be valid, not .needsRepair")
        self.scheduleType = schedule
        self.nextDueAt = SchedulingEngine.firstDue(for: schedule, anchor: anchor, calendar: calendar)
        self.explicitSnoozeAt = nil
        self.updatedAt = anchor
    }
}

// MARK: - TaskEvent (spec §3.3)

@Model
public final class TaskEvent {
    @Attribute(.unique) public var id: UUID
    public var taskID: UUID
    public var actionRaw: String
    public var timestamp: Date
    public var note: String?

    public var task: CareTask?

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        action: TaskAction,
        timestamp: Date,
        note: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.actionRaw = action.rawValue
        self.timestamp = timestamp
        self.note = note
    }

    public var action: TaskAction {
        get { TaskAction(rawValue: actionRaw) ?? .missedAcknowledged }
        set { actionRaw = newValue.rawValue }
    }
}

// MARK: - AppSettings (spec §3.4, single row)

@Model
public final class AppSettings {
    public var defaultLeadTimeMinutes: Int
    public var defaultSnoozeMinutes: Int
    public var privacyModeNotifications: Bool
    public var appLockEnabled: Bool
    public var appLockTimeoutMinutes: Int
    public var shiftStartHour: Int?
    /// Last-used Schedule tab mode ("byTime" / "byPatient" / "grid"). Property-level default
    /// keeps this migration-safe for an existing store.
    public var scheduleModeRaw: String = "byTime"

    public init(
        defaultLeadTimeMinutes: Int = 15,
        defaultSnoozeMinutes: Int = 3,
        privacyModeNotifications: Bool = true,
        appLockEnabled: Bool = true,
        appLockTimeoutMinutes: Int = 5,
        shiftStartHour: Int? = nil,
        scheduleModeRaw: String = "byTime"
    ) {
        self.defaultLeadTimeMinutes = defaultLeadTimeMinutes
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.privacyModeNotifications = privacyModeNotifications
        self.appLockEnabled = appLockEnabled
        self.appLockTimeoutMinutes = appLockTimeoutMinutes
        self.shiftStartHour = shiftStartHour
        self.scheduleModeRaw = scheduleModeRaw
    }

    /// Bridge to the Core scheduler parameters.
    public var schedulerSettings: SchedulerSettings {
        SchedulerSettings(
            defaultLeadTimeMinutes: defaultLeadTimeMinutes,
            defaultSnoozeMinutes: defaultSnoozeMinutes)
    }
}
#endif

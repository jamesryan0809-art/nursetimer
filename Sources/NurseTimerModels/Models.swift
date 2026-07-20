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
        self.history = history
    }
}

extension CareTask: SchedulableTask {
    public var kind: TaskKind { TaskKind(rawValue: kindRaw) ?? .generic }

    public var scheduleType: ScheduleType {
        get { (try? JSONDecoder().decode(ScheduleType.self, from: scheduleData)) ?? .prn }
        set { scheduleData = (try? JSONEncoder().encode(newValue)) ?? Data() }
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

    public init(
        defaultLeadTimeMinutes: Int = 15,
        defaultSnoozeMinutes: Int = 3,
        privacyModeNotifications: Bool = true,
        appLockEnabled: Bool = true,
        appLockTimeoutMinutes: Int = 5,
        shiftStartHour: Int? = nil
    ) {
        self.defaultLeadTimeMinutes = defaultLeadTimeMinutes
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.privacyModeNotifications = privacyModeNotifications
        self.appLockEnabled = appLockEnabled
        self.appLockTimeoutMinutes = appLockTimeoutMinutes
        self.shiftStartHour = shiftStartHour
    }

    /// Bridge to the Core scheduler parameters.
    public var schedulerSettings: SchedulerSettings {
        SchedulerSettings(
            defaultLeadTimeMinutes: defaultLeadTimeMinutes,
            defaultSnoozeMinutes: defaultSnoozeMinutes)
    }
}
#endif

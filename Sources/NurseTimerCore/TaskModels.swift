import Foundation

// MARK: - Value types (Foundation only)
//
// These are the pure, dependency-free representations the scheduling engine and
// NotificationPlanner operate on. The SwiftData @Model classes (NurseTimerModels)
// map onto `SchedulableTask` — the tested code never sees SwiftData.

/// Two kinds of care task, one model. Mirrors spec §3.2.
public enum TaskKind: String, Codable, Equatable, Hashable, Sendable {
    case medication
    case generic
}

/// A validated recurrence interval, stored as **minutes** so sub-hour cadences
/// (e.g. q30min generic tasks) are first-class. Invalid intervals are
/// *unrepresentable*: the only way to build one is the failable initializer, which
/// rejects anything outside `[5 minutes, 24 hours]`. Custom `Codable` re-validates
/// on decode, so a corrupt store value can never smuggle an out-of-range interval
/// back in (spec §4.1 / §6.2).
public struct IntervalMinutes: Equatable, Hashable, Sendable, Codable {
    public let minutes: Int

    /// Minimum legal interval: 5 minutes.
    public static let minMinutes = 5
    /// Maximum legal interval: 24 hours.
    public static let maxMinutes = 24 * 60

    /// Fails for `minutes < 5` or `minutes > 1440`.
    public init?(minutes: Int) {
        guard minutes >= Self.minMinutes, minutes <= Self.maxMinutes else { return nil }
        self.minutes = minutes
    }

    /// Convenience: build from hours + minutes. Fails on the same bounds.
    public init?(hours: Int, minutes: Int = 0) {
        self.init(minutes: hours * 60 + minutes)
    }

    /// Interval length as seconds, for absolute date math.
    public var timeInterval: TimeInterval { Double(minutes) * 60 }
    /// Interval length in fractional hours (e.g. 30 min → 0.5).
    public var hours: Double { Double(minutes) / 60 }

    // Persisted as a bare Int (minutes); decode re-validates and throws on out-of-range
    // so an invalid interval can never round-trip back into a valid-looking schedule.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let m = try container.decode(Int.self)
        guard let valid = IntervalMinutes(minutes: m) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Interval \(m) min is outside [\(Self.minMinutes), \(Self.maxMinutes)]"))
        }
        self = valid
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(minutes)
    }
}

/// How a task recurs. Mirrors spec §3.2 / §4.1.
public enum ScheduleType: Codable, Equatable, Hashable, Sendable {
    /// Every `interval`, anchored to actual administration time. Stored as minutes,
    /// so both hourly (q4h) and sub-hour (q30min) cadences are supported.
    case interval(IntervalMinutes)
    /// Fixed wall-clock times each day (only `hour`/`minute` are used).
    case fixedTimes([DateComponents])
    /// Fires once at the given absolute date, then the task auto-pauses.
    case once(Date)
    /// As-needed. Never auto-schedules.
    case prn

    /// Validated factory for an interval schedule. Returns `nil` when hours+minutes
    /// falls outside `[5 min, 24 h]` — invalid intervals are unrepresentable (spec §4.1).
    public static func every(hours: Int = 0, minutes: Int = 0) -> ScheduleType? {
        IntervalMinutes(minutes: hours * 60 + minutes).map(ScheduleType.interval)
    }
}

/// Actions recorded in the shift log. Mirrors spec §3.3.
public enum TaskAction: String, Codable, Equatable, Hashable, Sendable {
    case given
    case done
    case skipped
    case snoozed
    case missedAcknowledged
}

/// The read-only surface the scheduler needs from a task. The SwiftData model
/// conforms to this; tests use `TaskSnapshot`.
public protocol SchedulableTask {
    var id: UUID { get }
    var kind: TaskKind { get }
    var scheduleType: ScheduleType { get }
    /// When the task was last marked Given/Done. Nil if never.
    var lastCompletedAt: Date? { get }
    /// The next absolute due time. Nil for PRN / never-scheduled tasks.
    var nextDueAt: Date? { get }
    /// Per-task lead-time override in minutes; nil = use global default.
    var leadTimeMinutes: Int? { get }
    /// Per-task snooze override in minutes; nil = use global default.
    var snoozeMinutes: Int? { get }
    /// "Held" — excluded from scheduling without being deleted.
    var isPaused: Bool { get }
    /// If the nurse explicitly hit Snooze, the moment they did so. The re-ping
    /// chain re-anchors here instead of at `nextDueAt`. Nil normally.
    var explicitSnoozeAt: Date? { get }
}

/// Concrete, immutable `SchedulableTask` for the engine, planner, and tests.
public struct TaskSnapshot: SchedulableTask, Equatable, Sendable {
    public let id: UUID
    public let kind: TaskKind
    public let scheduleType: ScheduleType
    public let lastCompletedAt: Date?
    public var nextDueAt: Date?
    public let leadTimeMinutes: Int?
    public let snoozeMinutes: Int?
    public let isPaused: Bool
    public let explicitSnoozeAt: Date?

    public init(
        id: UUID = UUID(),
        kind: TaskKind = .medication,
        scheduleType: ScheduleType,
        lastCompletedAt: Date? = nil,
        nextDueAt: Date? = nil,
        leadTimeMinutes: Int? = nil,
        snoozeMinutes: Int? = nil,
        isPaused: Bool = false,
        explicitSnoozeAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.scheduleType = scheduleType
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.leadTimeMinutes = leadTimeMinutes
        self.snoozeMinutes = snoozeMinutes
        self.isPaused = isPaused
        self.explicitSnoozeAt = explicitSnoozeAt
    }
}

/// Global scheduling parameters. Defaults mirror spec §3.4 / §4.3.
public struct SchedulerSettings: Equatable, Sendable {
    /// Minutes before due to fire the pre-alert. Spec default 15.
    public var defaultLeadTimeMinutes: Int
    /// Minutes between re-pings. Spec default 3.
    public var defaultSnoozeMinutes: Int
    /// Only schedule notifications within this many hours of `now`. Spec: 12h.
    public var horizonHours: Double
    /// Number of pre-computed snooze pings per overdue task. Spec: 20.
    public var snoozeChainLength: Int
    /// Soft limit: above this we trim furthest pre-alerts and surface a banner. Spec: ~55.
    public var softLimit: Int
    /// Hard OS ceiling on pending local notifications. Spec: 64.
    public var hardCap: Int

    public init(
        defaultLeadTimeMinutes: Int = 15,
        defaultSnoozeMinutes: Int = 3,
        horizonHours: Double = 12,
        snoozeChainLength: Int = 20,
        softLimit: Int = 55,
        hardCap: Int = 64
    ) {
        self.defaultLeadTimeMinutes = defaultLeadTimeMinutes
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.horizonHours = horizonHours
        self.snoozeChainLength = snoozeChainLength
        self.softLimit = softLimit
        self.hardCap = hardCap
    }

    public static let `default` = SchedulerSettings()
}

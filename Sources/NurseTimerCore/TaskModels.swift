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
    /// A schedule that could NOT be decoded from the store, carrying the raw
    /// undecodable bytes for diagnostics. A task in this state schedules **no**
    /// reminders and is surfaced for manual repair — decode failure is explicit,
    /// never a silent coercion to a valid-looking schedule (spec §4.1). Anything
    /// downstream must reject this case *before* trusting `nextDueAt`.
    case needsRepair(rawPayload: Data)

    /// Validated factory for an interval schedule. Returns `nil` when hours+minutes
    /// falls outside `[5 min, 24 h]` — invalid intervals are unrepresentable (spec §4.1).
    public static func every(hours: Int = 0, minutes: Int = 0) -> ScheduleType? {
        IntervalMinutes(minutes: hours * 60 + minutes).map(ScheduleType.interval)
    }

    /// True iff this is the undecodable `.needsRepair` state.
    public var isNeedsRepair: Bool {
        if case .needsRepair = self { return true }
        return false
    }

    /// Load a persisted schedule, **quarantining decode failure per-task**.
    ///
    /// This is the ONLY sanctioned way to turn stored bytes back into a
    /// `ScheduleType`. On any failure — corrupt JSON, unknown case, or an
    /// out-of-range interval that fails `IntervalMinutes` validation — it returns
    /// `.needsRepair(rawPayload:)` carrying the original bytes. It never throws and
    /// never coerces to `.prn` or a default interval, so one bad task can neither
    /// crash store loading nor silently stop firing reminders (spec §4.1).
    public static func decode(fromStore data: Data) -> ScheduleType {
        do {
            return try JSONDecoder().decode(ScheduleType.self, from: data)
        } catch {
            return .needsRepair(rawPayload: data)
        }
    }
}

/// Actions recorded in the shift log. Mirrors spec §3.3.
public enum TaskAction: String, Codable, Equatable, Hashable, Sendable {
    case given
    case done
    case skipped
    case snoozed
    case missedAcknowledged
    /// The task was explicitly held via the in-app Pause action.
    case paused
}

/// The read-only surface the scheduler needs from a task. The SwiftData model
/// conforms to this; tests use `TaskSnapshot`.
public protocol SchedulableTask {
    var id: UUID { get }
    var kind: TaskKind { get }
    /// Room number of the task's patient. Used by the planner's digest grouping
    /// (spec §4.3). Empty string if the task is detached from a patient.
    var roomNumber: String { get }
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
    /// Per-task notifications switch. A muted task (`false`) is excluded from planning
    /// EXACTLY like a paused one — it keeps its schedule and stays visible, it just fires
    /// no reminders. Default `true` (see extension) so existing conformers/tests are
    /// unaffected. This is not a scheduling change: the planner drops muted tasks the same
    /// way it drops paused tasks.
    var notificationsEnabled: Bool { get }
    /// If the nurse explicitly hit Snooze, the moment they did so. The re-ping
    /// chain re-anchors here instead of at `nextDueAt`. Nil normally.
    var explicitSnoozeAt: Date? { get }
}

public extension SchedulableTask {
    /// Default: notifications on. Conformers that predate the switch keep firing.
    var notificationsEnabled: Bool { true }
}

/// Concrete, immutable `SchedulableTask` for the engine, planner, and tests.
public struct TaskSnapshot: SchedulableTask, Equatable, Sendable {
    public let id: UUID
    public let kind: TaskKind
    public let roomNumber: String
    public let scheduleType: ScheduleType
    public let lastCompletedAt: Date?
    public var nextDueAt: Date?
    public let leadTimeMinutes: Int?
    public let snoozeMinutes: Int?
    public let isPaused: Bool
    public let notificationsEnabled: Bool
    public let explicitSnoozeAt: Date?

    public init(
        id: UUID = UUID(),
        kind: TaskKind = .medication,
        roomNumber: String = "?",
        scheduleType: ScheduleType,
        lastCompletedAt: Date? = nil,
        nextDueAt: Date? = nil,
        leadTimeMinutes: Int? = nil,
        snoozeMinutes: Int? = nil,
        isPaused: Bool = false,
        notificationsEnabled: Bool = true,
        explicitSnoozeAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.roomNumber = roomNumber
        self.scheduleType = scheduleType
        self.lastCompletedAt = lastCompletedAt
        self.nextDueAt = nextDueAt
        self.leadTimeMinutes = leadTimeMinutes
        self.snoozeMinutes = snoozeMinutes
        self.isPaused = isPaused
        self.notificationsEnabled = notificationsEnabled
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
    /// **Hard invariant**: the emitted plan never exceeds this many notifications.
    /// Kept below the OS's 64-pending cap for headroom (spec §4.3).
    public var maxPlanNotifications: Int
    /// Floor for uniform snooze-chain depth reduction under budget pressure (spec §4.3).
    public var minSnoozeDepth: Int
    /// At most this many repair warnings are shown individually; above it they coalesce
    /// into a single repair digest so unbounded repair counts can't breach the cap (item 2).
    public var repairDigestThreshold: Int

    // Post-due taper (item 3). Phase 1: `fastCount` pings at the snooze interval;
    // Phase 2: `midCount` pings at `midIntervalMinutes`; Phase 3: `slowIntervalMinutes`
    // spacing to the horizon.
    public var fastCount: Int
    public var midIntervalMinutes: Int
    public var midCount: Int
    public var slowIntervalMinutes: Int

    public init(
        defaultLeadTimeMinutes: Int = 15,
        defaultSnoozeMinutes: Int = 3,
        horizonHours: Double = 12,
        snoozeChainLength: Int = 20,
        maxPlanNotifications: Int = 60,
        minSnoozeDepth: Int = 5,
        repairDigestThreshold: Int = 5,
        fastCount: Int = 5,
        midIntervalMinutes: Int = 15,
        midCount: Int = 5,
        slowIntervalMinutes: Int = 30
    ) {
        self.defaultLeadTimeMinutes = defaultLeadTimeMinutes
        self.defaultSnoozeMinutes = defaultSnoozeMinutes
        self.horizonHours = horizonHours
        self.snoozeChainLength = snoozeChainLength
        self.maxPlanNotifications = maxPlanNotifications
        self.minSnoozeDepth = minSnoozeDepth
        self.repairDigestThreshold = repairDigestThreshold
        self.fastCount = fastCount
        self.midIntervalMinutes = midIntervalMinutes
        self.midCount = midCount
        self.slowIntervalMinutes = slowIntervalMinutes
    }

    public static let `default` = SchedulerSettings()

    /// Clamp nonsensical settings to safe defaults so the planner can never be handed
    /// values that make it crash or emit an empty plan (item 1). Returns the sanitized
    /// settings plus whether anything had to be adjusted.
    public func validated() -> (settings: SchedulerSettings, adjusted: Bool) {
        var s = self
        var adjusted = false
        func fix<T: Comparable>(_ kp: WritableKeyPath<SchedulerSettings, T>, _ ok: Bool, _ safe: T) {
            if !ok { s[keyPath: kp] = safe; adjusted = true }
        }
        fix(\.maxPlanNotifications, (1...64).contains(maxPlanNotifications), 60)
        fix(\.minSnoozeDepth, minSnoozeDepth >= 1, 5)
        fix(\.horizonHours, horizonHours > 0, 12)
        fix(\.snoozeChainLength, snoozeChainLength >= 1, 20)
        fix(\.defaultSnoozeMinutes, defaultSnoozeMinutes >= 1, 3)
        fix(\.defaultLeadTimeMinutes, defaultLeadTimeMinutes >= 0, 15)
        fix(\.repairDigestThreshold, repairDigestThreshold >= 1, 5)
        fix(\.fastCount, fastCount >= 1, 5)
        fix(\.midIntervalMinutes, midIntervalMinutes >= 1, 15)
        fix(\.midCount, midCount >= 0, 5)
        fix(\.slowIntervalMinutes, slowIntervalMinutes >= 1, 30)
        // Keep the chain floor within the cap.
        if s.minSnoozeDepth > s.maxPlanNotifications { s.minSnoozeDepth = 5; adjusted = true }
        return (s, adjusted)
    }
}

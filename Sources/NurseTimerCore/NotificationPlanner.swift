import Foundation

/// Which slot an individual (per-task) notification occupies in a task's timeline.
public enum NotificationSlot: Equatable, Hashable, Sendable {
    case pre                 // "Due in N min"
    case due                 // due now
    case snooze(Int)         // k-th re-ping in the chain

    /// Stable string used in the deterministic identifier (spec §4.3).
    public var token: String {
        switch self {
        case .pre: return "pre"
        case .due: return "due"
        case .snooze(let n): return "snooze-\(n)"
        }
    }
}

/// Coarse classification of a planned notification (individual pre/due/snooze, or a group digest).
public enum PlannedKind: String, Equatable, Sendable { case pre, due, snooze, group }

/// A digest notification standing in for several due alerts the budget couldn't
/// afford individually (spec §4.3). Carries the member task IDs so the app can
/// route a tap (to a room-filtered Board, or the Board at large).
public struct GroupDigest: Equatable, Sendable {
    /// The shared room, or `nil` for a cross-room digest.
    public let room: String?
    /// Start of the fixed 30-minute window this digest covers.
    public let windowStart: Date
    /// Tasks folded into this digest (sorted deterministically).
    public let memberTaskIDs: [UUID]
    public let title: String
    public let body: String

    public init(room: String?, windowStart: Date, memberTaskIDs: [UUID], title: String, body: String) {
        self.room = room
        self.windowStart = windowStart
        self.memberTaskIDs = memberTaskIDs
        self.title = title
        self.body = body
    }
}

/// One concrete local notification the planner wants pending — either an individual
/// task alert or a grouped digest.
public struct PlannedNotification: Equatable, Sendable {
    public let identifier: String
    public let fireDate: Date
    public let payload: Payload

    public enum Payload: Equatable, Sendable {
        /// A single task's pre / due / snooze alert. `dueDate` is shared by the whole
        /// chain, so acting on the task cancels every slot for that due time.
        case task(taskID: UUID, dueDate: Date, slot: NotificationSlot)
        /// A coalesced digest for several tasks.
        case group(GroupDigest)
    }

    public init(identifier: String, fireDate: Date, payload: Payload) {
        self.identifier = identifier
        self.fireDate = fireDate
        self.payload = payload
    }

    public var kind: PlannedKind {
        switch payload {
        case .task(_, _, let slot):
            switch slot {
            case .pre: return .pre
            case .due: return .due
            case .snooze: return .snooze
            }
        case .group: return .group
        }
    }

    /// Task id for an individual notification; `nil` for a group.
    public var taskID: UUID? { if case .task(let id, _, _) = payload { return id }; return nil }
    /// Due date for an individual notification; `nil` for a group.
    public var dueDate: Date? { if case .task(_, let d, _) = payload { return d }; return nil }
    /// Slot for an individual notification; `nil` for a group.
    public var slot: NotificationSlot? { if case .task(_, _, let s) = payload { return s }; return nil }
    /// Digest payload for a group notification; `nil` for an individual.
    public var group: GroupDigest? { if case .group(let g) = payload { return g }; return nil }
}

/// The full pending set for a shift horizon plus flags for the UI banners (spec §4.3).
public struct NotificationPlan: Equatable, Sendable {
    public let notifications: [PlannedNotification]
    /// Pre-alerts were dropped, or snooze-chain depth was reduced, to fit the budget.
    public let wasTrimmed: Bool
    /// One or more due alerts were coalesced into digest groups.
    public let planWasCoalesced: Bool
    /// Number of group digests in the plan.
    public let coalescedGroupCount: Int
    /// IDs of tasks whose schedule failed to decode (`.needsRepair`) — zero notifications,
    /// surfaced for manual repair (spec §4.1 / §6.3).
    public let tasksNeedingRepair: [UUID]

    public init(
        notifications: [PlannedNotification],
        wasTrimmed: Bool,
        planWasCoalesced: Bool,
        coalescedGroupCount: Int,
        tasksNeedingRepair: [UUID] = []
    ) {
        self.notifications = notifications
        self.wasTrimmed = wasTrimmed
        self.planWasCoalesced = planWasCoalesced
        self.coalescedGroupCount = coalescedGroupCount
        self.tasksNeedingRepair = tasksNeedingRepair
    }
}

/// Recomputes the entire pending-notification set from current task state, enforcing
/// a **hard cap** (never more than `settings.maxPlanNotifications`, default 60) while
/// never leaving a task's due time completely unrepresented (spec §4.3).
public enum NotificationPlanner {

    /// GMT ISO-8601, seconds precision — stable across devices for dedup (spec §4.3/§5.4).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // timeZone defaults to GMT
        return f
    }()

    // MARK: Identifiers

    /// Deterministic identifier for an individual alert: `"{taskID}|{dueISO8601}|{slot}"`.
    public static func identifier(taskID: UUID, due: Date, slot: NotificationSlot) -> String {
        "\(taskID.uuidString)|\(iso.string(from: due))|\(slot.token)"
    }

    /// Deterministic identifier for a digest group: `"group|{room}|{windowStartISO8601}"`,
    /// or `"group|*|{windowStartISO8601}"` for a cross-room digest (spec §4.3).
    public static func groupIdentifier(room: String?, windowStart: Date) -> String {
        "group|\(room ?? "*")|\(iso.string(from: windowStart))"
    }

    /// Deterministic, per-task identifier for the "schedule couldn't be loaded" warning
    /// (spec §6.3) — stable so re-detection replaces rather than duplicates.
    public static func repairWarningIdentifier(taskID: UUID) -> String {
        "repair|\(taskID.uuidString)"
    }

    // MARK: Plan

    public static func plan(
        tasks: [SchedulableTask],
        settings: SchedulerSettings,
        now: Date,
        calendar: Calendar
    ) -> NotificationPlan {
        let horizonEnd = now.addingTimeInterval(settings.horizonHours * 3600)

        var preAlerts: [PlannedNotification] = []
        var chains: [[PlannedNotification]] = []   // per overdue task, earliest-ping first
        var dueItems: [DueItem] = []
        var tasksNeedingRepair: [UUID] = []

        for task in tasks {
            // Reject an undecodable schedule before trusting nextDueAt (spec §4.1).
            if task.scheduleType.isNeedsRepair {
                tasksNeedingRepair.append(task.id)
                continue
            }
            guard !task.isPaused, let due = task.nextDueAt else { continue }

            let lead = SchedulingEngine.effectiveLeadMinutes(task, settings)
            let snooze = SchedulingEngine.effectiveSnoozeMinutes(task, settings)

            if due >= now {
                guard due <= horizonEnd else { continue }
                let preDate = SchedulingEngine.preAlertDate(due: due, leadMinutes: lead)
                if preDate > now {
                    preAlerts.append(PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .pre),
                        fireDate: preDate,
                        payload: .task(taskID: task.id, dueDate: due, slot: .pre)))
                }
                dueItems.append(DueItem(taskID: task.id, room: task.roomNumber, dueDate: due))
            } else {
                let anchor = task.explicitSnoozeAt ?? due
                let chain = SchedulingEngine.snoozeChain(
                    anchor: anchor, snoozeMinutes: snooze, after: now, count: settings.snoozeChainLength)
                var pings: [PlannedNotification] = []
                for ping in chain where ping.date <= horizonEnd {
                    pings.append(PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .snooze(ping.index)),
                        fireDate: ping.date,
                        payload: .task(taskID: task.id, dueDate: due, slot: .snooze(ping.index))))
                }
                if !pings.isEmpty { chains.append(pings) }
            }
        }

        let (notifications, wasTrimmed, groupCount) = enforceBudget(
            preAlerts: preAlerts, chains: chains, dueItems: dueItems,
            settings: settings, calendar: calendar)

        return NotificationPlan(
            notifications: notifications.sorted { lhs, rhs in
                lhs.fireDate != rhs.fireDate ? lhs.fireDate < rhs.fireDate
                                             : lhs.identifier < rhs.identifier
            },
            wasTrimmed: wasTrimmed,
            planWasCoalesced: groupCount > 0,
            coalescedGroupCount: groupCount,
            tasksNeedingRepair: tasksNeedingRepair)
    }

    // MARK: Budget enforcement (spec §4.3 reduction order a → d)

    private static func enforceBudget(
        preAlerts: [PlannedNotification],
        chains: [[PlannedNotification]],
        dueItems: [DueItem],
        settings: SchedulerSettings,
        calendar: Calendar
    ) -> (notifications: [PlannedNotification], wasTrimmed: Bool, groupCount: Int) {
        let cap = settings.maxPlanNotifications
        var pre = preAlerts.sorted { $0.fireDate < $1.fireDate }   // ascending → last is furthest
        var depth = chains.map(\.count).max() ?? 0                  // uniform chain-depth cap
        var units = dueItems.map { DueUnit(members: [$0], windowStart: windowStart(of: $0.dueDate, calendar)) }

        var wasTrimmed = false
        var wasCoalesced = false

        func snoozeCount() -> Int { chains.reduce(0) { $0 + min($1.count, depth) } }
        func total() -> Int { pre.count + snoozeCount() + units.count }

        // a. Trim pre-alerts, furthest-out first.
        while total() > cap, !pre.isEmpty { pre.removeLast(); wasTrimmed = true }

        // b. Reduce snooze-chain depth uniformly, down to the floor.
        while total() > cap, depth > settings.minSnoozeDepth { depth -= 1; wasTrimmed = true }

        // c. Coalesce same-room due alerts within a 30-min window, furthest window first.
        while total() > cap {
            guard let group = furthestSameRoomGroup(in: units) else { break }
            units = coalesce(units, indices: group)
            wasCoalesced = true
        }

        // d. Coalesce across rooms by 30-min window, furthest window first.
        while total() > cap {
            guard let group = furthestWindowGroup(in: units) else { break }
            units = coalesce(units, indices: group)
            wasCoalesced = true
        }

        // Absolute backstop: after step d every window holds one unit (≤ 24 windows in a
        // 12h horizon), so dropping remaining pre / snooze depth guarantees total ≤ cap.
        while total() > cap, !pre.isEmpty { pre.removeLast(); wasTrimmed = true }
        while total() > cap, depth > 0 { depth -= 1; wasTrimmed = true }

        // Assemble.
        var out: [PlannedNotification] = pre
        for chain in chains { out.append(contentsOf: chain.prefix(depth)) }
        var groupCount = 0
        for unit in units {
            if unit.members.count == 1 {
                let m = unit.members[0]
                out.append(PlannedNotification(
                    identifier: identifier(taskID: m.taskID, due: m.dueDate, slot: .due),
                    fireDate: m.dueDate,
                    payload: .task(taskID: m.taskID, dueDate: m.dueDate, slot: .due)))
            } else {
                out.append(makeDigest(unit, calendar: calendar))
                groupCount += 1
            }
        }
        _ = wasCoalesced
        return (out, wasTrimmed, groupCount)
    }

    // MARK: Grouping helpers

    private struct DueItem { let taskID: UUID; let room: String; let dueDate: Date }
    private struct DueUnit { var members: [DueItem]; let windowStart: Date }
    private struct RoomWindow: Hashable { let room: String; let window: Date }

    /// Indices of the furthest-future (room, window) cluster among still-individual units
    /// that has ≥2 members — nil if none can be coalesced same-room.
    private static func furthestSameRoomGroup(in units: [DueUnit]) -> [Int]? {
        var byKey: [RoomWindow: [Int]] = [:]
        for (i, u) in units.enumerated() where u.members.count == 1 {
            byKey[RoomWindow(room: u.members[0].room, window: u.windowStart), default: []].append(i)
        }
        let eligible = byKey.filter { $0.value.count >= 2 }
        guard !eligible.isEmpty else { return nil }
        let key = eligible.keys.sorted {
            $0.window != $1.window ? $0.window > $1.window : $0.room < $1.room
        }.first!
        return eligible[key]
    }

    /// Indices of the furthest-future window that still has ≥2 units (any rooms) — nil if none.
    private static func furthestWindowGroup(in units: [DueUnit]) -> [Int]? {
        var byWindow: [Date: [Int]] = [:]
        for (i, u) in units.enumerated() { byWindow[u.windowStart, default: []].append(i) }
        let eligible = byWindow.filter { $0.value.count >= 2 }
        guard !eligible.isEmpty else { return nil }
        let window = eligible.keys.sorted(by: >).first!
        return eligible[window]
    }

    /// Merge the units at `indices` into one grouped unit.
    private static func coalesce(_ units: [DueUnit], indices: [Int]) -> [DueUnit] {
        let idx = Set(indices)
        var merged: [DueItem] = []
        let window = units[indices[0]].windowStart
        for i in indices { merged.append(contentsOf: units[i].members) }
        var result = units.enumerated().filter { !idx.contains($0.offset) }.map { $0.element }
        result.append(DueUnit(members: merged, windowStart: window))
        return result
    }

    private static func makeDigest(_ unit: DueUnit, calendar: Calendar) -> PlannedNotification {
        let members = unit.members.sorted {
            $0.dueDate != $1.dueDate ? $0.dueDate < $1.dueDate : $0.taskID.uuidString < $1.taskID.uuidString
        }
        let rooms = Set(members.map(\.room))
        let n = members.count
        let fireDate = members.map(\.dueDate).min() ?? unit.windowStart
        let memberIDs = members.map(\.taskID)

        let digest: GroupDigest
        if rooms.count == 1, let room = rooms.first {
            digest = GroupDigest(
                room: room, windowStart: unit.windowStart, memberTaskIDs: memberIDs,
                title: "\(n) tasks due · Rm \(room) · next 30 min",
                body: "Tap to open Rm \(room) on the Board")
        } else {
            let end = unit.windowStart.addingTimeInterval(30 * 60)
            digest = GroupDigest(
                room: nil, windowStart: unit.windowStart, memberTaskIDs: memberIDs,
                title: "\(n) tasks due · \(rooms.count) rooms · by \(hourMinute(end, calendar))",
                body: "Tap to open the Board")
        }
        return PlannedNotification(
            identifier: groupIdentifier(room: digest.room, windowStart: unit.windowStart),
            fireDate: fireDate,
            payload: .group(digest))
    }

    /// Floor a date to its fixed 30-minute window start (…:00 or …:30) in the calendar's zone.
    private static func windowStart(of date: Date, _ calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.minute = (c.minute ?? 0) < 30 ? 0 : 30
        c.second = 0
        return calendar.date(from: c) ?? date
    }

    /// "HH:mm" wall-clock in the calendar's time zone.
    private static func hourMinute(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

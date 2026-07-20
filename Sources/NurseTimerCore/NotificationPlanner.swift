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

/// Coarse classification of a planned notification.
public enum PlannedKind: String, Equatable, Sendable { case pre, due, snooze, group }

/// Which family a digest collapses. Lets the app route a digest tap without re-deriving
/// intent from the identifier string.
public enum DigestCategory: String, Equatable, Sendable { case due, overdue, repair }

/// A digest notification standing in for several tasks the budget couldn't afford
/// individually (spec §4.3). Carries the member task IDs so the app can route a tap.
public struct GroupDigest: Equatable, Sendable {
    public let category: DigestCategory
    /// The shared room, or `nil` for a cross-room / global digest.
    public let room: String?
    /// Start of the 30-minute window this digest covers (earliest member for a global digest).
    public let windowStart: Date
    /// Tasks folded into this digest (sorted deterministically).
    public let memberTaskIDs: [UUID]
    public let title: String
    public let body: String

    public init(category: DigestCategory, room: String?, windowStart: Date,
                memberTaskIDs: [UUID], title: String, body: String) {
        self.category = category
        self.room = room
        self.windowStart = windowStart
        self.memberTaskIDs = memberTaskIDs
        self.title = title
        self.body = body
    }
}

/// One concrete local notification the planner wants pending — an individual task alert
/// or a grouped digest.
public struct PlannedNotification: Equatable, Sendable {
    public let identifier: String
    public let fireDate: Date
    public let payload: Payload

    public enum Payload: Equatable, Sendable {
        case task(taskID: UUID, dueDate: Date, slot: NotificationSlot)
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

    public var taskID: UUID? { if case .task(let id, _, _) = payload { return id }; return nil }
    public var dueDate: Date? { if case .task(_, let d, _) = payload { return d }; return nil }
    public var slot: NotificationSlot? { if case .task(_, _, let s) = payload { return s }; return nil }
    public var group: GroupDigest? { if case .group(let g) = payload { return g }; return nil }
}

/// The full pending set for a shift horizon plus flags for the UI banners (spec §4.3).
public struct NotificationPlan: Equatable, Sendable {
    public let notifications: [PlannedNotification]
    /// Pre-alerts were dropped, or chain depth reduced, to fit the budget.
    public let wasTrimmed: Bool
    /// One or more tasks were coalesced into digest groups.
    public let planWasCoalesced: Bool
    /// Number of group digests in the plan.
    public let coalescedGroupCount: Int
    /// IDs of tasks whose schedule failed to decode (`.needsRepair`), surfaced for repair.
    public let tasksNeedingRepair: [UUID]
    /// Settings were out of range and safe defaults were substituted (item 1).
    public let settingsAdjusted: Bool

    public init(
        notifications: [PlannedNotification],
        wasTrimmed: Bool,
        planWasCoalesced: Bool,
        coalescedGroupCount: Int,
        tasksNeedingRepair: [UUID] = [],
        settingsAdjusted: Bool = false
    ) {
        self.notifications = notifications
        self.wasTrimmed = wasTrimmed
        self.planWasCoalesced = planWasCoalesced
        self.coalescedGroupCount = coalescedGroupCount
        self.tasksNeedingRepair = tasksNeedingRepair
        self.settingsAdjusted = settingsAdjusted
    }
}

/// Recomputes the entire pending-notification set from current task state.
///
/// **Postcondition (tested):** the emitted plan never exceeds `maxPlanNotifications`,
/// and while any task is due or overdue the plan is non-empty and represents EVERY such
/// task by at least one notification (individually or as a digest member). There is no
/// reduce-to-zero backstop; representation is guaranteed by an escalating grouping ladder
/// that ultimately collapses each category to a single global digest.
public enum NotificationPlanner {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Identifiers

    public static func identifier(taskID: UUID, due: Date, slot: NotificationSlot) -> String {
        "\(taskID.uuidString)|\(iso.string(from: due))|\(slot.token)"
    }

    /// Deterministic identifier for an upcoming-due digest (kept backward compatible).
    public static func groupIdentifier(room: String?, windowStart: Date) -> String {
        "group|\(room ?? "*")|\(iso.string(from: windowStart))"
    }

    public static func repairWarningIdentifier(taskID: UUID) -> String {
        "repair|\(taskID.uuidString)"
    }

    // MARK: Plan

    public static func plan(
        tasks: [SchedulableTask],
        settings rawSettings: SchedulerSettings,
        now: Date,
        calendar: Calendar
    ) -> NotificationPlan {
        // Validate settings at entry — never crash, never emit empty on bad input (item 1).
        let (settings, settingsAdjusted) = rawSettings.validated()
        let horizonEnd = now.addingTimeInterval(settings.horizonHours * 3600)

        var entries: [TaskEntry] = []
        var tasksNeedingRepair: [UUID] = []

        for task in tasks {
            if task.scheduleType.isNeedsRepair {
                tasksNeedingRepair.append(task.id)
                continue
            }
            guard !task.isPaused, let due = task.nextDueAt else { continue }

            let lead = SchedulingEngine.effectiveLeadMinutes(task, settings)
            let snooze = SchedulingEngine.effectiveSnoozeMinutes(task, settings)
            let window = windowStart(of: due, calendar)

            if due >= now {
                guard due <= horizonEnd else { continue }
                var pre: PlannedNotification?
                let preDate = SchedulingEngine.preAlertDate(due: due, leadMinutes: lead)
                if preDate > now {
                    pre = PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .pre),
                        fireDate: preDate, payload: .task(taskID: task.id, dueDate: due, slot: .pre))
                }
                let dueNotif = PlannedNotification(
                    identifier: identifier(taskID: task.id, due: due, slot: .due),
                    fireDate: due, payload: .task(taskID: task.id, dueDate: due, slot: .due))
                entries.append(TaskEntry(id: task.id, room: task.roomNumber, dueDate: due,
                                         windowStart: window, category: .upcoming,
                                         pre: pre, due: dueNotif, chain: []))
            } else {
                let anchor = task.explicitSnoozeAt ?? due
                let chain = SchedulingEngine.snoozeChain(
                    anchor: anchor, snoozeMinutes: snooze, after: now, count: settings.snoozeChainLength)
                var pings: [PlannedNotification] = []
                for ping in chain where ping.date <= horizonEnd {
                    pings.append(PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .snooze(ping.index)),
                        fireDate: ping.date, payload: .task(taskID: task.id, dueDate: due, slot: .snooze(ping.index))))
                }
                guard !pings.isEmpty else { continue }
                entries.append(TaskEntry(id: task.id, room: task.roomNumber, dueDate: due,
                                         windowStart: window, category: .overdue,
                                         pre: nil, due: nil, chain: pings))
            }
        }

        let result = enforceBudget(entries: entries, settings: settings, calendar: calendar)

        return NotificationPlan(
            notifications: result.notifications.sorted { lhs, rhs in
                lhs.fireDate != rhs.fireDate ? lhs.fireDate < rhs.fireDate : lhs.identifier < rhs.identifier
            },
            wasTrimmed: result.wasTrimmed,
            planWasCoalesced: result.groupCount > 0,
            coalescedGroupCount: result.groupCount,
            tasksNeedingRepair: tasksNeedingRepair,
            settingsAdjusted: settingsAdjusted)
    }

    // MARK: Internal model

    private enum Category { case upcoming, overdue }

    private struct TaskEntry {
        let id: UUID
        let room: String
        let dueDate: Date
        let windowStart: Date
        let category: Category
        let pre: PlannedNotification?
        let due: PlannedNotification?
        let chain: [PlannedNotification]
    }

    private struct Unit { var ids: [UUID]; var window: Date }
    private struct RoomWindow: Hashable { let room: String; let window: Date }

    // MARK: Budget enforcement (reduction order: pre → chains → coalesce upcoming → coalesce overdue → global)

    private static func enforceBudget(
        entries: [TaskEntry], settings: SchedulerSettings, calendar: Calendar
    ) -> (notifications: [PlannedNotification], wasTrimmed: Bool, groupCount: Int) {
        let cap = settings.maxPlanNotifications
        let floor = settings.minSnoozeDepth
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        var preKept = Set(entries.compactMap { $0.pre != nil ? $0.id : nil })
        var depth = entries.map { $0.chain.count }.max() ?? 0
        var upcoming = entries.filter { $0.category == .upcoming }.map { Unit(ids: [$0.id], window: $0.windowStart) }
        var overdue = entries.filter { $0.category == .overdue }.map { Unit(ids: [$0.id], window: $0.windowStart) }

        var wasTrimmed = false
        var coalesced = false

        func chainKept(_ id: UUID) -> Int { min(byID[id]!.chain.count, depth) }
        func unitFootprint(_ u: Unit, _ category: Category) -> Int {
            if u.ids.count > 1 { return 1 }
            let e = byID[u.ids[0]]!
            switch category {
            case .upcoming: return (preKept.contains(e.id) && e.pre != nil ? 1 : 0) + (e.due != nil ? 1 : 0) + chainKept(e.id)
            case .overdue:  return chainKept(e.id)
            }
        }
        func total() -> Int {
            upcoming.reduce(0) { $0 + unitFootprint($1, .upcoming) }
                + overdue.reduce(0) { $0 + unitFootprint($1, .overdue) }
        }

        // 1. Trim pre-alerts, furthest-due first.
        if total() > cap {
            for e in entries.filter({ $0.category == .upcoming }).sorted(by: { $0.dueDate > $1.dueDate }) {
                if total() <= cap { break }
                if preKept.remove(e.id) != nil { wasTrimmed = true }
            }
        }
        // 2. Shorten chains uniformly, down to the five-ping floor.
        while total() > cap, depth > floor { depth -= 1; wasTrimmed = true }
        // 3. Coalesce upcoming tasks (room → cross-room → global).
        while total() > cap, mergeOnce(&upcoming, byID: byID) { coalesced = true }
        // 4. Coalesce overdue tasks (room → cross-room → global).
        while total() > cap, mergeOnce(&overdue, byID: byID) { coalesced = true }

        // Assemble.
        var out: [PlannedNotification] = []
        var groupCount = 0
        func emit(_ units: [Unit], _ category: Category) {
            for u in units {
                if u.ids.count == 1 {
                    let e = byID[u.ids[0]]!
                    if category == .upcoming {
                        if preKept.contains(e.id), let pre = e.pre { out.append(pre) }
                        if let due = e.due { out.append(due) }
                    }
                    out.append(contentsOf: e.chain.prefix(depth))
                } else {
                    out.append(makeDigest(u, category: category, byID: byID, calendar: calendar))
                    groupCount += 1
                }
            }
        }
        emit(upcoming, .upcoming)
        emit(overdue, .overdue)
        return (out, wasTrimmed, groupCount)
    }

    /// One escalating merge: same room+window → same window (cross-room) → global.
    /// Returns false only when the category is already a single unit.
    private static func mergeOnce(_ units: inout [Unit], byID: [UUID: TaskEntry]) -> Bool {
        // Tier 1: same room + window, among still-individual units, furthest window first.
        var byRW: [RoomWindow: [Int]] = [:]
        for (i, u) in units.enumerated() where u.ids.count == 1 {
            let e = byID[u.ids[0]]!
            byRW[RoomWindow(room: e.room, window: u.window), default: []].append(i)
        }
        if let key = byRW.filter({ $0.value.count >= 2 }).keys
            .sorted(by: { $0.window != $1.window ? $0.window > $1.window : $0.room < $1.room }).first {
            merge(&units, byRW[key]!); return true
        }
        // Tier 2: same window, any room, furthest window first.
        var byW: [Date: [Int]] = [:]
        for (i, u) in units.enumerated() { byW[u.window, default: []].append(i) }
        if let w = byW.filter({ $0.value.count >= 2 }).keys.sorted(by: >).first {
            merge(&units, byW[w]!); return true
        }
        // Tier 3: global — collapse everything into one digest.
        if units.count > 1 { merge(&units, Array(0..<units.count)); return true }
        return false
    }

    private static func merge(_ units: inout [Unit], _ indices: [Int]) {
        let idx = Set(indices)
        var ids: [UUID] = []
        var minWindow = Date.distantFuture
        for i in indices { ids += units[i].ids; minWindow = min(minWindow, units[i].window) }
        var rest = units.enumerated().filter { !idx.contains($0.offset) }.map { $0.element }
        rest.append(Unit(ids: ids, window: minWindow))
        units = rest
    }

    private static func makeDigest(_ unit: Unit, category: Category,
                                   byID: [UUID: TaskEntry], calendar: Calendar) -> PlannedNotification {
        let members = unit.ids.compactMap { byID[$0] }.sorted {
            $0.dueDate != $1.dueDate ? $0.dueDate < $1.dueDate : $0.id.uuidString < $1.id.uuidString
        }
        let rooms = Set(members.map(\.room))
        let windows = Set(members.map(\.windowStart))
        let n = members.count
        let memberIDs = members.map(\.id)
        let fireDate = members.map { category == .upcoming ? $0.dueDate : ($0.chain.first?.fireDate ?? $0.dueDate) }
            .min() ?? (windows.min() ?? Date())
        let digestCat: DigestCategory = category == .upcoming ? .due : .overdue

        let room: String?
        let windowForID: Date
        let title: String
        let body: String
        let id: String

        if windows.count == 1, rooms.count == 1 {
            let r = rooms.first!, w = windows.first!
            room = r; windowForID = w
            body = "Tap to open Rm \(r) on the Board"
            if category == .upcoming {
                title = "\(n) tasks due · Rm \(r) · next 30 min"
                id = "group|\(r)|\(iso.string(from: w))"
            } else {
                title = "\(n) overdue · Rm \(r)"
                id = "overdue|\(r)|\(iso.string(from: w))"
            }
        } else if windows.count == 1 {
            let w = windows.first!
            room = nil; windowForID = w
            body = "Tap to open the Board"
            if category == .upcoming {
                title = "\(n) tasks due · \(rooms.count) rooms · by \(hourMinute(w.addingTimeInterval(30 * 60), calendar))"
                id = "group|*|\(iso.string(from: w))"
            } else {
                title = "\(n) overdue · \(rooms.count) rooms"
                id = "overdue|*|\(iso.string(from: w))"
            }
        } else {
            room = nil; windowForID = windows.min() ?? fireDate
            body = "Tap to open the Board"
            if category == .upcoming {
                title = "\(n) tasks due — open app"
                id = "group|*|global"
            } else {
                title = "\(n) tasks overdue — open app"
                id = "overdue|*|global"
            }
        }

        let digest = GroupDigest(category: digestCat, room: room, windowStart: windowForID,
                                 memberTaskIDs: memberIDs, title: title, body: body)
        return PlannedNotification(identifier: id, fireDate: fireDate, payload: .group(digest))
    }

    // MARK: Window helpers

    private static func windowStart(of date: Date, _ calendar: Calendar) -> Date {
        var c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        c.minute = (c.minute ?? 0) < 30 ? 0 : 30
        c.second = 0
        return calendar.date(from: c) ?? date
    }

    private static func hourMinute(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

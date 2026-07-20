import Foundation

/// Which slot a planned notification occupies in a task's timeline.
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

/// One concrete local notification the planner wants pending.
public struct PlannedNotification: Equatable, Sendable {
    public let identifier: String
    public let taskID: UUID
    /// The due time this notification is anchored to (shared by the whole chain,
    /// so acting on the task cancels every slot for that due time).
    public let dueDate: Date
    public let fireDate: Date
    public let slot: NotificationSlot

    public init(identifier: String, taskID: UUID, dueDate: Date, fireDate: Date, slot: NotificationSlot) {
        self.identifier = identifier
        self.taskID = taskID
        self.dueDate = dueDate
        self.fireDate = fireDate
        self.slot = slot
    }
}

/// The full pending set for a shift horizon, plus whether early reminders were
/// trimmed to respect the OS cap (spec §4.3 banner).
public struct NotificationPlan: Equatable, Sendable {
    public let notifications: [PlannedNotification]
    public let trimmed: Bool

    public init(notifications: [PlannedNotification], trimmed: Bool) {
        self.notifications = notifications
        self.trimmed = trimmed
    }
}

/// Recomputes the entire pending-notification set from current task state.
///
/// Design (spec §4.3): on every data change / foreground the app cancels all its
/// notifications and reschedules whatever `plan(...)` returns. This function is the
/// single source of truth for *what should be pending*, and is fully pure.
public enum NotificationPlanner {

    /// GMT ISO-8601, seconds precision — stable across devices for dedup (spec §4.3/§5.4).
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // timeZone defaults to GMT
        return f
    }()

    /// Deterministic identifier: `"{taskID}|{dueISO8601}|{slot}"` (spec §4.3).
    public static func identifier(taskID: UUID, due: Date, slot: NotificationSlot) -> String {
        "\(taskID.uuidString)|\(iso.string(from: due))|\(slot.token)"
    }

    /// Build the pending plan.
    ///
    /// Per task within the 12h horizon:
    ///   - upcoming (due ≥ now): a `pre` alert (only if still in the future) + a `due` alert.
    ///   - overdue  (due < now): the active snooze chain (future pings only).
    /// Paused tasks and tasks with no `nextDueAt` (PRN / unscheduled) contribute nothing.
    ///
    /// If the total exceeds `softLimit`, the furthest-out `pre` alerts are dropped
    /// first and `trimmed` is set. `due` alerts are never trimmed. As a final OS
    /// safeguard the furthest snooze pings are dropped only if still above `hardCap`.
    public static func plan(
        tasks: [SchedulableTask],
        settings: SchedulerSettings,
        now: Date,
        calendar: Calendar
    ) -> NotificationPlan {
        let horizonEnd = now.addingTimeInterval(settings.horizonHours * 3600)
        var notifications: [PlannedNotification] = []

        for task in tasks {
            guard !task.isPaused, let due = task.nextDueAt else { continue }

            let lead = SchedulingEngine.effectiveLeadMinutes(task, settings)
            let snooze = SchedulingEngine.effectiveSnoozeMinutes(task, settings)

            if due >= now {
                // Upcoming, and only if it lands inside the shift horizon.
                guard due <= horizonEnd else { continue }

                let preDate = SchedulingEngine.preAlertDate(due: due, leadMinutes: lead)
                if preDate > now {
                    notifications.append(PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .pre),
                        taskID: task.id, dueDate: due, fireDate: preDate, slot: .pre))
                }
                notifications.append(PlannedNotification(
                    identifier: identifier(taskID: task.id, due: due, slot: .due),
                    taskID: task.id, dueDate: due, fireDate: due, slot: .due))
            } else {
                // Overdue → active snooze chain. Re-anchors to an explicit Snooze
                // if the nurse tapped it, else to the due time (spec §4.2 step 3–4).
                let anchor = task.explicitSnoozeAt ?? due
                let chain = SchedulingEngine.snoozeChain(
                    anchor: anchor, snoozeMinutes: snooze, after: now, count: settings.snoozeChainLength)
                for ping in chain where ping.date <= horizonEnd {
                    notifications.append(PlannedNotification(
                        identifier: identifier(taskID: task.id, due: due, slot: .snooze(ping.index)),
                        taskID: task.id, dueDate: due, fireDate: ping.date, slot: .snooze(ping.index)))
                }
            }
        }

        // Trim to the OS budget (spec §4.3).
        let (kept, trimmed) = applyBudget(notifications, settings: settings)
        // Deterministic ordering by fire time for stable, testable output.
        return NotificationPlan(notifications: kept.sorted { $0.fireDate < $1.fireDate }, trimmed: trimmed)
    }

    // MARK: Budget trimming

    private static func applyBudget(
        _ notifications: [PlannedNotification],
        settings: SchedulerSettings
    ) -> (kept: [PlannedNotification], trimmed: Bool) {
        var kept = notifications
        var trimmed = false

        // 1) Above the soft limit: drop furthest-out PRE alerts first.
        if kept.count > settings.softLimit {
            let overBy = kept.count - settings.softLimit
            let preFurthestFirst = kept.enumerated()
                .filter { $0.element.slot == .pre }
                .sorted { $0.element.fireDate > $1.element.fireDate }
                .prefix(overBy)
                .map { $0.offset }
            if !preFurthestFirst.isEmpty {
                let drop = Set(preFurthestFirst)
                kept = kept.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
                trimmed = true
            }
        }

        // 2) Hard OS ceiling safeguard: if still over, drop furthest snooze pings.
        //    Never touch `due` alerts.
        if kept.count > settings.hardCap {
            let overBy = kept.count - settings.hardCap
            let snoozeFurthestFirst = kept.enumerated()
                .filter { if case .snooze = $0.element.slot { return true } else { return false } }
                .sorted { $0.element.fireDate > $1.element.fireDate }
                .prefix(overBy)
                .map { $0.offset }
            if !snoozeFurthestFirst.isEmpty {
                let drop = Set(snoozeFurthestFirst)
                kept = kept.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
                trimmed = true
            }
        }

        return (kept, trimmed)
    }
}

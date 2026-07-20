import Foundation
import UserNotifications
import NurseTimerCore
import NurseTimerModels

/// Deep-link intents produced by notification taps.
enum AppRoute: Equatable {
    case board(room: String?)
    case repairTask(UUID)
}

/// Minimal, Sendable snapshot of a task for building notification content — keeps
/// the scheduler free of SwiftData.
struct TaskDisplay: Sendable {
    let id: UUID
    let title: String
    let room: String
    let firstName: String?
    let dosage: String?
    let route: String?
    let kind: TaskKind

    @MainActor
    init(task: CareTask) {
        self.id = task.id
        self.title = task.title
        self.room = task.patient?.roomNumber ?? ""
        self.firstName = task.patient?.firstName
        self.dosage = task.dosage
        self.route = task.route
        self.kind = task.kind
    }
}

protocol NotificationScheduling {
    func apply(plan: NotificationPlan, displays: [UUID: TaskDisplay])
    func removeRepairWarning(taskID: UUID)
    func removeAll()
}

/// Adapts `NotificationPlanner` output to `UNUserNotificationCenter`: cancel-all then
/// reschedule the whole plan on every change, with deterministic identifiers so
/// re-planning replaces rather than duplicates. Registration/add failures are logged,
/// not swallowed.
final class NotificationScheduler: NotificationScheduling {

    static let categoryID = "NT_TASK"
    static let actionSnooze = "NT_SNOOZE"
    static let actionGiven  = "NT_GIVEN"
    static let actionSkip   = "NT_SKIP"

    private let center = UNUserNotificationCenter.current()
    private let calendar = Calendar.autoupdatingCurrent

    func attachDelegate(_ delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
        registerCategories()
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppLog.notifications.error("Authorization request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private func registerCategories() {
        // Snooze must be the visually dominant / first action (spec §5.2).
        let snooze = UNNotificationAction(identifier: Self.actionSnooze, title: "Snooze", options: [])
        let given  = UNNotificationAction(identifier: Self.actionGiven,  title: "Given / Done", options: [])
        let skip   = UNNotificationAction(identifier: Self.actionSkip,   title: "Skip", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [snooze, given, skip],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    // MARK: Apply plan

    func apply(plan: NotificationPlan, displays: [UUID: TaskDisplay]) {
        center.removeAllPendingNotificationRequests()
        for notification in plan.notifications { schedule(notification, displays: displays) }
        for taskID in plan.tasksNeedingRepair { scheduleRepairWarning(taskID: taskID, display: displays[taskID]) }
    }

    private func schedule(_ n: PlannedNotification, displays: [UUID: TaskDisplay]) {
        let content = UNMutableNotificationContent()
        content.interruptionLevel = .timeSensitive
        content.sound = .default

        switch n.payload {
        case .task(let taskID, _, let slot):
            let display = displays[taskID]
            content.title = titleLine(display)
            content.body = bodyLine(display, slot: slot)
            content.threadIdentifier = taskID.uuidString
            if slot == .due || slot.isSnooze { content.categoryIdentifier = Self.categoryID }
        case .group(let digest):
            content.title = digest.title
            content.body = digest.body
            content.threadIdentifier = "group"
        }

        let request = UNNotificationRequest(
            identifier: n.identifier, content: content, trigger: trigger(for: n.fireDate))
        center.add(request) { error in
            if let error {
                AppLog.notifications.error("Failed to add \(n.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Repair warnings (deterministic id → replaces, never duplicates)

    private func scheduleRepairWarning(taskID: UUID, display: TaskDisplay?) {
        let content = UNMutableNotificationContent()
        content.title = "A task's schedule couldn't be loaded"
        content.body = display.map { "Rm \($0.room) · tap to fix" } ?? "Tap to fix"
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: NotificationPlanner.repairWarningIdentifier(taskID: taskID),
            content: content, trigger: nil)   // deliver immediately
        center.add(request) { error in
            if let error {
                AppLog.notifications.error("Failed to add repair warning: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeRepairWarning(taskID: UUID) {
        let id = NotificationPlanner.repairWarningIdentifier(taskID: taskID)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: Content (Milestone 2: full content; redaction is added in Milestone 3)

    private func titleLine(_ d: TaskDisplay?) -> String {
        guard let d else { return "Task due" }
        return "Rm \(d.room) · \(d.title)"
    }

    private func bodyLine(_ d: TaskDisplay?, slot: NotificationSlot) -> String {
        let phase: String
        switch slot {
        case .pre: phase = "Due soon"
        case .due: phase = "Due now"
        case .snooze: phase = "Still due"
        }
        let dosage = d?.dosage.map { " · \($0)" } ?? ""
        return phase + dosage
    }

    private func trigger(for fireDate: Date) -> UNCalendarNotificationTrigger {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        return UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
    }
}

private extension NotificationSlot {
    var isSnooze: Bool { if case .snooze = self { return true }; return false }
}

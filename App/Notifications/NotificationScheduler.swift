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

protocol NotificationScheduling: AnyObject {
    /// When true, lock-screen content is redacted to room only (spec §6.3).
    var privacyMode: Bool { get set }
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

    /// Redact lock-screen content to room only when true (spec §6.3). Default ON.
    var privacyMode = true

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
        // Notifications offer Skip Once only — never Pause (spec §5.2).
        let skip   = UNNotificationAction(identifier: Self.actionSkip,   title: "Skip Once", options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [snooze, given, skip],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    // MARK: Apply plan

    /// Identifiers of repair notifications currently scheduled, so re-plans don't re-buzz
    /// stable warnings and obsolete ones (repaired / membership changed) get cleared (item 2).
    private var scheduledRepairIDs: Set<String> = []

    func apply(plan: NotificationPlan, displays: [UUID: TaskDisplay]) {
        // Repair notifications are OWNED by the planner now — the scheduler appends nothing.
        let repair = plan.notifications.filter { $0.isRepair }
        let tasks = plan.notifications.filter { !$0.isRepair }

        // Cancel-all-then-reschedule for task notifications (future triggers).
        center.removeAllPendingNotificationRequests()
        for n in tasks { schedule(n, displays: displays, immediate: false) }

        // Reconcile repair notifications: remove obsolete (delivered + pending), add only
        // newly-appearing ones with an immediate trigger. Stable warnings are left alone.
        let newRepairIDs = Set(repair.map { $0.identifier })
        let obsolete = Array(scheduledRepairIDs.subtracting(newRepairIDs))
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: obsolete)
            center.removeDeliveredNotifications(withIdentifiers: obsolete)
        }
        for n in repair where !scheduledRepairIDs.contains(n.identifier) {
            schedule(n, displays: displays, immediate: true)
        }
        scheduledRepairIDs = newRepairIDs
    }

    private func schedule(_ n: PlannedNotification, displays: [UUID: TaskDisplay], immediate: Bool) {
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
            // Privacy ON: redact to a kind-aware, count/room-only title ("3 medications overdue
            // · Rm 422"). Kind is permitted in redacted content (spec §6.3); no names/dosage.
            content.title = privacyMode ? redactedDigestTitle(digest, displays: displays) : digest.title
            content.body = digest.body
            content.threadIdentifier = digest.category == .repair ? "repair" : "group"
        case .repairWarning(let taskID):
            let display = displays[taskID]
            content.title = "A task's schedule couldn't be loaded"
            content.body = display.map { "Rm \($0.room) · tap to fix" } ?? "Tap to fix"
            content.threadIdentifier = "repair"
        }

        let trg: UNNotificationTrigger? = immediate ? nil : trigger(for: n.fireDate)
        let request = UNNotificationRequest(identifier: n.identifier, content: content, trigger: trg)
        center.add(request) { error in
            if let error {
                AppLog.notifications.error("Failed to add \(n.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func removeRepairWarning(taskID: UUID) {
        let id = NotificationPlanner.repairWarningIdentifier(taskID: taskID)
        scheduledRepairIDs.remove(id)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    func removeAll() {
        scheduledRepairIDs.removeAll()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: Content
    //
    // Privacy mode (spec §6.3) redacts to task KIND + room — no patient name, med name,
    // dosage, route, or notes ever appear in a notification. Kind (Medication / Care) is
    // permitted in redacted content: it is not clinically identifying and it lets the nurse
    // make a routing decision from the wrist (feedback pass 3, item 3). Full detail lives in
    // the app (behind the app lock). When privacy mode is off, content is descriptive.

    private func titleLine(_ d: TaskDisplay?) -> String {
        guard let d else { return "Task due" }
        if privacyMode { return "\(kindNoun(d.kind, capitalized: true)) due · Rm \(d.room)" }
        return "Rm \(d.room) · \(d.title)"
    }

    /// "Medication" / "Care" (singular) or "medications" / "care tasks" (plural). Kind is the
    /// only clinical-ish token allowed in redacted content (spec §6.3, feedback item 3).
    private func kindNoun(_ kind: TaskKind, capitalized: Bool = false, plural: Bool = false) -> String {
        switch (kind, plural) {
        case (.medication, false): return capitalized ? "Medication" : "medication"
        case (.medication, true):  return "medications"
        case (.generic, false):    return capitalized ? "Care" : "care task"
        case (.generic, true):     return "care tasks"
        }
    }

    /// Redacted, kind-aware digest title ("3 medications overdue · Rm 422"). Repair digests
    /// carry no clinical content, so their title is left unchanged.
    private func redactedDigestTitle(_ digest: GroupDigest, displays: [UUID: TaskDisplay]) -> String {
        guard digest.category != .repair else { return digest.title }
        let count = digest.memberTaskIDs.count
        let kinds = Set(digest.memberTaskIDs.compactMap { displays[$0]?.kind })
        let noun: String
        if kinds == [.medication] { noun = kindNoun(.medication, plural: count != 1) }
        else if kinds == [.generic] { noun = kindNoun(.generic, plural: count != 1) }
        else { noun = count == 1 ? "task" : "tasks" }   // mixed kinds
        let verb = digest.category == .overdue ? "overdue" : "due"
        let roomSuffix: String
        if let room = digest.room {
            roomSuffix = " · Rm \(room)"
        } else {
            let rooms = Set(digest.memberTaskIDs.compactMap { displays[$0]?.room }).count
            roomSuffix = rooms > 1 ? " · \(rooms) rooms" : ""
        }
        return "\(count) \(noun) \(verb)\(roomSuffix)"
    }

    private func bodyLine(_ d: TaskDisplay?, slot: NotificationSlot) -> String {
        let phase: String
        switch slot {
        case .pre: phase = "Due soon"
        case .due: phase = "Due now"
        case .snooze: phase = "Still due"
        }
        if privacyMode { return phase }   // room already in the title; no clinical detail
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

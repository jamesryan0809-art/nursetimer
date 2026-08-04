import Foundation
import UserNotifications
import NurseTimerCore

/// Watch-side local notification scheduling (BUILD_SPEC §5.4 — the mirroring fix).
///
/// The watch schedules its OWN local notifications from the synced snapshot using the SAME
/// `NotificationPlanner` (Foundation-only Core — reused, never re-implemented) and the SAME
/// deterministic identifiers as the phone. Because the identifiers match, dedup is automatic and
/// simultaneous delivery on both devices is acceptable (§5.4 — no suppression is attempted).
///
/// Any action from either device replans on the phone and re-pushes the snapshot, which lands
/// here and triggers a cancel-all-then-reschedule — stale pings clear on both sides.
///
/// Notification actions (Given / Snooze / Skip Once, Snooze first/dominant) route back through the
/// same watch action path as tap actions (`onAction`). Muted tasks fire nothing; privacy mode
/// redacts content identically to the phone.
final class WatchNotificationScheduler: NSObject {

    static let categoryID = "NT_TASK"
    static let actionSnooze = "NT_SNOOZE"
    static let actionGiven  = "NT_GIVEN"
    static let actionSkip   = "NT_SKIP"

    private let center = UNUserNotificationCenter.current()
    private let calendar = Calendar.autoupdatingCurrent
    private var privacyMode = true

    /// Set by the app so a notification action becomes a synced watch action.
    var onAction: ((WatchAction) -> Void)?

    func start() {
        center.delegate = self
        registerCategories()
        Task { await requestAuthorization() }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func registerCategories() {
        // Snooze must be the visually dominant / first action (spec §5.2).
        let snooze = UNNotificationAction(identifier: Self.actionSnooze, title: "Snooze", options: [])
        let given  = UNNotificationAction(identifier: Self.actionGiven,  title: "Given / Done", options: [])
        let skip   = UNNotificationAction(identifier: Self.actionSkip,   title: "Skip Once", options: [.destructive])
        let category = UNNotificationCategory(identifier: Self.categoryID, actions: [snooze, given, skip],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }

    // MARK: Reschedule from snapshot

    /// Recompute the plan from the snapshot and cancel-all-then-reschedule. Same planner, same
    /// identifiers as the phone → dedup is inherent.
    func reschedule(from snapshot: SyncSnapshot) {
        guard !snapshot.isNewerThanSupported else { return }   // don't schedule from data we don't understand
        privacyMode = snapshot.privacyMode
        let plan = NotificationPlanner.plan(
            tasks: snapshot.schedulables, settings: snapshot.settings, now: .now, calendar: calendar)
        let byID = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        center.removeAllPendingNotificationRequests()
        for n in plan.notifications {
            // The watch schedules future-dated task pings; immediate repair warnings stay a
            // phone concern (the nurse repairs on the phone).
            guard n.fireDate > .now, !n.isRepair else { continue }
            schedule(n, tasks: byID)
        }
    }

    private func schedule(_ n: PlannedNotification, tasks: [UUID: SyncTask]) {
        let content = UNMutableNotificationContent()
        content.interruptionLevel = .timeSensitive
        content.sound = .default

        switch n.payload {
        case .task(let taskID, _, let slot):
            let t = tasks[taskID]
            content.title = title(for: t)
            content.body = body(for: t, slot: slot)
            content.threadIdentifier = taskID.uuidString
            content.categoryIdentifier = Self.categoryID
        case .group(let digest):
            content.title = digest.title       // digests are already count/room-only (safe redacted)
            content.body = digest.body
            content.threadIdentifier = "group"
        case .repairWarning:
            return
        }

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: n.fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: n.identifier, content: content, trigger: trigger)
        center.add(request)
    }

    // MARK: Content (privacy parity with the phone — §6.3)

    private func title(for t: SyncTask?) -> String {
        guard let t else { return "Task due" }
        if privacyMode { return "\(kindNoun(t.kind, capitalized: true)) due · Rm \(t.room)" }
        if t.kind == .reminder { return "Reminder · \(t.title) · Rm \(t.room)" }
        return "Rm \(t.room) · \(t.title)"
    }

    private func body(for t: SyncTask?, slot: NotificationSlot) -> String {
        let phase: String
        switch slot {
        case .pre: phase = "Due soon"
        case .due: phase = "Due now"
        case .snooze: phase = "Still due"
        }
        if privacyMode { return phase }
        let dosage = t?.dosage.map { " · \($0)" } ?? ""
        return phase + dosage
    }

    private func kindNoun(_ kind: TaskKind, capitalized: Bool) -> String {
        switch kind {
        case .medication: return capitalized ? "Medication" : "medication"
        case .generic:    return capitalized ? "Care" : "care task"
        case .reminder:   return capitalized ? "Reminder" : "reminder"
        }
    }
}

extension WatchNotificationScheduler: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound, .list] }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let identifier = response.notification.request.identifier
        // Individual task identifier is "{taskID}|{dueISO}|{slot}".
        guard let first = identifier.split(separator: "|").first,
              let taskID = UUID(uuidString: String(first)) else { return }
        let action: WatchAction?
        switch response.actionIdentifier {
        case Self.actionGiven:  action = .given(taskID)
        case Self.actionSnooze: action = .snooze(taskID)
        case Self.actionSkip:   action = .skipOnce(taskID)
        default:                action = nil   // a plain tap just opens the app
        }
        if let action { await MainActor.run { self.onAction?(action) } }
    }
}

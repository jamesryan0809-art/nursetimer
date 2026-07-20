import Foundation
import UserNotifications
import NurseTimerCore

/// `UNUserNotificationCenterDelegate`: presents notifications while foregrounded and
/// routes notification actions (Given / Snooze / Skip) and taps back into the store.
/// Delegate callbacks arrive off the main actor, so we hop to `@MainActor` before
/// touching the store, capturing only `Sendable` strings across the boundary.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private let store: NurseStore

    init(store: NurseStore) {
        self.store = store
        super.init()
    }

    // Show reminders even when the app is foregrounded.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            self.handle(identifier: identifier, action: action)
            completionHandler()
        }
    }

    @MainActor
    private func handle(identifier: String, action: String) {
        // Repair warning → open the repair flow.
        if identifier.hasPrefix("repair|"),
           let taskID = UUID(uuidString: String(identifier.dropFirst("repair|".count))) {
            store.route = .repairTask(taskID)
            return
        }
        // Digest group → open the Board (room-filtered when same-room).
        if identifier.hasPrefix("group|") {
            let parts = identifier.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            let room = parts.count >= 2 ? String(parts[1]) : "*"
            store.route = .board(room: room == "*" ? nil : room)
            return
        }
        // Individual task notification: "{taskID}|{dueISO}|{slot}".
        guard let first = identifier.split(separator: "|").first,
              let taskID = UUID(uuidString: String(first)),
              let task = store.task(withID: taskID) else { return }

        switch action {
        case NotificationScheduler.actionGiven:  store.markGivenOrDone(task)
        case NotificationScheduler.actionSnooze: store.snooze(task)
        case NotificationScheduler.actionSkip:   store.skip(task)
        default:                                 store.route = .board(room: task.patient?.roomNumber)
        }
    }
}

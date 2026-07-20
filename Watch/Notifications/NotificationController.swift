import WatchKit
import SwiftUI
import UserNotifications

/// Custom watch notification interface (spec §5.2). The action buttons themselves
/// (Given / Snooze / Skip, with Snooze first/dominant) come from the shared "NT_TASK"
/// category registered by the phone; this controller renders the content.
class NotificationController: WKUserNotificationHostingController<NotificationView> {
    private var titleText = "Task due"
    private var messageText = ""

    override var body: NotificationView {
        NotificationView(title: titleText, message: messageText)
    }

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        titleText = content.title
        messageText = content.body
    }
}

struct NotificationView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if !message.isEmpty {
                Text(message).font(.body).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

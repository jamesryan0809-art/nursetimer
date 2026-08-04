import SwiftUI

/// watchOS app. Runs against the `SyncTransport` abstraction, now backed by a real
/// `WCSessionSyncTransport` (BUILD_SPEC §5.3): the phone pushes a versioned `SyncSnapshot`, the
/// watch renders + schedules its own local notifications from it (§5.4), and watch actions round-
/// trip to the phone. Previews still use `StubSyncTransport.sample()`.
@main
struct NurseTimerWatchApp: App {
    @State private var model: WatchModel
    private let notifications = WatchNotificationScheduler()

    init() {
        let scheduler = notifications
        // The transport reschedules local notifications from every accepted snapshot (§5.4).
        let transport = WCSessionSyncTransport(reschedule: { snapshot in
            scheduler.reschedule(from: snapshot)
            ComplicationStore.write(snapshot)   // feed the complication (item 2)
        })
        // A notification action becomes a synced watch action, same path as a tap.
        scheduler.onAction = { [weak transport] action in transport?.send(action) }
        scheduler.start()
        _model = State(initialValue: WatchModel(transport: transport))
    }

    var body: some Scene {
        WindowGroup {
            NowView().environment(model)
        }
        WKNotificationScene(controller: NotificationController.self, category: "NT_TASK")
    }
}

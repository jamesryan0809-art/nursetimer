import SwiftUI

/// watchOS app. Runs against the `SyncTransport` abstraction. Until WatchConnectivity
/// exists (a later milestone) it uses `StubSyncTransport.sample()` — sample data with a
/// permanent "not synced" banner, so the UI is reviewable without pretending sync works.
@main
struct NurseTimerWatchApp: App {
    @State private var model = WatchModel(transport: StubSyncTransport.sample())

    var body: some Scene {
        WindowGroup {
            NowView().environment(model)
        }
        WKNotificationScene(controller: NotificationController.self, category: "NT_TASK")
    }
}

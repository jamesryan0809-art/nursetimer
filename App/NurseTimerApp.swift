import SwiftUI
import SwiftData

/// Owns the container, store, notification scheduler, and delegate for the app's life.
@MainActor
@Observable
final class AppModel {
    let container: ModelContainer
    let store: NurseStore
    let scheduler: NotificationScheduler
    let coordinator: NotificationCoordinator
    let lock = AppLockController()
    var notificationsDenied = false

    init(container: ModelContainer, store: NurseStore,
         scheduler: NotificationScheduler, coordinator: NotificationCoordinator) {
        self.container = container
        self.store = store
        self.scheduler = scheduler
        self.coordinator = coordinator
    }

    func start() async {
        let settings = store.settings()
        lock.configure(enabled: settings.appLockEnabled, timeoutMinutes: settings.appLockTimeoutMinutes)
        lock.lockIfEnabled()
        let granted = await scheduler.requestAuthorization()
        notificationsDenied = !granted
        if !granted { store.banner = .notificationsDenied() }
        store.replan()
    }

    /// Recompute the plan on foreground (spec §4.3), and refresh notification status.
    func refreshOnForeground() async {
        notificationsDenied = await scheduler.authorizationStatus() == .denied
        store.replan()
    }
}

@main
struct NurseTimerApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer()
        } catch {
            AppLog.persistence.critical("ModelContainer creation failed: \(error.localizedDescription, privacy: .public)")
            // Last resort so the app still launches; the failure is surfaced in-app.
            container = try! PersistenceController.makeContainer(inMemory: true)
        }
        let scheduler = NotificationScheduler()
        let store = NurseStore(context: container.mainContext, scheduler: scheduler)
        let coordinator = NotificationCoordinator(store: store)
        scheduler.attachDelegate(coordinator)
        _app = State(initialValue: AppModel(container: container, store: store,
                                            scheduler: scheduler, coordinator: coordinator))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(app)
                .environment(app.store)
                .modelContainer(app.container)
                .task { await app.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        app.lock.didBecomeActive()
                        Task { await app.refreshOnForeground() }
                    case .background:
                        app.lock.didEnterBackground()
                    default:
                        break
                    }
                }
        }
    }
}

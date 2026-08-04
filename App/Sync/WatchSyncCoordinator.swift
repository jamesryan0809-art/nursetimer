import Foundation
import Observation
import NurseTimerCore
import NurseTimerModels
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone side of the phone↔watch link (BUILD_SPEC §5.3). The phone is the source of truth:
///
///  - It pushes a full versioned `SyncSnapshot` via `updateApplicationContext` (always-latest,
///    coalescing) with `transferUserInfo` as the durable fallback. Crucially it pushes NOT ONLY
///    on store commits but also when the session activates and whenever the watch state changes
///    (a watch paired/installed after the last commit would otherwise wait forever).
///  - It answers a watch "send me the current snapshot" pull in the `sendMessage` reply handler.
///  - Watch actions arrive via `didReceiveMessage` / `didReceiveUserInfo`; they are ordered by the
///    Core conflict rule and applied through the EXISTING `NurseStore` paths, then the fresh
///    snapshot is pushed back.
///
/// No networking beyond WatchConnectivity — the app's no-server property is untouched.
@MainActor
@Observable
final class WatchSyncCoordinator: NSObject {
    private unowned let store: NurseStore

    // MARK: Diagnostics (item 2g) — the phone mirror the Settings screen reads.
    var lastPushAt: Date?
    var lastPushOutcome: String = "—"
    var lastError: String?
    var activationDescription: String = "not activated"
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false

    init(store: NurseStore) {
        self.store = store
        super.init()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { activationDescription = "unsupported"; return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #else
        activationDescription = "unsupported (no WatchConnectivity)"
        #endif
    }

    // MARK: Snapshot build + push

    /// Build the current snapshot from the store's active, non-archived tasks. Paused/muted tasks
    /// are included (the watch renders them with parity status and the shared planner excludes them
    /// exactly like the phone); archived tasks never leave the phone.
    func buildSnapshot() -> SyncSnapshot {
        let settings = store.settings()
        let tasks = store.planningTasks()
            .filter { !$0.isArchived }
            .map { SyncTask(careTask: $0) }
        return SyncSnapshot(
            generatedAt: .now, tasks: tasks,
            privacyMode: settings.privacyModeNotifications,
            settings: settings.schedulerSettings)
    }

    /// Encode the snapshot to plist-safe `Data`, surfacing (not swallowing) an encode failure.
    private func encodedSnapshot() -> Data? {
        do {
            return try JSONEncoder().encode(buildSnapshot())
        } catch {
            let msg = "snapshot encode failed: \(error.localizedDescription)"
            AppLog.notifications.error("\(msg, privacy: .public)")
            lastError = msg
            lastPushOutcome = "encode error"
            return nil
        }
    }

    /// Push the latest snapshot. Called from `NurseStore.replan()` (every commit) and on
    /// activation / watch-state / reachability changes.
    func pushSnapshot(reason: String = "commit") {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        refreshState(session)
        guard session.activationState == .activated else {
            lastPushOutcome = "skipped: not activated (\(reason))"
            return
        }
        guard let data = encodedSnapshot() else { return }
        do {
            // `Data` is a property-list type, so the context payload is always plist-safe.
            try session.updateApplicationContext([Self.snapshotKey: data])
            lastPushAt = .now
            lastPushOutcome = "context ok (\(reason), \(data.count)B)"
            lastError = nil
        } catch {
            // Durable fallback — WC persists and retries this across launches.
            AppLog.notifications.error("applicationContext push failed: \(error.localizedDescription, privacy: .public)")
            session.transferUserInfo([Self.snapshotKey: data])
            lastPushAt = .now
            lastPushOutcome = "context failed → transferUserInfo (\(reason))"
            lastError = error.localizedDescription
        }
        #endif
    }

    static let snapshotKey = "snapshot"
    static let actionsKey = "actions"
    static let requestKey = "requestSnapshot"

    #if canImport(WatchConnectivity)
    private func refreshState(_ session: WCSession) {
        switch session.activationState {
        case .activated:      activationDescription = "activated"
        case .inactive:       activationDescription = "inactive"
        case .notActivated:   activationDescription = "notActivated"
        @unknown default:     activationDescription = "unknown"
        }
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }
    #endif

    // MARK: Incoming watch actions

    private func applyIncoming(_ data: Data) {
        guard let batch = try? JSONDecoder().decode(SyncActionBatch.self, from: data) else {
            lastError = "could not decode watch action batch"
            AppLog.notifications.error("Could not decode watch action batch")
            return
        }
        // Conflict rule §5.3: last-by-timestamp wins; Given supersedes Snooze at equal time.
        for action in SyncConflictResolver.applicationOrder(batch.actions) { apply(action) }
        // Each apply() commits→replans→pushes a fresh snapshot, so the watch reconciles.
    }

    private func apply(_ action: SyncAction) {
        guard let task = store.task(withID: action.taskID) else { return }
        switch action.kind {
        case .given:    store.markGivenOrDone(task, at: action.timestamp)
        case .snooze:   store.snooze(task, at: action.timestamp)
        case .skipOnce: store.skip(task, source: action.source, at: action.timestamp)
        }
    }
}

#if canImport(WatchConnectivity)
extension WatchSyncCoordinator: WCSessionDelegate {
    // WC delegate callbacks arrive off the main actor; hop to @MainActor before touching the store,
    // carrying only Sendable payloads across the boundary.

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        // Push the current state as soon as the session is up — a watch installed after the last
        // commit is populated immediately (item 2b, the most likely first-snapshot root cause).
        Task { @MainActor in
            if let error { self.lastError = "activation: \(error.localizedDescription)" }
            self.pushSnapshot(reason: "activation")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // reactivate for the next paired watch (Apple's required dance)
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        // isPaired / isWatchAppInstalled just changed — a newly-installed watch needs the snapshot
        // NOW rather than at the next commit (item 2b).
        Task { @MainActor in self.pushSnapshot(reason: "watchStateChanged") }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // A watch pull (item 2c): reply with the full snapshot in the reply handler.
        if message[Self.requestKey] != nil {
            Task { @MainActor in
                if let data = self.encodedSnapshot() {
                    self.lastPushAt = .now
                    self.lastPushOutcome = "replied to pull (\(data.count)B)"
                    replyHandler([Self.snapshotKey: data])
                } else {
                    replyHandler(["error": "encode"])
                }
            }
            return
        }
        if let data = message[Self.actionsKey] as? Data {
            Task { @MainActor in self.applyIncoming(data) }
        }
        replyHandler(["ack": true])
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[Self.actionsKey] as? Data {
            Task { @MainActor in self.applyIncoming(data) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushSnapshot(reason: "reachabilityChanged") }
    }
}
#endif

// MARK: - CareTask → SyncTask

private extension SyncTask {
    @MainActor
    init(careTask t: CareTask) {
        self.init(
            id: t.id,
            room: t.patient?.roomNumber ?? "",
            firstName: t.patient?.firstName,
            title: t.title,
            dosage: t.dosage,
            route: t.route,
            kind: t.kind,
            scheduleData: t.scheduleData,   // raw stored bytes — decodes to .needsRepair on corruption, parity with phone
            lastCompletedAt: t.lastCompletedAt,
            nextDueAt: t.nextDueAt,
            leadTimeMinutes: t.leadTimeMinutes,
            snoozeMinutes: t.snoozeMinutes,
            isPaused: t.isPaused,
            notificationsEnabled: t.notificationsEnabled,
            isArchived: t.isArchived,
            explicitSnoozeAt: t.explicitSnoozeAt,
            colorTagRaw: t.colorTagRaw,
            prnFrequencyText: t.prnFrequencyText)
    }
}

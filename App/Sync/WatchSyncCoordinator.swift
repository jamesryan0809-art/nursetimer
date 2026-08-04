import Foundation
import NurseTimerCore
import NurseTimerModels
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone side of the phone↔watch link (BUILD_SPEC §5.3). The phone is the source of truth:
///
///  - On every store commit it pushes a full versioned `SyncSnapshot` to the watch via
///    `updateApplicationContext` (always-latest, coalescing), with `transferUserInfo` as the
///    durable fallback when the context payload is rejected (too large / not yet paired).
///  - Watch actions arrive via `didReceiveMessage` (reachable) or `didReceiveUserInfo` (queued);
///    they are ordered by the Core conflict rule and applied through the EXISTING `NurseStore`
///    paths, so TaskEvents, on-phone toasts, replanning, and the transactional commit guarantees
///    all apply unchanged. Applying an action commits → replans → pushes the fresh snapshot back.
///
/// No networking beyond WatchConnectivity — the app's no-server property is untouched.
@MainActor
final class WatchSyncCoordinator: NSObject {
    private unowned let store: NurseStore

    init(store: NurseStore) {
        self.store = store
        super.init()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    // MARK: Snapshot push

    /// Build the current snapshot from the store's active, non-archived tasks. Paused/muted
    /// tasks are included (the watch renders them with parity status and the shared planner
    /// excludes them from reminders exactly like the phone); archived tasks never leave the phone.
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

    /// Push the latest snapshot. Called from `NurseStore.replan()` after every commit.
    func pushSnapshot() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(buildSnapshot()) else { return }
        do {
            // Latest-state channel: the OS coalesces to the newest, ideal for "current snapshot".
            try session.updateApplicationContext([Self.snapshotKey: data])
        } catch {
            // Durable fallback for an oversized/queued payload — WC persists and retries this.
            AppLog.notifications.error("applicationContext push failed: \(error.localizedDescription, privacy: .public)")
            session.transferUserInfo([Self.snapshotKey: data])
        }
        #endif
    }

    static let snapshotKey = "snapshot"
    static let actionsKey = "actions"

    // MARK: Incoming watch actions

    private func applyIncoming(_ data: Data) {
        guard let batch = try? JSONDecoder().decode(SyncActionBatch.self, from: data) else {
            AppLog.notifications.error("Could not decode watch action batch")
            return
        }
        // Conflict rule §5.3: last-by-timestamp wins; Given supersedes Snooze at equal time.
        for action in SyncConflictResolver.applicationOrder(batch.actions) {
            apply(action)
        }
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
    // carrying only the Sendable `Data` payload across the boundary.

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        // On (re)activation, push the current state so a freshly-paired watch is populated at once.
        Task { @MainActor in self.pushSnapshot() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate for the next paired watch (Apple's required re-activation dance).
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        if let data = message[Self.actionsKey] as? Data {
            Task { @MainActor in self.applyIncoming(data) }
        }
        replyHandler(["ack": true])   // lets the watch mark the send delivered
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo[Self.actionsKey] as? Data {
            Task { @MainActor in self.applyIncoming(data) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // When the watch becomes reachable, re-push so it can't sit on a stale snapshot.
        Task { @MainActor in self.pushSnapshot() }
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

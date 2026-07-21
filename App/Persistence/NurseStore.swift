import Foundation
import Observation
import SwiftData
import NurseTimerCore
import NurseTimerModels

/// The application-data layer: the single place that mutates persistence, keeps
/// `nextDueAt` in sync with Core's scheduling engine, and re-runs the
/// `NotificationPlanner` after every relevant change.
///
/// One damaged task never blocks the rest: reads tolerate `.needsRepair` (which
/// Core surfaces per-task), and such a task schedules nothing until repaired.
@MainActor
@Observable
final class NurseStore {
    private let context: ModelContext
    private let scheduler: NotificationScheduling
    private let calendar = Calendar.autoupdatingCurrent

    /// Non-fatal problems surfaced to the UI (never silently dropped).
    var banner: AppBanner?
    /// Task ids Core reports as needing schedule repair (drives Board pinning).
    var tasksNeedingRepair: Set<UUID> = []
    /// Whether the last plan coalesced/trimmed to fit the budget (drives the banner).
    var lastPlanWasCoalesced = false
    /// Non-blocking reduction indicator state (feedback item 2). Replaces the top-of-screen
    /// reduction banner: a one-time-per-change alert plus a persistent nav-bar indicator read
    /// this instead. Persistence-error banners are unaffected and keep their priority.
    var reduction = ReductionState()
    /// Deep-link intent from a notification tap (root view observes it).
    var route: AppRoute?
    /// Centralized Add/Edit/Repair task presentation (root presents the sheet).
    var editRequest: TaskEditTarget?
    /// Centralized tap-to-act task-detail presentation (root presents the sheet). Any task
    /// row across Board / patient detail / Schedule / Grid sets this to open the action sheet.
    var taskDetailRequest: TaskDetailTarget?

    func task(withID id: UUID) -> CareTask? {
        fetch(FetchDescriptor<CareTask>(predicate: #Predicate { $0.id == id }), "task").first
    }

    init(context: ModelContext, scheduler: NotificationScheduling) {
        self.context = context
        self.scheduler = scheduler
        _ = settings()   // ensure the singleton settings row exists
    }

    // MARK: Diagnostics + fetch (item 7)

    /// Set a banner without letting a lower-priority message hide a visible higher one —
    /// a persistence error is never immediately overwritten by a reduction/coalescing info.
    private func setBanner(_ new: AppBanner) {
        if let current = banner, current.level.rank > new.level.rank { return }
        banner = new
    }

    /// Fetch that SURFACES errors instead of masquerading them as valid-empty data. On
    /// failure it logs, shows a banner, and returns [] as an explicit degraded state.
    private func fetch<T>(_ descriptor: FetchDescriptor<T>, _ what: String) -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLog.persistence.error("Fetch \(what, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            setBanner(.loadFailed(what))
            return []
        }
    }

    // MARK: Settings

    func settings() -> AppSettings {
        if let existing = fetch(FetchDescriptor<AppSettings>(), "settings").first {
            return existing
        }
        // No row yet — create and persist. If persistence fails, degrade to an in-memory
        // instance (explicit degraded state) and surface the error; never crash, never
        // pretend the empty fetch was valid.
        let created = AppSettings()
        context.insert(created)
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Could not create settings row: \(error.localizedDescription, privacy: .public)")
            setBanner(.saveFailed)
        }
        return created
    }

    private var schedulerSettings: SchedulerSettings { settings().schedulerSettings }

    // MARK: Fetches

    func activePatients() -> [Patient] {
        fetch(FetchDescriptor<Patient>(), "patients")
            .filter { $0.isActive }
            .sorted { $0.roomNumber.localizedStandardCompare($1.roomNumber) == .orderedAscending }
    }

    func archivedPatients() -> [Patient] {
        fetch(FetchDescriptor<Patient>(), "patients").filter { !$0.isActive }
    }

    /// Every task belonging to an active patient — Core filters paused / needsRepair.
    func planningTasks() -> [CareTask] {
        fetch(FetchDescriptor<CareTask>(), "tasks").filter { $0.patient?.isActive == true }
    }

    // MARK: Task lifecycle

    /// Given/Done is valid at ANY time (early, on time, or late) and always records the actual
    /// completion time. It completes the current upcoming occurrence and advances the schedule
    /// per Core's anchoring rules; passing `currentDue` lets fixed-time schedules advance past
    /// an EARLY completion instead of re-resolving to the same occurrence (feedback item 5).
    /// The subsequent `commit()`→`replan()` cancels this occurrence's pending pre/due/taper
    /// notifications (cancel-all-then-reschedule from the new `nextDueAt`).
    func markGivenOrDone(_ task: CareTask, at date: Date = .now, note: String? = nil) {
        guard !task.scheduleType.isNeedsRepair else { return }
        let action: TaskAction = task.kind == .medication ? .given : .done
        record(action, on: task, at: date, note: note)
        let schedule = task.scheduleType
        let occurrenceDue = task.nextDueAt
        task.lastCompletedAt = date
        task.nextDueAt = SchedulingEngine.nextDueAfterCompletion(
            schedule: schedule, completedAt: date, currentDue: occurrenceDue, calendar: calendar)
        if SchedulingEngine.shouldAutoPauseAfterCompletion(schedule) { task.isPaused = true }
        task.explicitSnoozeAt = nil
        task.updatedAt = date
        commit()
    }

    /// Re-ping chain re-anchors to now via `explicitSnoozeAt`; `nextDueAt` is unchanged
    /// (the dose is still conceptually due at its original time).
    func snooze(_ task: CareTask, at date: Date = .now) {
        guard !task.scheduleType.isNeedsRepair else { return }
        record(.snoozed, on: task, at: date)
        task.explicitSnoozeAt = date
        task.updatedAt = date
        commit()
    }

    /// Skip Once: advance the schedule one occurrence without recording an
    /// administration. The note records the SOURCE only ("in app" / "via notification"
    /// / "via watch") — the chart is the system of record for clinical reasons.
    func skip(_ task: CareTask, source: String, at date: Date = .now) {
        guard !task.scheduleType.isNeedsRepair else { return }
        record(.skipped, on: task, at: date, note: source)
        let schedule = task.scheduleType
        task.nextDueAt = SchedulingEngine.nextDueAfterCompletion(
            schedule: schedule, completedAt: date, currentDue: task.nextDueAt, calendar: calendar)
        if SchedulingEngine.shouldAutoPauseAfterCompletion(schedule) { task.isPaused = true }
        task.explicitSnoozeAt = nil
        task.updatedAt = date
        commit()
    }

    /// Pause: hold the task (no reminders until resumed), record a `.paused` event with
    /// the source, and cancel its pending notifications (replan excludes paused tasks).
    /// Always confirmed in the UI.
    func pause(_ task: CareTask, source: String, at date: Date = .now) {
        task.isPaused = true
        task.explicitSnoozeAt = nil
        record(.paused, on: task, at: date, note: source)
        task.updatedAt = date
        commit()
    }

    /// Resume (and other non-event pause toggles).
    func setPaused(_ task: CareTask, _ paused: Bool) {
        task.isPaused = paused
        task.updatedAt = .now
        commit()
    }

    /// Mute / unmute a task's reminders (feedback item 2). The planner excludes muted tasks
    /// like paused ones; a commit replans so pending reminders are dropped/restored at once.
    func setNotificationsEnabled(_ task: CareTask, _ enabled: Bool) {
        task.notificationsEnabled = enabled
        task.updatedAt = .now
        commit()
    }

    func acknowledgeMissed(_ task: CareTask, at date: Date = .now) {
        record(.missedAcknowledged, on: task, at: date)
        commit()
    }

    /// Apply a nurse-selected repair: fresh valid schedule + fresh nextDueAt, and
    /// remove the task's pending repair warning (spec §6.2/§6.3).
    func repair(_ task: CareTask, with schedule: ScheduleType, anchor: Date) {
        task.repair(with: schedule, anchor: anchor, calendar: calendar)
        scheduler.removeRepairWarning(taskID: task.id)
        commit()
    }

    private func record(_ action: TaskAction, on task: CareTask, at date: Date, note: String? = nil) {
        let event = TaskEvent(taskID: task.id, action: action, timestamp: date, note: note)
        event.task = task
        context.insert(event)
    }

    // MARK: Patient CRUD

    @discardableResult
    func addPatient(roomNumber: String, firstName: String?, notes: String?) -> Patient {
        let now = Date.now
        let patient = Patient(roomNumber: roomNumber, firstName: firstName, notes: notes,
                              isActive: true, createdAt: now, updatedAt: now)
        context.insert(patient)
        commit()
        return patient
    }

    func updatePatient(_ patient: Patient, roomNumber: String, firstName: String?, notes: String?) {
        patient.roomNumber = roomNumber
        patient.firstName = firstName
        patient.notes = notes
        patient.updatedAt = .now
        commit()
    }

    func setPatientActive(_ patient: Patient, _ active: Bool) {
        patient.isActive = active
        patient.updatedAt = .now
        commit()   // replan drops an archived patient's notifications automatically
    }

    func deletePatient(_ patient: Patient) {
        context.delete(patient)   // cascade removes tasks + events
        commit()
    }

    /// True if another active patient already occupies this room (spec §8 warn-on-save).
    func roomIsOccupied(_ room: String, excluding patient: Patient? = nil) -> Bool {
        activePatients().contains { $0.roomNumber == room && $0.id != patient?.id }
    }

    // MARK: Task CRUD

    /// `firstDueOverride` (feedback item 1): when set, it becomes the initial `nextDueAt`
    /// directly — a synthetic first-due the nurse chose (interval + no last-given case). It
    /// does NOT fabricate a `lastCompletedAt`; no administration event is invented. Subsequent
    /// dosing follows normal interval math from actual given times.
    @discardableResult
    func addTask(to patient: Patient, kind: TaskKind, title: String, dosage: String?, route: String?,
                 schedule: ScheduleType, lastGiven: Date?, leadTimeMinutes: Int?, snoozeMinutes: Int?,
                 colorTag: TaskColorTag = .none, notificationsEnabled: Bool = true,
                 prnFrequencyText: String = "", firstDueOverride: Date? = nil) -> CareTask {
        let task = CareTask(kind: kind, title: title, dosage: dosage, route: route,
                            scheduleType: schedule, leadTimeMinutes: leadTimeMinutes, snoozeMinutes: snoozeMinutes,
                            colorTagRaw: colorTag.rawValue, notificationsEnabled: notificationsEnabled,
                            prnFrequencyText: prnFrequencyText)
        task.patient = patient
        task.lastCompletedAt = lastGiven   // stays nil when there's no last-given — never fabricated
        task.nextDueAt = firstDueOverride
            ?? SchedulingEngine.firstDue(for: schedule, anchor: lastGiven ?? .now, calendar: calendar)
        context.insert(task)
        commit()
        return task
    }

    /// Item 9 — Last-Given edit coherence. `lastGiven` reflects the form's toggle:
    /// non-nil = submitted value, nil = cleared. Rules:
    ///  - A submitted Last Given updates `lastCompletedAt` REGARDLESS of a schedule change.
    ///  - Clearing it sets `lastCompletedAt = nil`.
    ///  - `nextDueAt` recomputes via the SAME Core path as creation (`firstDue`) whenever the
    ///    schedule or the anchor changed, anchored to `lastGiven ?? now`.
    ///  - schedule, anchor, lastCompletedAt, and nextDueAt commit atomically (item 7).
    func updateTask(_ task: CareTask, kind: TaskKind, title: String, dosage: String?, route: String?,
                    schedule: ScheduleType, lastGiven: Date?, leadTimeMinutes: Int?, snoozeMinutes: Int?,
                    colorTag: TaskColorTag = .none, notificationsEnabled: Bool = true,
                    prnFrequencyText: String = "", firstDueOverride: Date? = nil) {
        let priorLastGiven = task.lastCompletedAt
        let scheduleChanged = task.scheduleType != schedule
        let anchorChanged = lastGiven != priorLastGiven

        task.kindRaw = kind.rawValue
        task.title = title
        task.dosage = dosage
        task.route = route
        task.leadTimeMinutes = leadTimeMinutes
        task.snoozeMinutes = snoozeMinutes
        task.colorTagRaw = colorTag.rawValue      // display-only tag channel (color-tag pass)
        task.notificationsEnabled = notificationsEnabled   // muted-task switch (feedback item 2)
        task.prnFrequencyText = prnFrequencyText   // display-only PRN guidance (feedback item 3)
        task.scheduleType = schedule
        task.lastCompletedAt = lastGiven          // always reflect the form (submit or clear)

        if let firstDueOverride {
            // Nurse-set synthetic first-due (feedback item 1) — set nextDueAt directly, no
            // fabricated lastCompletedAt.
            task.explicitSnoozeAt = nil
            task.nextDueAt = firstDueOverride
        } else if scheduleChanged || anchorChanged {
            task.explicitSnoozeAt = nil
            task.nextDueAt = SchedulingEngine.firstDue(for: schedule, anchor: lastGiven ?? .now, calendar: calendar)
        }
        task.updatedAt = .now
        commit()
    }

    func deleteTask(_ task: CareTask) {
        scheduler.removeRepairWarning(taskID: task.id)
        context.delete(task)
        commit()
    }

    // MARK: Save + replan

    /// Transactional commit (item 7): persist FIRST, then replan **exactly once**. On save
    /// failure, roll back the in-memory mutation (restore last-saved state), surface the
    /// error, and DO NOT replan — existing scheduled notifications are left untouched, so
    /// they never reflect never-persisted state.
    func commit() {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Save failed: \(error.localizedDescription, privacy: .public)")
            context.rollback()          // discard the failed mutation
            setBanner(.saveFailed)
            return                      // no replan; scheduler untouched
        }
        replan()
    }

    /// Persist a UI preference (e.g., last-used Schedule mode) WITHOUT replanning —
    /// preferences don't affect reminders.
    func persistPreferences() {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Could not save preferences: \(error.localizedDescription, privacy: .public)")
            setBanner(.saveFailed)
        }
    }

    func replan() {
        let tasks = planningTasks()
        scheduler.privacyMode = settings().privacyModeNotifications
        let plan = NotificationPlanner.plan(tasks: tasks, settings: schedulerSettings, now: .now, calendar: calendar)
        let displays = Dictionary(tasks.map { ($0.id, TaskDisplay(task: $0)) }, uniquingKeysWith: { a, _ in a })
        tasksNeedingRepair = Set(plan.tasksNeedingRepair)
        lastPlanWasCoalesced = plan.planWasCoalesced
        // Feedback item 2: reduction is no longer a top-of-screen banner (it obstructed
        // controls). It now drives a non-blocking, one-time-per-change alert plus a persistent
        // nav-bar indicator, via `reduction`. Persistence errors keep the banner + their priority.
        reduction = ReductionState(
            isActive: plan.planWasReduced,
            coalesced: plan.planWasCoalesced,
            groupCount: plan.coalescedGroupCount,
            trimmed: plan.wasTrimmed)
        scheduler.apply(plan: plan, displays: displays)
    }

    // MARK: Destructive maintenance (used by Settings in Milestone 3)

    func clearLog() {
        for event in fetch(FetchDescriptor<TaskEvent>(), "log") { context.delete(event) }
        commit()
    }

    func deleteAllData() {
        for patient in fetch(FetchDescriptor<Patient>(), "patients") { context.delete(patient) }
        for event in fetch(FetchDescriptor<TaskEvent>(), "log") { context.delete(event) }
        scheduler.removeAll()
        commit()
    }
}

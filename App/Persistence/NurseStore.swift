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
    /// Deep-link intent from a notification tap (root view observes it).
    var route: AppRoute?
    /// Centralized Add/Edit/Repair task presentation (root presents the sheet).
    var editRequest: TaskEditTarget?

    func task(withID id: UUID) -> CareTask? {
        let descriptor = FetchDescriptor<CareTask>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    init(context: ModelContext, scheduler: NotificationScheduling) {
        self.context = context
        self.scheduler = scheduler
        _ = settings()   // ensure the singleton settings row exists
    }

    // MARK: Settings

    func settings() -> AppSettings {
        if let existing = try? context.fetch(FetchDescriptor<AppSettings>()).first {
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        try? context.save()
        return created
    }

    private var schedulerSettings: SchedulerSettings { settings().schedulerSettings }

    // MARK: Fetches

    func activePatients() -> [Patient] {
        let all = (try? context.fetch(FetchDescriptor<Patient>())) ?? []
        return all.filter { $0.isActive }.sorted { $0.roomNumber.localizedStandardCompare($1.roomNumber) == .orderedAscending }
    }

    func archivedPatients() -> [Patient] {
        let all = (try? context.fetch(FetchDescriptor<Patient>())) ?? []
        return all.filter { !$0.isActive }
    }

    /// Every task belonging to an active patient — Core filters paused / needsRepair.
    func planningTasks() -> [CareTask] {
        let all = (try? context.fetch(FetchDescriptor<CareTask>())) ?? []
        return all.filter { $0.patient?.isActive == true }
    }

    // MARK: Task lifecycle

    func markGivenOrDone(_ task: CareTask, at date: Date = .now, note: String? = nil) {
        guard !task.scheduleType.isNeedsRepair else { return }
        let action: TaskAction = task.kind == .medication ? .given : .done
        record(action, on: task, at: date, note: note)
        task.lastCompletedAt = date
        let schedule = task.scheduleType
        task.nextDueAt = SchedulingEngine.nextDueAfterCompletion(schedule: schedule, completedAt: date, calendar: calendar)
        if SchedulingEngine.shouldAutoPauseAfterCompletion(schedule) { task.isPaused = true }
        task.explicitSnoozeAt = nil
        commit()
    }

    /// Re-ping chain re-anchors to now via `explicitSnoozeAt`; `nextDueAt` is unchanged
    /// (the dose is still conceptually due at its original time).
    func snooze(_ task: CareTask, at date: Date = .now) {
        guard !task.scheduleType.isNeedsRepair else { return }
        record(.snoozed, on: task, at: date)
        task.explicitSnoozeAt = date
        commit()
    }

    /// Skip advances the schedule WITHOUT recording an administration.
    func skip(_ task: CareTask, reason: String? = nil, at date: Date = .now) {
        guard !task.scheduleType.isNeedsRepair else { return }
        record(.skipped, on: task, at: date, note: reason)
        let schedule = task.scheduleType
        task.nextDueAt = SchedulingEngine.nextDueAfterCompletion(schedule: schedule, completedAt: date, calendar: calendar)
        if SchedulingEngine.shouldAutoPauseAfterCompletion(schedule) { task.isPaused = true }
        task.explicitSnoozeAt = nil
        commit()
    }

    func setPaused(_ task: CareTask, _ paused: Bool) {
        task.isPaused = paused
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

    @discardableResult
    func addTask(to patient: Patient, kind: TaskKind, title: String, dosage: String?, route: String?,
                 schedule: ScheduleType, lastGiven: Date?, leadTimeMinutes: Int?, snoozeMinutes: Int?) -> CareTask {
        let task = CareTask(kind: kind, title: title, dosage: dosage, route: route,
                            scheduleType: schedule, leadTimeMinutes: leadTimeMinutes, snoozeMinutes: snoozeMinutes)
        task.patient = patient
        task.lastCompletedAt = lastGiven
        task.nextDueAt = SchedulingEngine.firstDue(for: schedule, anchor: lastGiven ?? .now, calendar: calendar)
        context.insert(task)
        commit()
        return task
    }

    func updateTask(_ task: CareTask, kind: TaskKind, title: String, dosage: String?, route: String?,
                    schedule: ScheduleType, lastGiven: Date?, leadTimeMinutes: Int?, snoozeMinutes: Int?) {
        let scheduleChanged = task.scheduleType != schedule
        task.kindRaw = kind.rawValue
        task.title = title
        task.dosage = dosage
        task.route = route
        task.leadTimeMinutes = leadTimeMinutes
        task.snoozeMinutes = snoozeMinutes
        if scheduleChanged {
            task.scheduleType = schedule
            task.explicitSnoozeAt = nil
            task.nextDueAt = SchedulingEngine.firstDue(for: schedule, anchor: lastGiven ?? .now, calendar: calendar)
        } else if let lastGiven { task.lastCompletedAt = lastGiven }
        commit()
    }

    func deleteTask(_ task: CareTask) {
        scheduler.removeRepairWarning(taskID: task.id)
        context.delete(task)
        commit()
    }

    // MARK: Save + replan

    /// Persist, then recompute the entire notification plan. Persistence and
    /// scheduling failures are surfaced, never swallowed.
    func commit() {
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Save failed: \(error.localizedDescription, privacy: .public)")
            banner = .persistenceError(error.localizedDescription)
        }
        replan()
    }

    func replan() {
        let tasks = planningTasks()
        let plan = NotificationPlanner.plan(tasks: tasks, settings: schedulerSettings, now: .now, calendar: calendar)
        let displays = Dictionary(tasks.map { ($0.id, TaskDisplay(task: $0)) }, uniquingKeysWith: { a, _ in a })
        tasksNeedingRepair = Set(plan.tasksNeedingRepair)
        lastPlanWasCoalesced = plan.planWasCoalesced
        if plan.planWasCoalesced { banner = .planCoalesced(groupCount: plan.coalescedGroupCount) }
        scheduler.apply(plan: plan, displays: displays)
    }

    // MARK: Destructive maintenance (used by Settings in Milestone 3)

    func clearLog() {
        let events = (try? context.fetch(FetchDescriptor<TaskEvent>())) ?? []
        events.forEach { context.delete($0) }
        commit()
    }

    func deleteAllData() {
        for patient in (try? context.fetch(FetchDescriptor<Patient>())) ?? [] { context.delete(patient) }
        for event in (try? context.fetch(FetchDescriptor<TaskEvent>())) ?? [] { context.delete(event) }
        scheduler.removeAll()
        commit()
    }
}

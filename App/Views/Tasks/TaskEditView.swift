import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// What the Add/Edit/Repair task sheet is doing.
enum TaskEditTarget: Identifiable {
    case add(Patient, TaskKind)
    case edit(CareTask)
    case repair(CareTask)

    var id: String {
        switch self {
        case .add(let p, let k): "add-\(k.rawValue)-\(p.id.uuidString)"
        case .edit(let t):       "edit-\(t.id.uuidString)"
        case .repair(let t):     "repair-\(t.id.uuidString)"
        }
    }
    var isRepair: Bool { if case .repair = self { return true }; return false }
}

private let genericQuickPicks = ["Turn/reposition", "Vitals", "I&O", "Blood glucose", "Ambulate"]

/// Add/Edit Task form (spec §6.2). In repair mode all data is preserved but the
/// schedule field starts empty and is required; saving establishes a fresh nextDueAt.
struct TaskEditView: View {
    @Environment(NurseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: TaskEditTarget

    @State private var kind: TaskKind = .medication
    @State private var title = ""
    @State private var dosage = ""
    @State private var route = ""
    @State private var draft = ScheduleDraft()
    @State private var setLastGiven = false
    @State private var lastGiven = Date.now
    // Reminders (feedback item 2) — prefilled from the Settings defaults; a changed value
    // becomes a per-task override, an unchanged one keeps following the default.
    @State private var notificationsEnabled = true
    @State private var leadMinutes = 15
    @State private var repingMinutes = 3
    @State private var colorTag: TaskColorTag = .none
    @State private var prnFrequency = ""
    // Adjustable first reminder (feedback item 1) — interval + no-last-given only.
    @State private var firstReminder = Date.now
    @State private var firstReminderCustom = false
    @State private var confirmingDelete = false

    private var settings: AppSettings { store.settings() }

    /// The task being edited, for the Delete action (feedback pass 4, item 1); nil for add/repair.
    private var editingTask: CareTask? { if case .edit(let t) = target { return t }; return nil }

    private var titlePlaceholder: String {
        switch kind {
        case .medication: return "Medication name"
        case .generic:    return "Task label"
        case .reminder:   return "Reminder (e.g. call family)"
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.scheduleType != nil
            && (draft.mode != .interval || draft.intervalIsValid)
    }

    var body: some View {
        Form {
            if target.isRepair {
                Section {
                    Label("This task's schedule couldn't be loaded. Pick a new schedule to fix it — everything else is kept.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            // Form order (feedback item 4): Reminders → name (type + title) → schedule →
            // PRN frequency (when applicable) → last given → Details (dosage, route) → color tag.
            remindersSection

            Section("Type") {
                Picker("Type", selection: $kind) {
                    Text("Medication").tag(TaskKind.medication)
                    Text("Care task").tag(TaskKind.generic)
                    Text("Reminder").tag(TaskKind.reminder)
                }.pickerStyle(.segmented)
            }

            Section("Title") {
                TextField(titlePlaceholder, text: $title)
                if kind == .generic {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(genericQuickPicks, id: \.self) { pick in
                                Button(pick) { title = pick }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                }
            }

            SchedulePickerView(draft: $draft, requireSelection: target.isRepair,
                               lastGiven: setLastGiven ? lastGiven : nil,
                               firstReminder: $firstReminder, firstReminderCustom: $firstReminderCustom)

            if draft.mode == .prn && kind != .reminder {
                Section {
                    TextField("e.g. every 4–6 hrs as needed", text: $prnFrequency, axis: .vertical)
                } header: {
                    Text("Frequency")
                } footer: {
                    Text("A note you'll read on the card — the app never enforces it, times it, or alerts from it. You decide when to give.")
                }
            }

            Section("Last given (optional)") {
                Toggle("Set last-given time", isOn: $setLastGiven)
                if setLastGiven { DatePicker("Last given", selection: $lastGiven) }
            }

            if kind == .medication {
                Section("Details") {
                    TextField("Dosage (e.g. 25 mg PO)", text: $dosage)
                    TextField("Route (optional)", text: $route)
                }
            }

            Section {
                ColorTagPicker(selection: $colorTag)
            } header: {
                Text("Color tag")
            } footer: {
                Text("A visual label to group meds at a glance. Separate from the red/orange/green urgency colors — it never changes how urgent a task looks.")
            }

            // Delete (feedback pass 4, item 1) — edit only; add/repair have nothing to delete.
            if let task = editingTask {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete Task", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                }
                .confirmationDialog("Delete this task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { store.deleteTask(task); dismiss() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Rm \(task.patient?.roomNumber ?? "?") · \(task.title) — this permanently removes the task and its log history, and cancels its reminders. This can't be undone.")
                }
            }
        }
        .navigationTitle(navTitle)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
        }
        .onAppear(perform: load)
    }

    /// Reminders — promoted to the TOP of the form (feedback item 2). Lead time and re-ping
    /// interval are the per-task overrides, prefilled from the Settings defaults; the
    /// Notifications toggle mutes the task without deleting it.
    private var remindersSection: some View {
        Section {
            Toggle("Notifications", isOn: $notificationsEnabled)
            if notificationsEnabled {
                Stepper("Notify me \(leadMinutes) min before due",
                        value: $leadMinutes, in: 5...60, step: 5)
                Stepper("If I don't respond, re-ping every \(repingMinutes) min",
                        value: $repingMinutes, in: 1...15)
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text(notificationsEnabled
                 ? "Defaults come from Settings; changing a value here overrides it for this task only."
                 : "Muted — this task stays on your lists but won't notify you.")
        }
    }

    private var navTitle: String {
        switch target {
        case .add: "Add Task"
        case .edit: "Edit Task"
        case .repair: "Fix Schedule"
        }
    }

    private func load() {
        // Prefill reminder controls from the global defaults; an existing task's overrides win.
        leadMinutes = settings.defaultLeadTimeMinutes
        repingMinutes = settings.defaultSnoozeMinutes
        switch target {
        case .add(_, let presetKind):
            kind = presetKind   // "Add Medication" / "Add Task" preset the type
        case .edit(let task), .repair(let task):
            kind = task.kind
            title = task.title
            dosage = task.dosage ?? ""
            route = task.route ?? ""
            if let lead = task.leadTimeMinutes { leadMinutes = lead }
            if let snz = task.snoozeMinutes { repingMinutes = snz }
            notificationsEnabled = task.notificationsEnabled
            prnFrequency = task.prnFrequencyText
            if let last = task.lastCompletedAt { setLastGiven = true; lastGiven = last }
            colorTag = task.colorTag
            // Repair starts with an EMPTY, required schedule; edit prefills it.
            if target.isRepair {
                draft = ScheduleDraft()
                draft.mode = nil
                setLastGiven = false   // fresh anchor for a fresh nextDueAt
            } else {
                draft = ScheduleDraft.from(task.scheduleType)
                // Seed the editable first-reminder from the task's actual scheduled first due
                // (interval + no last-given), so editing shows the real value rather than a
                // fresh now+interval. Not marked custom, so changing the interval re-defaults it.
                if draft.mode == .interval, task.lastCompletedAt == nil, let due = task.nextDueAt {
                    firstReminder = due
                }
            }
        }
    }

    private func save() {
        guard let schedule = draft.scheduleType else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let dose = kind == .medication ? dosage.nilIfBlank : nil
        let rte = kind == .medication ? route.nilIfBlank : nil
        // Store an override only when it differs from the current default, so a value left at
        // the default keeps tracking future Settings changes.
        let lead = leadMinutes == settings.defaultLeadTimeMinutes ? nil : leadMinutes
        let snooze = repingMinutes == settings.defaultSnoozeMinutes ? nil : repingMinutes
        let lastGivenValue = setLastGiven ? lastGiven : nil
        // Frequency guidance is only meaningful for PRN; clear it otherwise.
        let freq = draft.mode == .prn ? prnFrequency.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        // Nurse-adjusted first reminder (feedback item 1): only when interval + no last-given
        // AND the nurse actually set it — a synthetic first-due, never a fabricated last-given.
        let firstDueOverride: Date? =
            (draft.mode == .interval && !setLastGiven && firstReminderCustom) ? firstReminder : nil

        switch target {
        case .add(let patient, _):
            store.addTask(to: patient, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                          schedule: schedule, lastGiven: lastGivenValue,
                          leadTimeMinutes: lead, snoozeMinutes: snooze, colorTag: colorTag,
                          notificationsEnabled: notificationsEnabled, prnFrequencyText: freq,
                          firstDueOverride: firstDueOverride)
        case .edit(let task):
            store.updateTask(task, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                             schedule: schedule, lastGiven: lastGivenValue,
                             leadTimeMinutes: lead, snoozeMinutes: snooze, colorTag: colorTag,
                             notificationsEnabled: notificationsEnabled, prnFrequencyText: freq,
                             firstDueOverride: firstDueOverride)
        case .repair(let task):
            // Preserve the other edits, then apply the repair with a fresh anchor.
            store.updateTask(task, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                             schedule: task.scheduleType, lastGiven: nil,
                             leadTimeMinutes: lead, snoozeMinutes: snooze, colorTag: colorTag,
                             notificationsEnabled: notificationsEnabled, prnFrequencyText: freq)
            store.repair(task, with: schedule, anchor: lastGivenValue ?? .now)
        }
        dismiss()
    }
}

/// A horizontal row of tappable swatches for the per-med color tag (item 2). "None" is a
/// hollow slashed circle; the selected swatch gets a ring. Fixed palette from `TaskColorTag`.
private struct ColorTagPicker: View {
    @Binding var selection: TaskColorTag

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(TaskColorTag.allCases) { tag in
                    Button { selection = tag } label: { swatch(tag) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tag.displayName)
                        .accessibilityAddTraits(selection == tag ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func swatch(_ tag: TaskColorTag) -> some View {
        let isSelected = selection == tag
        ZStack {
            if let color = tag.color {
                Circle().fill(color)
            } else {
                Image(systemName: "slash.circle").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(
            Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
                .padding(-3)
        )
    }
}

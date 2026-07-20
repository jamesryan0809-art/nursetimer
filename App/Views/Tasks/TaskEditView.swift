import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// What the Add/Edit/Repair task sheet is doing.
enum TaskEditTarget: Identifiable {
    case add(Patient)
    case edit(CareTask)
    case repair(CareTask)

    var id: String {
        switch self {
        case .add(let p):    "add-\(p.id.uuidString)"
        case .edit(let t):   "edit-\(t.id.uuidString)"
        case .repair(let t): "repair-\(t.id.uuidString)"
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
    @State private var useLeadOverride = false
    @State private var leadOverride = 15
    @State private var useSnoozeOverride = false
    @State private var snoozeOverride = 3

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

            Section("Type") {
                Picker("Type", selection: $kind) {
                    Text("Medication").tag(TaskKind.medication)
                    Text("Care task").tag(TaskKind.generic)
                }.pickerStyle(.segmented)
            }

            Section("Title") {
                TextField(kind == .medication ? "Medication name" : "Task label", text: $title)
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

            if kind == .medication {
                Section("Medication") {
                    TextField("Dosage (e.g. 25 mg PO)", text: $dosage)
                    TextField("Route (optional)", text: $route)
                }
            }

            SchedulePickerView(draft: $draft, requireSelection: target.isRepair,
                               lastGiven: setLastGiven ? lastGiven : nil)

            Section("Last given (optional)") {
                Toggle("Set last-given time", isOn: $setLastGiven)
                if setLastGiven { DatePicker("Last given", selection: $lastGiven) }
            }

            Section {
                DisclosureGroup("Advanced") {
                    Toggle("Custom lead time", isOn: $useLeadOverride)
                    if useLeadOverride { Stepper("Lead: \(leadOverride) min", value: $leadOverride, in: 5...60, step: 5) }
                    Toggle("Custom snooze", isOn: $useSnoozeOverride)
                    if useSnoozeOverride { Stepper("Snooze: \(snoozeOverride) min", value: $snoozeOverride, in: 1...15) }
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

    private var navTitle: String {
        switch target {
        case .add: "Add Task"
        case .edit: "Edit Task"
        case .repair: "Fix Schedule"
        }
    }

    private func load() {
        switch target {
        case .add:
            break   // defaults
        case .edit(let task), .repair(let task):
            kind = task.kind
            title = task.title
            dosage = task.dosage ?? ""
            route = task.route ?? ""
            if let lead = task.leadTimeMinutes { useLeadOverride = true; leadOverride = lead }
            if let snz = task.snoozeMinutes { useSnoozeOverride = true; snoozeOverride = snz }
            if let last = task.lastCompletedAt { setLastGiven = true; lastGiven = last }
            // Repair starts with an EMPTY, required schedule; edit prefills it.
            if target.isRepair {
                draft = ScheduleDraft()
                draft.mode = nil
                setLastGiven = false   // fresh anchor for a fresh nextDueAt
            } else {
                draft = ScheduleDraft.from(task.scheduleType)
            }
        }
    }

    private func save() {
        guard let schedule = draft.scheduleType else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let dose = kind == .medication ? dosage.nilIfBlank : nil
        let rte = kind == .medication ? route.nilIfBlank : nil
        let lead = useLeadOverride ? leadOverride : nil
        let snooze = useSnoozeOverride ? snoozeOverride : nil
        let lastGivenValue = setLastGiven ? lastGiven : nil

        switch target {
        case .add(let patient):
            store.addTask(to: patient, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                          schedule: schedule, lastGiven: lastGivenValue,
                          leadTimeMinutes: lead, snoozeMinutes: snooze)
        case .edit(let task):
            store.updateTask(task, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                             schedule: schedule, lastGiven: lastGivenValue,
                             leadTimeMinutes: lead, snoozeMinutes: snooze)
        case .repair(let task):
            // Preserve the other edits, then apply the repair with a fresh anchor.
            store.updateTask(task, kind: kind, title: trimmedTitle, dosage: dose, route: rte,
                             schedule: task.scheduleType, lastGiven: nil,
                             leadTimeMinutes: lead, snoozeMinutes: snooze)
            store.repair(task, with: schedule, anchor: lastGivenValue ?? .now)
        }
        dismiss()
    }
}

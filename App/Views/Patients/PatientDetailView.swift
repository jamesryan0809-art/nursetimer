import SwiftUI
import NurseTimerCore
import NurseTimerModels

/// Patient detail — the working hub (spec §6.2). Primary Add Medication / Add Task, the
/// patient's day laid out chronologically with inline projected times (reusing the shared
/// projection + By-Patient time rendering), and full lifecycle actions on each task row.
struct PatientDetailView: View {
    @Environment(NurseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var patient: Patient
    @State private var editingPatient = false
    @State private var confirmingDelete = false

    private var settings: AppSettings { store.settings() }

    /// The patient's tasks of one kind, laid out chronologically for the day (PRN / no-due last).
    private func tasks(of kind: TaskKind) -> [CareTask] {
        patient.tasks
            .filter { $0.kind == kind }
            .sorted { ($0.nextDueAt ?? .distantFuture) < ($1.nextDueAt ?? .distantFuture) }
    }

    /// Projected times per task, from the shared projector (no duplicated projection logic).
    private var timesByTask: [UUID: [Date]] {
        Dictionary(uniqueKeysWithValues:
            PatientScheduleBuilder.lines(for: patient.tasks).map { ($0.id, $0.times) })
    }

    var body: some View {
        List {
            Section {
                Button { store.editRequest = .add(patient, .medication) } label: {
                    Label("Add Medication", systemImage: "pills.fill")
                }
                Button { store.editRequest = .add(patient, .generic) } label: {
                    Label("Add Task", systemImage: "checklist")
                }
                Button { store.editRequest = .add(patient, .reminder) } label: {
                    Label("Add Reminder", systemImage: "bell.badge")
                }
            }

            if patient.tasks.isEmpty {
                Section { Text("No medications, tasks, or reminders yet.").foregroundStyle(.secondary) }
            }
            // Grouped by kind; Reminders at the bottom (feedback pass 4, item 3).
            taskSection("Medications", kind: .medication)
            taskSection("Care tasks", kind: .generic)
            taskSection("Reminders", kind: .reminder)

            if let notes = patient.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
        }
        .navigationTitle(patient.display)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editingPatient = true } label: { Label("Edit Patient", systemImage: "pencil") }
                    Button { store.setPatientActive(patient, false); dismiss() } label: {
                        Label("Deactivate", systemImage: "archivebox")
                    }
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete Patient", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingPatient) { NavigationStack { PatientFormView(patient: patient) } }
        .confirmationDialog("Delete \(patient.display) and all their tasks?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deletePatient(patient); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A kind-grouped section of task rows, rendered only when the patient has tasks of that kind.
    @ViewBuilder
    private func taskSection(_ title: String, kind: TaskKind) -> some View {
        let items = tasks(of: kind)
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { task in
                    Button { store.taskDetailRequest = .init(task: task) } label: {
                        HubTaskRow(task: task, times: timesByTask[task.id] ?? [], now: .now, settings: settings)
                    }
                    .buttonStyle(.plain)
                    .taskSwipeActions(task: task, store: store)
                }
            }
        }
    }
}

/// A task row for the patient hub: the shared status/title/due row plus the projected
/// times for the day, with lifecycle swipe actions attached by the caller.
private struct HubTaskRow: View {
    let task: CareTask
    let times: [Date]
    let now: Date
    let settings: AppSettings

    private var occurrences: [OccurrenceMark] { task.todayOccurrences(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TaskRowView(task: task, now: now, settings: settings)
            // Fixed-times tasks show per-occurrence state (which of 0900/1700/2100 is done);
            // other schedules fall back to the plain projected-times line (feedback pass 4 item 2c).
            if !occurrences.isEmpty {
                OccurrenceMarksView(marks: occurrences).padding(.leading, 22)
            } else if !times.isEmpty {
                Text("Today · " + PatientScheduleBuilder.timesText(times))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(.leading, 22)
            }
        }
    }
}

import SwiftUI
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

    /// The patient's tasks laid out chronologically for the day (PRN / no-due last).
    private var chronologicalTasks: [CareTask] {
        patient.tasks.sorted { ($0.nextDueAt ?? .distantFuture) < ($1.nextDueAt ?? .distantFuture) }
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
            }

            Section("Today") {
                if patient.tasks.isEmpty {
                    Text("No medications or tasks yet.").foregroundStyle(.secondary)
                }
                ForEach(chronologicalTasks) { task in
                    HubTaskRow(task: task, times: timesByTask[task.id] ?? [], now: .now, settings: settings)
                        .taskSwipeActions(task: task, store: store)
                }
            }

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
}

/// A task row for the patient hub: the shared status/title/due row plus the projected
/// times for the day, with lifecycle swipe actions attached by the caller.
private struct HubTaskRow: View {
    let task: CareTask
    let times: [Date]
    let now: Date
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TaskRowView(task: task, now: now, settings: settings)
            if !times.isEmpty {
                Text("Today · " + PatientScheduleBuilder.timesText(times))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .italic()
                    .padding(.leading, 22)
            }
        }
    }
}

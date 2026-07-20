import SwiftUI
import NurseTimerModels

/// Patient detail: info + task list split into medication and general-care sections,
/// with Add Task and the shared swipe actions (spec §6.2).
struct PatientDetailView: View {
    @Environment(NurseStore.self) private var store
    @Bindable var patient: Patient
    @State private var editingPatient = false

    private var settings: AppSettings { store.settings() }
    private var meds: [CareTask] { patient.tasks.filter { $0.kind == .medication }.sorted(by: dueOrder) }
    private var generics: [CareTask] { patient.tasks.filter { $0.kind == .generic }.sorted(by: dueOrder) }

    var body: some View {
        List {
            if let notes = patient.notes, !notes.isEmpty {
                Section("Notes") { Text(notes) }
            }
            taskSection("Medications", tasks: meds, empty: "No medications")
            taskSection("Care tasks", tasks: generics, empty: "No care tasks")
        }
        .navigationTitle(patient.display)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { store.editRequest = .add(patient) } label: { Label("Add Task", systemImage: "plus") }
                    Button { editingPatient = true } label: { Label("Edit Patient", systemImage: "pencil") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $editingPatient) { NavigationStack { PatientFormView(patient: patient) } }
    }

    private func taskSection(_ title: String, tasks: [CareTask], empty: String) -> some View {
        Section(title) {
            if tasks.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(tasks) { task in
                    TaskRowView(task: task, now: .now, settings: settings)
                        .taskSwipeActions(task: task, store: store)
                }
            }
        }
    }

    private func dueOrder(_ a: CareTask, _ b: CareTask) -> Bool {
        (a.nextDueAt ?? .distantFuture) < (b.nextDueAt ?? .distantFuture)
    }
}

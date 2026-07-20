import SwiftUI
import SwiftData
import NurseTimerModels

/// Patient list with add / edit / deactivate-reactivate / delete (spec §6.2).
/// (Archive/purge is out of scope for this pass.)
struct PatientListView: View {
    @Environment(NurseStore.self) private var store
    @Query(sort: \Patient.roomNumber) private var patients: [Patient]
    @State private var editing: Patient?
    @State private var adding = false
    @State private var toDelete: Patient?

    private var active: [Patient] { patients.filter { $0.isActive } }
    private var inactive: [Patient] { patients.filter { !$0.isActive } }

    var body: some View {
        List {
            Section("Active") {
                if active.isEmpty { Text("No active patients").foregroundStyle(.secondary) }
                ForEach(active) { patient in
                    NavigationLink { PatientDetailView(patient: patient) } label: { row(patient) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { toDelete = patient } label: { Label("Delete", systemImage: "trash") }
                            Button { store.setPatientActive(patient, false) } label: { Label("Deactivate", systemImage: "archivebox") }.tint(.gray)
                            Button { editing = patient } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                }
            }
            if !inactive.isEmpty {
                Section("Inactive") {
                    ForEach(inactive) { patient in
                        HStack {
                            Text(patient.display).foregroundStyle(.secondary)
                            Spacer()
                            Button("Reactivate") { store.setPatientActive(patient, true) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { toDelete = patient } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Patients")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("Add Patient", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) { NavigationStack { PatientFormView(patient: nil) } }
        .sheet(item: $editing) { patient in NavigationStack { PatientFormView(patient: patient) } }
        .confirmationDialog("Delete patient and all their tasks?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { patient in
            Button("Delete \(patient.display)", role: .destructive) { store.deletePatient(patient); toDelete = nil }
            Button("Cancel", role: .cancel) { toDelete = nil }
        }
    }

    private func row(_ patient: Patient) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(patient.display).font(.headline)
            Text("\(patient.tasks.count) task\(patient.tasks.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

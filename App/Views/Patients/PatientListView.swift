import SwiftUI
import SwiftData
import NurseTimerModels

/// Inactive (archived) patients — reactivate or delete. Active patients live on the Board
/// (the single entry point), so this screen intentionally does NOT duplicate that route.
struct PatientListView: View {
    @Environment(NurseStore.self) private var store
    @Query(sort: \Patient.roomNumber) private var patients: [Patient]
    @State private var toDelete: Patient?

    private var inactive: [Patient] { patients.filter { !$0.isActive } }

    var body: some View {
        Group {
            if inactive.isEmpty {
                ContentUnavailableView("No inactive patients", systemImage: "archivebox")
            } else {
                List {
                    ForEach(inactive) { patient in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(patient.display)
                                Text("\(patient.tasks.count) task\(patient.tasks.count == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reactivate") { store.setPatientActive(patient, true) }
                                .buttonStyle(.borderless)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { toDelete = patient } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .navigationTitle("Inactive Patients")
        .confirmationDialog("Delete patient and all their tasks?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            presenting: toDelete) { patient in
            Button("Delete \(patient.display)", role: .destructive) { store.deletePatient(patient); toDelete = nil }
            Button("Cancel", role: .cancel) { toDelete = nil }
        }
    }
}

import SwiftUI
import NurseTimerModels

/// Add / edit a patient. Warns (does not block) on duplicate active room (spec §8).
struct PatientFormView: View {
    @Environment(NurseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let patient: Patient?

    @State private var roomNumber = ""
    @State private var firstName = ""
    @State private var notes = ""
    @State private var showDuplicateWarning = false

    private var isEditing: Bool { patient != nil }
    private var canSave: Bool { !roomNumber.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section("Room") {
                TextField("Room number (e.g. 412B)", text: $roomNumber)
                    .textInputAutocapitalization(.characters)
            }
            Section("Optional") {
                TextField("First name", text: $firstName)
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }
        }
        .navigationTitle(isEditing ? "Edit Patient" : "Add Patient")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { attemptSave() }.disabled(!canSave) }
        }
        .onAppear {
            if let patient {
                roomNumber = patient.roomNumber
                firstName = patient.firstName ?? ""
                notes = patient.notes ?? ""
            }
        }
        .alert("Room \(roomNumber) already has an active patient", isPresented: $showDuplicateWarning) {
            Button("Save anyway") { save() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func attemptSave() {
        let room = roomNumber.trimmingCharacters(in: .whitespaces)
        if store.roomIsOccupied(room, excluding: patient) {
            showDuplicateWarning = true
        } else {
            save()
        }
    }

    private func save() {
        let room = roomNumber.trimmingCharacters(in: .whitespaces)
        let name = firstName.trimmingCharacters(in: .whitespaces).nilIfBlank
        let note = notes.trimmingCharacters(in: .whitespaces).nilIfBlank
        if let patient {
            store.updatePatient(patient, roomNumber: room, firstName: name, notes: note)
        } else {
            store.addPatient(roomNumber: room, firstName: name, notes: note)
        }
        dismiss()
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}

import SwiftUI

/// Task detail (spec §5.1): three large actions. SNOOZE is the visually dominant /
/// first action (spec §5.2). SKIP requires a second confirmation with a quick reason.
struct TaskDetailView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: WatchTask
    @State private var confirmingSkip = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header

                Button {
                    model.snooze(task); dismiss()
                } label: {
                    Label("Snooze", systemImage: "zzz").frame(maxWidth: .infinity)
                }
                .tint(.indigo)

                Button {
                    model.given(task); dismiss()
                } label: {
                    Label(task.isMedication ? "Given" : "Done", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)

                Button(role: .destructive) {
                    confirmingSkip = true
                } label: {
                    Label("Skip", systemImage: "forward").frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .navigationTitle("Rm \(task.room)")
        .confirmationDialog("Skip this task?", isPresented: $confirmingSkip, titleVisibility: .visible) {
            ForEach(["Refused", "NPO", "Held", "Other"], id: \.self) { reason in
                Button(reason) { model.skip(task, reason: reason); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title).font(.headline)
            if let dosage = task.dosage { Text(dosage).font(.caption).foregroundStyle(.secondary) }
            Text(task.dueText).font(.caption).foregroundStyle(task.urgency().color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

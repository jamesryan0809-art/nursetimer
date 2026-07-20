import SwiftUI

/// Task detail (spec §5.1). SNOOZE is the visually dominant / first action (spec §5.2),
/// then Given/Done, then Skip Once (immediate). Pause is visually subordinate,
/// physically separated below a divider, and always confirmed (naming task + room).
/// No skip reasons — the phone records only the source.
struct TaskDetailView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: WatchTask
    @State private var confirmingPause = false

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

                Button {
                    model.skipOnce(task); dismiss()
                } label: {
                    Label("Skip Once", systemImage: "forward").frame(maxWidth: .infinity)
                }
                .tint(.orange)

                Divider().padding(.vertical, 6)

                // Subordinate, separated, destructive — always confirmed.
                Button(role: .destructive) {
                    confirmingPause = true
                } label: {
                    Label("Pause", systemImage: "pause").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .navigationTitle("Rm \(task.room)")
        .confirmationDialog("Pause this task?", isPresented: $confirmingPause, titleVisibility: .visible) {
            Button("Pause", role: .destructive) { model.pause(task); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rm \(task.room) · \(task.title) — no reminders until resumed.")
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

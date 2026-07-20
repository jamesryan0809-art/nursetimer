import SwiftUI

/// Root Now view (spec §5.1): tasks sorted by urgency, each row room · title · dosage ·
/// due. Scrolls with the Digital Crown (native List). Shows the not-synced state and an
/// empty state.
struct NowView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if !model.isSynced {
                    NotSyncedBanner()
                }
                if model.sortedTasks.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle")
                } else {
                    ForEach(model.sortedTasks) { task in
                        NavigationLink(value: task) { TaskRow(task: task) }
                    }
                }
            }
            .navigationTitle("Now")
            .navigationDestination(for: WatchTask.self) { TaskDetailView(task: $0) }
            .onAppear { model.refresh() }
        }
    }
}

struct TaskRow: View {
    let task: WatchTask
    private var urgency: WatchUrgency { task.urgency() }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(urgency.color).frame(width: 4).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                Text("Rm \(task.room)").font(.headline)
                Text(task.title).font(.caption).lineLimit(1)
                if let dosage = task.dosage { Text(dosage).font(.caption2).foregroundStyle(.secondary) }
                Text(task.dueText).font(.caption2).foregroundStyle(urgency.color)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Room \(task.room), \(task.title), \(task.dueText)")
    }
}

struct NotSyncedBanner: View {
    var body: some View {
        Label("Not synced to iPhone · sample data", systemImage: "iphone.slash")
            .font(.caption2)
            .foregroundStyle(.orange)
            .listRowBackground(Color.orange.opacity(0.12))
    }
}

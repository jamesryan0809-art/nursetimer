import SwiftUI

/// Root Now view (spec §5.1): tasks sorted by urgency, each row room · title · dosage · due,
/// bound to the SYNCED snapshot. Shows an "update the app" state on a newer schema, a subtle
/// staleness indicator when the snapshot is old / the phone is unreachable, and an empty state.
struct NowView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if model.needsAppUpdate {
                    UpdateAppBanner()
                } else if model.isStale() {
                    StaleBanner(lastSyncedAt: model.lastSyncedAt)
                }

                if model.needsAppUpdate {
                    // Don't render possibly-misunderstood data alongside the update prompt.
                } else if model.sortedTasks.isEmpty {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle")
                } else {
                    ForEach(model.sortedTasks) { task in
                        NavigationLink(value: task) {
                            TaskRow(task: task, pending: model.isPending(task))
                        }
                    }
                }
            }
            .navigationTitle("Now")
            .navigationDestination(for: WatchTask.self) { TaskDetailView(task: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SyncStatusView() } label: {
                        Image(systemName: syncGlyph).foregroundStyle(syncTint)
                    }
                    .accessibilityLabel("Sync status")
                }
            }
            .onAppear { model.refresh() }
        }
    }

    /// A tiny, always-visible sync affordance whose glyph reflects the current link health.
    private var syncGlyph: String {
        if model.needsAppUpdate { return "exclamationmark.arrow.triangle.2.circlepath" }
        if model.isStale() { return "iphone.slash" }
        return model.isSynced ? "iphone.and.arrow.forward" : "iphone.gen1"
    }
    private var syncTint: Color {
        if model.needsAppUpdate { return .orange }
        if model.isStale() { return .secondary }
        return model.isSynced ? .green : .secondary
    }
}

struct TaskRow: View {
    let task: WatchTask
    var pending = false

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(task.status.color).frame(width: 4).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Rm \(task.room)").font(.headline)
                    if task.colorTagRaw != "none" {
                        Circle().fill(colorTagColor).frame(width: 7, height: 7)
                    }
                    if task.isMuted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.primary)
                    }
                    if pending {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(task.title).font(.caption).lineLimit(1)
                if let dosage = task.dosage { Text(dosage).font(.caption2).foregroundStyle(.secondary) }
                if task.isPRN, let last = task.lastCompletedAt {
                    Text("Last \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(task.dueText).font(.caption2).foregroundStyle(task.status.color)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Room \(task.room), \(task.title), \(task.dueText)\(task.isMuted ? ", reminders off" : "")\(pending ? ", syncing" : "")")
    }

    /// Minimal watch-side color-tag palette (display-only; mirrors the phone tag names).
    private var colorTagColor: Color {
        switch task.colorTagRaw {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .gray
        }
    }
}

/// The phone sent a newer schema than this build understands (§5.3) — never misrender; ask to update.
struct UpdateAppBanner: View {
    var body: some View {
        Label("Update NurseTimer on this watch to sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            .font(.caption2)
            .foregroundStyle(.orange)
            .listRowBackground(Color.orange.opacity(0.12))
    }
}

/// Snapshot is old or the phone is unreachable — the data may be behind the phone.
struct StaleBanner: View {
    let lastSyncedAt: Date?
    var body: some View {
        Label {
            if let lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Waiting for iPhone")
            }
        } icon: {
            Image(systemName: "iphone.slash")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .listRowBackground(Color.gray.opacity(0.12))
    }
}

import SwiftUI

/// Discreet, permanent sync-status readout (item 2g). Reached from the Now view toolbar. On
/// hardware this is where the next session reads the break point directly: session state,
/// reachability, last snapshot time, and the last error.
struct SyncStatusView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        List {
            Section("Session") {
                row("State", model.diagnostics.activation)
                row("Reachable", model.diagnostics.reachable ? "yes" : "no")
            }
            Section("Snapshot") {
                row("Sync state", syncStateText)
                row("Last received", model.diagnostics.lastSnapshotAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "never")
                row("Tasks", "\(model.snapshot.tasks.count)")
            }
            if let error = model.diagnostics.lastError {
                Section("Last error") {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Section {
                Button("Request snapshot now") { model.refresh() }
            }
        }
        .navigationTitle("Sync")
    }

    private var syncStateText: String {
        switch model.state {
        case .notSynced: return "not synced"
        case .synced: return "synced"
        case .needsUpdate: return "update the app"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
            .font(.caption2)
    }
}

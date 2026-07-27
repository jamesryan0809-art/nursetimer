import SwiftUI
import NurseTimerModels

/// Settings (spec §6.2 item 7). Reminder-affecting changes trigger a replan;
/// app-lock changes reconfigure the lock controller. Destructive actions confirm.
struct SettingsView: View {
    @Environment(NurseStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: AppSettings

    @State private var confirmClearLog = false
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminders") {
                    Stepper("Default lead time: \(settings.defaultLeadTimeMinutes) min",
                            value: $settings.defaultLeadTimeMinutes, in: 5...60, step: 5)
                    Stepper("Default snooze: \(settings.defaultSnoozeMinutes) min",
                            value: $settings.defaultSnoozeMinutes, in: 1...15)
                }

                Section("Board") {
                    Picker("Sort by", selection: Binding(
                        get: { BoardSort(rawValue: settings.boardSortRaw) ?? .nextDue },
                        set: { settings.boardSortRaw = $0.rawValue; store.persistPreferences() })) {
                        ForEach(BoardSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Overdue patients stay pinned at the top for any sort.")
                }

                Section("Privacy & Security") {
                    Toggle("Hide details on lock screen", isOn: $settings.privacyModeNotifications)
                    Toggle("App lock (Face ID / passcode)", isOn: $settings.appLockEnabled)
                    if settings.appLockEnabled {
                        Stepper("Lock after \(settings.appLockTimeoutMinutes) min in background",
                                value: $settings.appLockTimeoutMinutes, in: 0...30)
                    }
                    if app.notificationsDenied {
                        Label("Notifications are off — reminders won't fire. Enable them in the Settings app.",
                              systemImage: "bell.slash")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section("Apple Watch") {
                    NavigationLink {
                        WatchSetupView()
                    } label: {
                        Label("Watch & reminders setup", systemImage: "applewatch")
                    }
                }

                Section("Data") {
                    Button("Clear shift log", role: .destructive) { confirmClearLog = true }
                    Button("Delete all data", role: .destructive) { confirmDeleteAll = true }
                }

                Section("About") {
                    NavigationLink("Disclaimer") { DisclaimerText() }
                    LabeledContent("Version", value: "1.0")
                    Text("NurseTimer is a personal organizer. It is not a medical device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings.defaultLeadTimeMinutes) { _, _ in store.commit() }
            .onChange(of: settings.defaultSnoozeMinutes) { _, _ in store.commit() }
            .onChange(of: settings.privacyModeNotifications) { _, _ in store.commit() }
            .onChange(of: settings.appLockEnabled) { _, _ in reconfigureLock() }
            .onChange(of: settings.appLockTimeoutMinutes) { _, _ in reconfigureLock() }
            .confirmationDialog("Clear the entire shift log?", isPresented: $confirmClearLog, titleVisibility: .visible) {
                Button("Clear log", role: .destructive) { store.clearLog() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete ALL patients, tasks, and history? This cannot be undone.",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { store.deleteAllData() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func reconfigureLock() {
        store.commit()   // persist the setting
        app.lock.configure(enabled: settings.appLockEnabled, timeoutMinutes: settings.appLockTimeoutMinutes)
    }
}

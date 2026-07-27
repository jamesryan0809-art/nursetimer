import SwiftUI
import UserNotifications
import WatchConnectivity
import UIKit

/// In-app "Watch & Reminders" setup guide (nurse-support request). iOS does NOT let an app
/// change notification-mirroring, Wrist Detection, Focus, or the "Mirror my iPhone" toggle
/// programmatically — those are user-owned system settings with no API. So this screen does the
/// most that's possible: it DETECTS what it can (notification permission, Time-Sensitive, watch
/// paired, and whether NurseTimer is actually installed on the watch via WatchConnectivity) and
/// gives tap-to-open Settings buttons plus the exact tap-paths for the toggles we can't reach.
struct WatchSetupView: View {
    @State private var model = WatchSetupModel()

    var body: some View {
        List {
            Section {
                Text("Reminders appear on your Apple Watch when your iPhone is locked and nearby. Use the checks below to make sure everything's switched on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Status") {
                StatusRow(title: "Notifications allowed", state: model.notifications,
                          fix: model.openNotificationSettings)
                StatusRow(title: "Time-Sensitive alerts on", state: model.timeSensitive,
                          fix: model.openNotificationSettings)
                StatusRow(title: "Apple Watch paired", state: model.watchPaired, fix: nil)
                StatusRow(title: "NurseTimer installed on watch", state: model.watchAppInstalled, fix: nil)
                Button { Task { await model.refresh() } } label: {
                    Label("Re-check", systemImage: "arrow.clockwise")
                }
            }

            Section("Set it up") {
                Step(number: 1, title: "Allow notifications",
                     detail: "Turn on Allow Notifications and Time-Sensitive Notifications.",
                     button: ("Open Notification Settings", model.openNotificationSettings))
                Step(number: 2, title: "Install the watch app",
                     detail: "Open the Apple Watch app on your iPhone, scroll to Available Apps, and tap Install next to NurseTimer. (Or turn on Automatic App Install so it happens for you.)",
                     button: nil)
                Step(number: 3, title: "Mirror alerts to the watch",
                     detail: "In the Apple Watch app: Notifications → NurseTimer → turn on “Mirror my iPhone.”",
                     button: nil)
                Step(number: 4, title: "Turn on Wrist Detection",
                     detail: "In the Apple Watch app: Passcode → Wrist Detection. Without it, the watch won't show mirrored alerts.",
                     button: nil)
                Step(number: 5, title: "Keep them together",
                     detail: "The watch shows a reminder when your iPhone is locked and within Bluetooth range. Check that a Focus, Sleep, or Do Not Disturb mode isn't silencing NurseTimer.",
                     button: nil)
            }

            Section {
                Text("Note: today the watch relays reminders from your iPhone, so the phone needs to be nearby and on. Reminders that fire on the watch with the phone away are on the roadmap.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Watch & Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }
}

// MARK: - Rows

private struct StatusRow: View {
    let title: String
    let state: WatchSetupModel.Check
    /// Optional one-tap fix (opens Settings). Only the checks we can deep-link to have one.
    let fix: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol).foregroundStyle(state.tint)
            Text(title)
            Spacer()
            if state != .ok, let fix {
                Button("Fix", action: fix).font(.callout)
            } else {
                Text(state.label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(state.label)")
    }
}

private struct Step: View {
    let number: Int
    let title: String
    let detail: String
    /// (label, action) for the steps we can deep-link; nil for instruction-only steps.
    let button: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").font(.headline.monospacedDigit())
                    .frame(minWidth: 18)
                Text(title).font(.headline)
            }
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .padding(.leading, 26)
            if let (label, action) = button {
                Button(label, action: action)
                    .buttonStyle(.bordered)
                    .padding(.leading, 26).padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Model

/// Reads the checks we can observe and opens the app's Settings page. Notification status comes
/// from `UNUserNotificationCenter`; watch pairing / install status comes from `WCSession`
/// (iOS-only APIs). Everything degrades to `.unknown` rather than failing.
@MainActor
@Observable
final class WatchSetupModel {
    enum Check: Equatable {
        case ok, needsAction, unknown
        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .needsAction: return "exclamationmark.circle.fill"
            case .unknown: return "questionmark.circle"
            }
        }
        var tint: Color {
            switch self {
            case .ok: return .green
            case .needsAction: return .orange
            case .unknown: return .secondary
            }
        }
        var label: String {
            switch self {
            case .ok: return "On"
            case .needsAction: return "Action needed"
            case .unknown: return "Unknown"
            }
        }
    }

    var notifications: Check = .unknown
    var timeSensitive: Check = .unknown
    var watchPaired: Check = .unknown
    var watchAppInstalled: Check = .unknown

    private var probe: WatchConnectivityProbe?

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notifications = (settings.authorizationStatus == .authorized
                         || settings.authorizationStatus == .provisional) ? .ok : .needsAction
        switch settings.timeSensitiveSetting {
        case .enabled:  timeSensitive = .ok
        case .disabled: timeSensitive = .needsAction
        default:        timeSensitive = .unknown   // .notSupported → not applicable
        }
        startWatchProbe()
    }

    /// Opens NurseTimer's own notification settings (iOS 16+), falling back to the app's
    /// Settings page. We can't deep-link into the Apple Watch app's mirroring screen — no
    /// public URL exists — so those steps are instruction-only.
    func openNotificationSettings() {
        let candidates = [UIApplication.openNotificationSettingsURLString, UIApplication.openSettingsURLString]
        for string in candidates {
            if let url = URL(string: string), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
    }

    private func startWatchProbe() {
        guard WCSession.isSupported() else {
            watchPaired = .unknown; watchAppInstalled = .unknown; return
        }
        let probe = WatchConnectivityProbe { [weak self] paired, installed in
            Task { @MainActor in
                self?.watchPaired = paired ? .ok : .needsAction
                self?.watchAppInstalled = installed ? .ok : .needsAction
            }
        }
        self.probe = probe
        probe.start()
    }
}

/// Minimal `WCSession` activation to read `isPaired` / `isWatchAppInstalled` (iOS-only). Kept
/// separate from the @Observable model so the delegate conformance stays simple; results are
/// delivered on the main actor via the callback. This is a read-only probe — it sends nothing
/// and is independent of the (still-stubbed) data-sync milestone.
private final class WatchConnectivityProbe: NSObject, WCSessionDelegate {
    private let onUpdate: (_ paired: Bool, _ installed: Bool) -> Void

    init(onUpdate: @escaping (Bool, Bool) -> Void) {
        self.onUpdate = onUpdate
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        if session.activationState == .activated {
            onUpdate(session.isPaired, session.isWatchAppInstalled)
        } else {
            session.activate()
        }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        onUpdate(session.isPaired, session.isWatchAppInstalled)
    }

    // Required iOS delegate stubs; a deactivated session is reactivated by the system on demand.
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
}

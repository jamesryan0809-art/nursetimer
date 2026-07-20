import Foundation
import Observation
import LocalAuthentication

/// App lock via LocalAuthentication (spec §6.3). Biometrics with device-passcode
/// fallback; no custom authentication and no biometric data stored. Locks on launch
/// (when enabled) and after `appLockTimeoutMinutes` in the background.
@MainActor
@Observable
final class AppLockController {
    enum LockState { case unlocked, locked }

    var state: LockState = .unlocked
    var lastError: String?

    private var enabled = true
    private var timeout: TimeInterval = 5 * 60
    private var backgroundedAt: Date?

    func configure(enabled: Bool, timeoutMinutes: Int) {
        self.enabled = enabled
        self.timeout = TimeInterval(max(0, timeoutMinutes) * 60)
        if !enabled { state = .unlocked }
    }

    /// Call once at launch: start locked when enabled.
    func lockIfEnabled() { state = enabled ? .locked : .unlocked }

    func didEnterBackground(now: Date = .now) { backgroundedAt = now }

    /// On foreground, re-lock if the timeout elapsed.
    func didBecomeActive(now: Date = .now) {
        guard enabled else { state = .unlocked; return }
        if let bg = backgroundedAt, now.timeIntervalSince(bg) >= timeout {
            state = .locked
        }
        backgroundedAt = nil
    }

    func authenticate() async {
        guard enabled else { state = .unlocked; return }
        lastError = nil
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Passcode"

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            lastError = policyError?.localizedDescription ?? "Authentication is unavailable on this device."
            AppLog.ui.error("App lock policy unavailable: \(self.lastError ?? "", privacy: .public)")
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock NurseTimer to view patient reminders.")
            state = success ? .unlocked : .locked
        } catch {
            // Cancellation / failure keep the app locked; surface the reason.
            lastError = error.localizedDescription
            state = .locked
        }
    }
}

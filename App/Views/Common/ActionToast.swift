import SwiftUI
import UIKit

/// Haptic feedback for action acknowledgment (feedback micro-pass). Uses standard
/// `UIFeedbackGenerator` types only. Device-only — the simulator does not vibrate.
enum Haptics {
    @MainActor
    static func play(_ style: ActionAck.Style) {
        switch style {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// The brief confirmation toast. Non-blocking, bottom-anchored (above the tab bar) so it never
/// obstructs the top nav bar or in-sheet action buttons. Monochrome + `.thinMaterial` — it
/// conveys "it worked", not status, so it never borrows the red/orange/green status hues.
struct ActionToastView: View {
    let ack: ActionAck

    private var icon: String {
        switch ack.style {
        case .success: return "checkmark.circle.fill"
        case .warning: return "arrow.uturn.forward.circle.fill"
        case .light:   return "zzz"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(ack.message).font(.subheadline.weight(.medium)).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        // Sit above the tab bar so the toast never overlaps it or the top nav bar.
        .padding(.bottom, 54)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ack.message)
    }
}

/// Observes `store.acknowledgment`, plays the haptic, and shows `ActionToastView` for ~2s.
/// Respects Reduce Motion (no slide/fade animation — the toast just appears/disappears).
private struct ActionToastModifier: ViewModifier {
    @Environment(NurseStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: ActionAck?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let current {
                    ActionToastView(ack: current)
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)   // never intercepts taps on controls beneath it
                }
            }
            .onChange(of: store.acknowledgment) { _, ack in show(ack) }
    }

    private func show(_ ack: ActionAck?) {
        guard let ack else { return }
        Haptics.play(ack.style)
        apply { current = ack }
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            apply { current = nil }
        }
    }

    /// Animate only when Reduce Motion is off; otherwise change state statically.
    private func apply(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.spring(duration: 0.3), change) }
    }
}

extension View {
    /// Presents the action-acknowledgment toast/haptic driven by `store.acknowledgment`.
    func actionAcknowledgments() -> some View { modifier(ActionToastModifier()) }
}

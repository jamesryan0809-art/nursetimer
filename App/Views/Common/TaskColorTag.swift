import SwiftUI
import NurseTimerModels

/// Optional per-med color tag (item 2) — a nurse-chosen label to visually group a med across
/// rooms/tasks (e.g. "all the antibiotics are teal"). This is a DISPLAY-ONLY channel that is
/// deliberately SEPARATE from status color (spec §7): status owns red / orange / green and
/// communicates urgency; a tag must never make a row read as more or less urgent. The palette
/// therefore AVOIDS the status hues entirely, and tags render as a distinct leading channel
/// (a small color chip / left-edge bar), never by recoloring status elements.
enum TaskColorTag: String, CaseIterable, Identifiable {
    case none
    case blue, purple, pink, teal, indigo, brown, cyan, mint

    var id: String { rawValue }

    /// nil = no tag (renders no chip / bar). Palette avoids red/orange/green (status-owned).
    var color: Color? {
        switch self {
        case .none:   return nil
        case .blue:   return .blue
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        case .indigo: return .indigo
        case .brown:  return .brown
        case .cyan:   return .cyan
        case .mint:   return .mint
        }
    }

    /// For VoiceOver / the picker label.
    var displayName: String {
        switch self {
        case .none: return "No tag"
        default:    return rawValue.capitalized
        }
    }
}

extension CareTask {
    /// The persisted tag, defaulting to `.none` for any unknown/legacy raw value.
    var colorTag: TaskColorTag { TaskColorTag(rawValue: colorTagRaw) ?? .none }
}

/// A thin left-edge bar for the tag channel on list rows. Renders as a fixed-width clear
/// spacer when there is no tag, so tagged and untagged rows keep the same content alignment.
struct TagBar: View {
    let tag: TaskColorTag
    var height: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(tag.color ?? .clear)
            .frame(width: 4, height: height)
            .accessibilityHidden(true)
    }
}

/// A small tag chip (dot) for compact contexts like Grid cells. Renders nothing when untagged.
struct TagDot: View {
    let tag: TaskColorTag
    var diameter: CGFloat = 7

    var body: some View {
        if let color = tag.color {
            Circle().fill(color).frame(width: diameter, height: diameter)
                .accessibilityHidden(true)
        }
    }
}

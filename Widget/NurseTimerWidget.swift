import WidgetKit
import SwiftUI

// Watch complication / Smart Stack widget (spec §5.1): overdue count + next task.
//
// HONEST DATA STATE: there is no live data source yet. The complication is fed by
// WatchConnectivity + shared state, which is a LATER milestone — so `getTimeline`
// returns a "not synced" entry rather than fabricating production task data. Preview
// states use sample data. Live complication data cannot be validated until sync exists.

struct NurseTimerEntry: TimelineEntry {
    let date: Date
    let isSynced: Bool
    let overdueCount: Int
    let nextRoom: String?
    let nextTime: Date?

    static func unavailable(_ date: Date) -> NurseTimerEntry {
        NurseTimerEntry(date: date, isSynced: false, overdueCount: 0, nextRoom: nil, nextTime: nil)
    }
    static let sample = NurseTimerEntry(date: Date(), isSynced: true, overdueCount: 2,
                                        nextRoom: "412", nextTime: Date().addingTimeInterval(14 * 60))
}

struct NurseTimerProvider: TimelineProvider {
    func placeholder(in context: Context) -> NurseTimerEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (NurseTimerEntry) -> Void) {
        completion(context.isPreview ? .sample : .unavailable(Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NurseTimerEntry>) -> Void) {
        // No shared-state data source yet → report not-synced, don't invent data.
        completion(Timeline(entries: [.unavailable(Date())], policy: .never))
    }
}

struct NurseTimerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NurseTimerEntry

    var body: some View {
        if !entry.isSynced {
            unavailable
        } else {
            switch family {
            case .accessoryCircular:    circular
            case .accessoryInline:      Text(inlineText)
            case .accessoryCorner:      circular
            default:                    rectangular
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 1) {
            Image(systemName: "iphone.slash")
            Text("Sync").font(.caption2)
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Text("\(entry.overdueCount)").font(.title3.bold())
            Text("due").font(.system(size: 9))
        }
        .foregroundStyle(entry.overdueCount > 0 ? .red : .primary)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.overdueCount > 0 ? "\(entry.overdueCount) overdue" : "Up to date")
                .font(.caption.bold())
                .foregroundStyle(entry.overdueCount > 0 ? .red : .primary)
            if let room = entry.nextRoom, let time = entry.nextTime {
                Text("Rm \(room) · \(time.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
            }
        }
    }

    private var inlineText: String {
        if let room = entry.nextRoom, let time = entry.nextTime {
            return "Rm \(room) · \(time.formatted(date: .omitted, time: .shortened))"
        }
        return entry.overdueCount > 0 ? "\(entry.overdueCount) overdue" : "NurseTimer"
    }
}

@main
struct NurseTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NurseTimerWidget", provider: NurseTimerProvider()) { entry in
            NurseTimerWidgetView(entry: entry)
        }
        .configurationDisplayName("NurseTimer")
        .description("Overdue count and the next task.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NurseTimerWidget()
} timeline: {
    NurseTimerEntry.sample
    NurseTimerEntry.unavailable(Date())
}

#Preview("Circular", as: .accessoryCircular) {
    NurseTimerWidget()
} timeline: {
    NurseTimerEntry.sample
    NurseTimerEntry.unavailable(Date())
}

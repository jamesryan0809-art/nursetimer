import WidgetKit
import SwiftUI

// Item 1 scaffolding. The real complication/widget timeline is built in Milestone 4,
// which replaces this file. It intentionally shows placeholder data only — there is
// no data source until WatchConnectivity + shared state exist (a later milestone).

struct NurseTimerEntry: TimelineEntry {
    let date: Date
    let overdueCount: Int
    let nextTitle: String?
}

struct NurseTimerProvider: TimelineProvider {
    func placeholder(in context: Context) -> NurseTimerEntry {
        NurseTimerEntry(date: Date(), overdueCount: 0, nextTitle: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NurseTimerEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NurseTimerEntry>) -> Void) {
        completion(Timeline(entries: [placeholder(in: context)], policy: .never))
    }
}

struct NurseTimerWidgetView: View {
    var entry: NurseTimerEntry
    var body: some View {
        Text("NurseTimer")
    }
}

@main
struct NurseTimerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NurseTimerWidget", provider: NurseTimerProvider()) { entry in
            NurseTimerWidgetView(entry: entry)
        }
        .configurationDisplayName("NurseTimer")
        .description("Overdue count and next task.")
    }
}

import SwiftUI
import WidgetKit
import RenderDockWidgetViews

/// The desktop widget: the render in front and how the queue is doing, read from a small file RenderDock writes
/// in its own folder. It asks the network for nothing and reads nothing else.

struct StatusEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?
}

struct StatusProvider: TimelineProvider {
    private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), data: .sample(chinese: chinese))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        // In the gallery there is a made-up render to look at, whatever is going on.
        completion(StatusEntry(date: Date(), data: context.isPreview ? .sample(chinese: chinese) : (WidgetData.read() ?? .sample(chinese: chinese))))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let data = WidgetData.read()
        var entries = [StatusEntry(date: now, data: data?.carried(to: now))]
        var again = now.addingTimeInterval(15 * 60)
        if let data, data.movesByItself, data.believable(at: now) {
            // A render that says how far it is and how long it has left is carried forward a minute at a time,
            // so the ring moves between two readings of the file. RenderDock asks for a new reading whenever
            // something changes that this cannot foresee.
            for minute in 1...10 {
                let date = now.addingTimeInterval(Double(minute) * 60)
                entries.append(StatusEntry(date: date, data: data.carried(to: date)))
            }
            again = now.addingTimeInterval(10 * 60)
        } else if let data, data.state != "idle", data.state != "off" {
            again = now.addingTimeInterval(5 * 60)
        }
        completion(Timeline(entries: entries, policy: .after(again)))
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        WidgetFace(data: entry.data, wide: family == .systemMedium, now: entry.date)
            .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct StatusWidget: Widget {
    private var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetData.kind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName(chinese ? "渲染进度" : "Render Progress")
        .description(chinese ? "最靠前的那一段渲到哪了、还要多久，以及整条队列。" : "How far the render in front is, how long it has left, and the queue.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct RenderDockWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}

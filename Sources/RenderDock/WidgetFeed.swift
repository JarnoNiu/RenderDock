import AppKit
import SwiftUI
import WidgetKit
import RenderDockCore
import RenderDockWidgetViews

// The desktop widget is an extension in a sandbox of its own: it cannot ask the app anything. So the app leaves
// it a small file in its own folder, and tells the system when the widget should read it again.

extension Store {
    /// What the widget is told, from what the dock knows now.
    func widgetData(now: Date) -> WidgetData {
        let g = groups
        let focus = g.focusItem
        let group = focus.flatMap { f in g.first { $0.items.contains { $0.id == f.id } } }
        let state: String
        if g.activeCount > 0 { state = "rendering" }
        else if g.stalledCount > 0 { state = "stalled" }
        else if g.pausedCount > 0 { state = "paused" }
        else if g.waitingCount > 0 { state = "waiting" }
        else { state = "idle" }
        return WidgetData(
            at: now, state: state, active: g.activeCount, paused: g.pausedCount, stalled: g.stalledCount, queued: g.waitingCount,
            focus: focus.map { WidgetData.Focus(name: $0.name, job: group?.title ?? "", fraction: $0.fraction, estimate: $0.totalIsEstimate,
                                                etaSec: $0.eta, framesDone: $0.framesDone) },
            shotsDone: group.map(\.doneCount), shotsTotal: group.map(\.items.count), queueEtaSec: group?.queueETA?.seconds,
            agentsWaiting: agents.count(.waiting), agentsWorking: agents.count(.working), agentsFailed: agents.count(.error),
            chinese: L("zh", "en") == "zh")
    }
}

/// Writes the widget's file and asks for it to be read again: when what it says has changed, and otherwise
/// seldom. A widget is not meant to be told every second, and the system would stop listening.
final class WidgetFeed {
    /// Where the file goes. Only the installed app writes the real one: a demo or a bare build must not put
    /// made-up renders on the desktop. RENDERDOCK_WIDGET names another file, for trying it.
    private let url: URL?
    /// Whether there is a widget extension to tell (only in the installed app).
    private let installed: Bool
    private var written: WidgetData?
    private var told: WidgetData?
    private var toldAt = Date.distantPast

    init(demo: Bool) {
        installed = !demo && Bundle.main.bundlePath.hasSuffix(".app")
        if let path = ProcessInfo.processInfo.environment["RENDERDOCK_WIDGET"], !path.isEmpty { url = URL(fileURLWithPath: path) }
        else { url = installed ? WidgetData.sharedURL : nil }
    }

    func update(_ data: WidgetData) {
        guard let url else { return }
        // The file: whenever it would say something else, and every half minute while something is going on,
        // so that a reader can tell a live app from one that is gone.
        let quiet = data.state == "idle" || data.state == "off"
        if let last = written, last.sameContent(as: data), quiet || data.at.timeIntervalSince(last.at) < 30 { return }
        data.write(to: url)
        written = data
        guard WidgetData.worthTelling(data, told: told, toldAt: toldAt) else { return }
        told = data
        toldAt = data.at
        if installed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetData.kind) }
    }

}

/// The widget's face drawn into a picture, on a ground like the one the system gives it: for looking at it
/// without putting it on the desktop.
@MainActor
func widgetPicture(_ data: WidgetData?, wide: Bool, light: Bool, now: Date, to path: String) {
    let size = wide ? CGSize(width: 364, height: 170) : CGSize(width: 170, height: 170)
    let view = WidgetFace(data: data, wide: wide, now: now)
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(light ? Color(white: 0.955) : Color(white: 0.165)))
        .environment(\.colorScheme, light ? .light : .dark)
        .padding(14)
        .background(light ? Color(white: 0.80) : Color(white: 0.06))
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

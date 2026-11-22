import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// The window has a transparent margin, so the system must not keep the whole frame below the menu bar; we clamp the position ourselves.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The first click takes effect even when the window is not frontmost.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct RootView: View {
    let store: Store
    weak var controller: PanelController?

    var body: some View {
        ZStack(alignment: store.anchor.alignment) {
            if store.expanded {
                PanelView(store: store, onCollapse: { controller?.setExpanded(false) })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { controller?.contentSizeChanged($0, expanded: true) }
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: store.anchor.unitPoint)))
            } else {
                CapsuleView(store: store)
                    .onTapGesture { controller?.capsuleTapped() }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { controller?.contentSizeChanged($0, expanded: false) }
                    .transition(.opacity.combined(with: .scale(scale: 0.86, anchor: store.anchor.unitPoint)))
            }
        }
        .padding(Layout.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: store.anchor.alignment)
        .environment(\.colorScheme, .dark)
    }
}

/// The floating window: dragging, snapping, expand/collapse, click-through.
final class PanelController {
    let store: Store
    let panel: FloatingPanel
    private var monitors: [Any] = []
    private var hoverTimer: Timer?

    private var dragStartMouse: NSPoint?
    private var dragStartFrame: NSRect = .zero
    private var dragging = false
    private var suppressTap = false
    private var transitioning = false
    private var capsuleSize = CGSize(width: 250, height: Layout.capsuleHeight)
    private var panelSize: CGSize?
    /// Where the capsule sat while collapsed (if expanding pushed the window aside, collapsing must return here).
    private var home: NSRect?
    /// Mouse position on screen. Replaced by injected coordinates when debugging.
    var mouseLocation: () -> NSPoint = { NSEvent.mouseLocation }

    init(store: Store) {
        self.store = store
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 82),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false

        let host = FirstMouseHostingView(rootView: RootView(store: store, controller: self))
        host.sizingOptions = []
        panel.contentView = host

        restorePosition()
        installMonitors()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }

    // MARK: Expand and collapse

    func capsuleTapped() {
        guard !suppressTap else { return }
        setExpanded(true)
    }

    func toggle() { setExpanded(!store.expanded) }

    func setExpanded(_ on: Bool) {
        guard on != store.expanded, !transitioning else { return }
        transitioning = true
        if on {
            store.refreshNow()
            let screen = currentScreen()
            store.listMaxHeight = max(150, min(480, screen.visibleFrame.height - 320))
            store.listContentHeight = measure(TaskListContent(store: store)).height
            let size = measure(PanelView(store: store))
            home = visual(panel.frame)
            fit(size)   // Grow the window to the panel size first (the extra area is transparent), then animate
            withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) { store.expanded = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.transitioning = false
                if self.store.expanded, let s = self.panelSize { self.fit(s) }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { store.expanded = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                guard let self else { return }
                self.transitioning = false
                guard !self.store.expanded else { return }
                if let h = self.home {
                    self.panel.setFrame(h.insetBy(dx: -Layout.pad, dy: -Layout.pad), display: true)
                }
                self.fit(self.capsuleSize)
                self.home = nil
            }
        }
    }

    func contentSizeChanged(_ size: CGSize, expanded: Bool) {
        let s = CGSize(width: ceil(size.width), height: ceil(size.height))
        if expanded { panelSize = s } else { capsuleSize = s }
        guard expanded == store.expanded, !transitioning, !dragging else { return }
        fit(s)
    }

    private func measure<V: View>(_ view: V) -> CGSize {
        let c = NSHostingController(rootView: view.environment(\.colorScheme, .dark))
        let s = c.sizeThatFits(in: CGSize(width: Layout.panelWidth, height: 10_000))
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    // MARK: Position

    private func visual(_ frame: NSRect) -> NSRect { frame.insetBy(dx: Layout.pad, dy: Layout.pad) }

    private func currentScreen() -> NSScreen {
        let v = visual(panel.frame)
        let c = NSPoint(x: v.midX, y: v.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }
            ?? NSScreen.screens.max { a, b in a.frame.intersection(v).width < b.frame.intersection(v).width }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Resizes the window to the content size, keeping the anchor (the corner it sticks to) in place.
    private func fit(_ content: CGSize) {
        let old = visual(panel.frame)
        var v = NSRect(origin: .zero, size: content)
        switch store.anchor.h {
        case .left: v.origin.x = old.minX
        case .right: v.origin.x = old.maxX - v.width
        case .center: v.origin.x = old.midX - v.width / 2
        }
        switch store.anchor.v {
        case .top: v.origin.y = old.maxY - v.height
        case .bottom: v.origin.y = old.minY
        }
        v = clamp(v, to: currentScreen())
        let f = v.insetBy(dx: -Layout.pad, dy: -Layout.pad).integral
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    private func clamp(_ rect: NSRect, to screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        var r = rect
        if r.maxX > area.maxX { r.origin.x = area.maxX - r.width }
        if r.minX < area.minX { r.origin.x = area.minX }
        if r.maxY > area.maxY { r.origin.y = area.maxY - r.height }
        if r.minY < area.minY { r.origin.y = area.minY }
        return r
    }

    /// On release after a drag: snap to a nearby screen edge, corner, or the centre of the top/bottom edge; stay put when far from all of them.
    private func snapAfterDrag() {
        let screen = currentScreen()
        let area = screen.visibleFrame
        var v = visual(panel.frame)
        var h: Anchor.H?
        var vert: Anchor.V?
        let m = Layout.margin, t = Layout.snap

        if v.minX - (area.minX + m) < t { v.origin.x = area.minX + m; h = .left }
        else if (area.maxX - m) - v.maxX < t { v.origin.x = area.maxX - m - v.width; h = .right }
        else if abs(v.midX - area.midX) < t { v.origin.x = area.midX - v.width / 2; h = .center }

        if (area.maxY - 6) - v.maxY < t { v.origin.y = area.maxY - 6 - v.height; vert = .top }
        else if v.minY - (area.minY + m) < t { v.origin.y = area.minY + m; vert = .bottom }

        // Centre only counts along the top or bottom edge (no snapping in the middle of the screen)
        if h == .center, vert == nil { h = nil; v.origin.x = visual(panel.frame).origin.x }

        store.anchor = Anchor(h: h ?? (v.midX < area.midX ? .left : .right), v: vert ?? (v.midY > area.midY ? .top : .bottom))
        let target = v.insetBy(dx: -Layout.pad, dy: -Layout.pad).integral
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().setFrame(target, display: true)
        }
        if store.expanded {
            // Dragged away while expanded: after collapsing, the capsule lands in this corner of the new position
            home = nil
        }
        savePosition(visualRect: v)
    }

    func resetPosition() {
        if store.expanded { store.expanded = false }
        home = nil
        store.anchor = Anchor(h: .right, v: .top)
        let screen = NSScreen.screens.first ?? currentScreen()
        let area = screen.visibleFrame
        let v = NSRect(x: area.maxX - Layout.margin - capsuleSize.width, y: area.maxY - 6 - capsuleSize.height,
                       width: capsuleSize.width, height: capsuleSize.height)
        panel.setFrame(v.insetBy(dx: -Layout.pad, dy: -Layout.pad).integral, display: true)
        savePosition(visualRect: v)
        show()
    }

    /// A --demo instance keeps its own place: it never reads or overwrites the saved position of the real one.
    private let ephemeral = CommandLine.arguments.contains("--demo")

    private func savePosition(visualRect v: NSRect) {
        guard !ephemeral else { return }
        let d = UserDefaults.standard
        // Store the anchored corner's coordinates, so the capsule doesn't drift when its width changes
        let x = store.anchor.h == .left ? v.minX : (store.anchor.h == .right ? v.maxX : v.midX)
        let y = store.anchor.v == .top ? v.maxY : v.minY
        d.set(Double(x), forKey: "anchorX")
        d.set(Double(y), forKey: "anchorY")
        d.set(store.anchor.h.rawValue, forKey: "anchorH")
        d.set(store.anchor.v.rawValue, forKey: "anchorV")
    }

    private func restorePosition() {
        let d = UserDefaults.standard
        let size = capsuleSize
        if !ephemeral, let hs = d.string(forKey: "anchorH"), let vs = d.string(forKey: "anchorV"),
           let h = Anchor.H(rawValue: hs), let vv = Anchor.V(rawValue: vs), d.object(forKey: "anchorX") != nil {
            let x = d.double(forKey: "anchorX"), y = d.double(forKey: "anchorY")
            var v = NSRect(origin: .zero, size: size)
            v.origin.x = h == .left ? x : (h == .right ? x - size.width : x - size.width / 2)
            v.origin.y = vv == .top ? y - size.height : y
            if NSScreen.screens.contains(where: { $0.frame.intersects(v) }) {
                store.anchor = Anchor(h: h, v: vv)
                panel.setFrame(v.insetBy(dx: -Layout.pad, dy: -Layout.pad).integral, display: false)
                return
            }
        }
        store.anchor = Anchor(h: .right, v: .top)
        let area = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
        let v = NSRect(x: area.maxX - Layout.margin - size.width, y: area.maxY - 6 - size.height, width: size.width, height: size.height)
        panel.setFrame(v.insetBy(dx: -Layout.pad, dy: -Layout.pad).integral, display: false)
    }

    private func screensChanged() {
        // A display was unplugged or rearranged: pull the window back if it ended up off-screen
        let v = visual(panel.frame)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(v) }) {
            resetPosition()
        } else {
            fit(store.expanded ? (panelSize ?? v.size) : capsuleSize)
        }
    }

    // MARK: Debug hook (for --send commands: capture our own window, inject simulated clicks and drags)

    func debugState() -> [String: Any] {
        let v = visual(panel.frame)
        let area = currentScreen().visibleFrame
        return [
            "expanded": store.expanded, "pinned": store.pinned, "visible": panel.isVisible,
            "anchor": "\(store.anchor.h.rawValue)-\(store.anchor.v.rawValue)",
            "visual": [v.minX, v.minY, v.width, v.height],
            "screenVisible": [area.minX, area.minY, area.width, area.height],
            "gapLeft": v.minX - area.minX, "gapRight": area.maxX - v.maxX,
            "gapTop": area.maxY - v.maxY, "gapBottom": v.minY - area.minY,
            "ignoresMouse": panel.ignoresMouseEvents,
            "groups": store.groups.count, "activeItems": store.groups.activeCount,
        ]
    }

    func debugShot(_ path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Injects, in order, at the screen coordinates in `points`: mouse down → drags along the way → mouse up. A single point is a click.
    func debugMouse(_ points: [NSPoint]) {
        guard let first = points.first, let last = points.last else { return }
        var steps: [(NSEvent.EventType, NSPoint)] = [(.leftMouseDown, first)]
        if points.count > 1 {
            for (a, b) in zip(points, points.dropFirst()) {
                for i in 1...8 {
                    let t = CGFloat(i) / 8
                    steps.append((.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
                }
            }
        }
        steps.append((.leftMouseUp, last))
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.03) { [weak self] in
                guard let self else { return }
                self.mouseLocation = { step.1 }
                let local = self.panel.convertPoint(fromScreen: step.1)
                if let e = NSEvent.mouseEvent(
                    with: step.0, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: self.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: step.0 == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(e, atStart: false)
                }
                if i == steps.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.mouseLocation = { NSEvent.mouseLocation } }
                }
            }
        }
    }

    // MARK: Mouse

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(m) }
        // A click in another app: collapse unless pinned
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, self.store.expanded, !self.store.pinned else { return }
            self.setExpanded(false)
        }) { monitors.append(m) }
        // The transparent margin must not block the mouse: when the pointer is outside the visible area, let clicks pass through
        let timer = Timer(timeInterval: 1.0 / 14, repeats: true) { [weak self] _ in
            guard let self, !self.dragging else { return }
            let inside = self.visual(self.panel.frame).contains(self.mouseLocation())
            if self.panel.ignoresMouseEvents == inside { self.panel.ignoresMouseEvents = !inside }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func handle(_ e: NSEvent) {
        guard e.window === panel else { return }
        switch e.type {
        case .leftMouseDown:
            let p = mouseLocation()
            let v = visual(panel.frame)
            // Collapsed: the whole capsule is draggable; expanded: only the header bar at the top is (except the two buttons on the right)
            var zone = v
            if store.expanded {
                zone = NSRect(x: v.minX, y: v.maxY - Layout.headerHeight, width: v.width - 84, height: Layout.headerHeight)
            }
            dragStartMouse = zone.contains(p) ? p : nil
            dragStartFrame = panel.frame
            dragging = false
            suppressTap = false
        case .leftMouseDragged:
            guard let start = dragStartMouse else { return }
            let p = mouseLocation()
            let dx = p.x - start.x, dy = p.y - start.y
            if !dragging, hypot(dx, dy) > 4 {
                dragging = true
                suppressTap = true
            }
            if dragging {
                panel.setFrameOrigin(NSPoint(x: dragStartFrame.origin.x + dx, y: dragStartFrame.origin.y + dy))
            }
        case .leftMouseUp:
            dragStartMouse = nil
            if dragging {
                dragging = false
                snapAfterDrag()
                // SwiftUI still treats the release as a tap; wait for that to pass before allowing taps again
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.suppressTap = false }
            }
        default:
            break
        }
    }
}

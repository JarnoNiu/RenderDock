import AppKit
import SwiftUI

/// Made-up jobs and metrics for `--demo`, the README screenshots and the demo reel.
/// Nothing here reads the real machine; every name and number is fictional.
enum Demo {
    /// Frames per second of demo time the "current shot" advances (time-compressed so progress is visible).
    static let frameRate = 9.0
    private static let shots: [(name: String, frames: Int)] = [
        ("s010_open", 640), ("s020_orbit", 720), ("s030_macro", 480), ("s040_explode", 720),
        ("s050_assemble", 540), ("s060_logo", 600), ("s070_pack", 660), ("s080_end", 500),
    ]

    private static func wave(_ x: Double, _ seed: Double) -> Double {
        let v = 0.5 + 0.28 * sin(x * 0.31 + seed) + 0.14 * sin(x * 1.27 + seed * 2.1) + 0.08 * sin(x * 2.9 + seed * 0.7)
        return min(1, max(0, v))
    }

    static func cpu(_ t: Double) -> Double { 0.46 + 0.34 * wave(t, 0.4) }
    static func gpu(_ t: Double) -> Double { 0.78 + 0.18 * wave(t, 2.2) }
    static func mem(_ t: Double) -> Double { 0.68 + 0.05 * wave(t * 0.4, 4.1) }
    static func temp(_ t: Double) -> Double { 63 + 8 * wave(t * 0.5, 1.3) }

    static func history(_ t: Double, _ f: (Double) -> Double) -> [Double] {
        (0..<Store.historyLength).map { f(t - Double(Store.historyLength - 1 - $0) * 2) }
    }

    static func metrics(_ t: Double) -> Metrics {
        var m = Metrics()
        m.cpu = cpu(t)
        m.gpu = gpu(t)
        m.gpuMemBytes = UInt64((10.6 + 1.2 * wave(t * 0.3, 5)) * 1_073_741_824)
        m.memTotal = 64 * 1_073_741_824
        m.memUsed = UInt64(mem(t) * Double(m.memTotal))
        m.memPressure = 1
        m.swapTotal = 4 * 1_073_741_824
        m.swapUsed = UInt64(1.8 * 1_073_741_824)
        m.tempC = temp(t)
        m.tempMaxC = temp(t) + 2.4
        m.thermal = .nominal
        m.diskFree = 412 * 1_073_741_824
        m.diskTotal = 1000 * 1_073_741_824
        m.onAC = true
        m.awakeHeld = true
        return m
    }

    static func groups(_ t: Double, now: Date) -> [RenderGroup] {
        // A — a queue of eight shots; the current one advances and rolls over to the next.
        let total = shots.reduce(0) { $0 + $1.frames }
        var clock = (640 + 720 + 480 + 412 + Int(t * frameRate)) % total
        var current = 0
        while clock >= shots[current].frames {
            clock -= shots[current].frames
            current += 1
        }
        var a: [RenderItem] = []
        for (i, shot) in shots.enumerated() {
            var item = RenderItem(id: "demo-a/\(shot.name)", name: shot.name, state: i < current ? .done : (i == current ? .rendering : .pending))
            if i == current {
                item.framesDone = clock
                item.framesTotal = shot.frames
                item.secPerFrame = 6.2
                item.pid = 41872
                item.cpuCores = 1.1 + 0.5 * wave(t, 3)
                item.memBytes = UInt64(2.9 * 1_073_741_824)
                item.startedAt = now.addingTimeInterval(-Double(clock) * 6.2)
            }
            a.append(item)
        }
        let groupA = RenderGroup(
            id: "demo-a", title: L("产品片 · 主镜头", "Product film · hero shots"), script: "render_hero.sh", scriptPath: nil,
            note: nil, project: "studio-reel", cwd: "/", startedAt: now.addingTimeInterval(-4380 - t), keepAwake: true, state: .running, items: a)

        // B — a bare Blender job with no known total: frame count and speed only, no percentage.
        var b = RenderItem(id: "demo-b/turntable", name: "turntable_v3", state: .rendering)
        b.framesDone = 96 + Int(t / 3.5)
        b.secPerFrame = 41
        b.pid = 42610
        b.cpuCores = 13.6 + 1.5 * wave(t, 6)
        b.memBytes = UInt64(9.8 * 1_073_741_824)
        let groupB = RenderGroup(
            id: "demo-b", title: "turntable_v3", script: nil, scriptPath: nil, note: nil, project: "lookdev", cwd: "/",
            startedAt: now.addingTimeInterval(-3960 - t), keepAwake: false, state: .running, items: [b])

        // C — paused mid-shot (SIGSTOP), with an estimated total.
        var paused = RenderItem(id: "demo-c/detail", name: "ep04_detail", state: .paused)
        paused.framesDone = 549
        paused.framesTotal = 812
        paused.totalIsEstimate = true
        paused.secPerFrame = 9.6
        paused.pid = 39114
        paused.memBytes = UInt64(1.9 * 1_073_741_824)
        let c: [RenderItem] = [
            RenderItem(id: "demo-c/intro", name: "ep04_intro", state: .done),
            RenderItem(id: "demo-c/loom", name: "ep04_loom", state: .done),
            paused,
            RenderItem(id: "demo-c/table", name: "ep04_table", state: .pending),
            RenderItem(id: "demo-c/outro", name: "ep04_outro", state: .pending),
        ]
        let groupC = RenderGroup(
            id: "demo-c", title: L("第 4 集 · 正片", "Episode 04 · final"), script: "final-ep04.sh", scriptPath: nil, note: nil,
            project: "series-main", cwd: "/", startedAt: now.addingTimeInterval(-15_840 - t), keepAwake: true, state: .paused, items: c)

        // D — a queue script waiting for its turn.
        let groupD = RenderGroup(
            id: "demo-d", title: L("夜间队列", "Night queue"), script: "queue-night.sh", scriptPath: nil, note: nil,
            project: "series-main", cwd: "/", startedAt: now.addingTimeInterval(-1260 - t), keepAwake: true, state: .waiting, items: [])

        return [groupA, groupB, groupC, groupD]
    }

    /// A small procedural "rendered frame" so the demo needs no image files.
    static func thumbnail(kind: Int, t: Double) -> NSImage {
        let size = NSSize(width: 108, height: 192)
        return NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let palettes: [[CGFloat]] = [[0.10, 0.16, 0.24, 0.95, 0.62, 0.30], [0.14, 0.12, 0.22, 0.52, 0.80, 0.98], [0.17, 0.15, 0.13, 0.96, 0.82, 0.52]]
            let p = palettes[kind % palettes.count]
            let space = CGColorSpaceCreateDeviceRGB()
            let top = CGColor(red: p[0] + 0.10, green: p[1] + 0.10, blue: p[2] + 0.12, alpha: 1)
            let bottom = CGColor(red: p[0] * 0.5, green: p[1] * 0.5, blue: p[2] * 0.5, alpha: 1)
            if let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: rect.height), options: [])
            }
            // floor
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
            ctx.fillEllipse(in: CGRect(x: -20, y: rect.height * 0.66, width: rect.width + 40, height: 70))
            let accent = CGColor(red: p[3], green: p[4], blue: p[5], alpha: 1)
            let swing = CGFloat(sin(t * 0.9 + Double(kind)))
            switch kind % 3 {
            case 0:   // exploded stack of plates
                for i in 0..<4 {
                    let y = 52 + CGFloat(i) * (22 + 4 * swing)
                    ctx.setFillColor(i == 1 ? accent : CGColor(red: 0.86, green: 0.88, blue: 0.92, alpha: 0.92 - CGFloat(i) * 0.12))
                    ctx.addPath(CGPath(roundedRect: CGRect(x: 24 + CGFloat(i) * 2, y: y, width: 60 - CGFloat(i) * 4, height: 13), cornerWidth: 5, cornerHeight: 5, transform: nil))
                    ctx.fillPath()
                }
            case 1:   // turntable sphere
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: CGRect(x: 26, y: 62, width: 56, height: 56))
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
                ctx.fillEllipse(in: CGRect(x: 40 + 9 * swing, y: 72, width: 14, height: 10))
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                ctx.fillEllipse(in: CGRect(x: 24, y: 122, width: 60, height: 12))
            default:  // rollers
                for i in 0..<3 {
                    ctx.setFillColor(i == 2 ? accent : CGColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 0.9))
                    ctx.addPath(CGPath(roundedRect: CGRect(x: 14, y: 60 + CGFloat(i) * 26, width: 80, height: 15), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
                    ctx.fillPath()
                }
            }
            return true
        }
    }
}

extension Store {
    /// Replace everything with demo data for demo time `t` (seconds).
    func loadDemo(_ t: Double) {
        let date = Date()
        groups = Demo.groups(t, now: date)
        metrics = Demo.metrics(t)
        cpuHistory = Demo.history(t, Demo.cpu)
        gpuHistory = Demo.history(t, Demo.gpu)
        memHistory = Demo.history(t, Demo.mem)
        tempHistory = Demo.history(t) { min(1, max(0, (Demo.temp($0) - 30) / 75)) }
        scanned = true
        now = date
        var images: [String: NSImage] = [:]
        for g in groups {
            for item in g.items where item.pid != nil {
                let kind = g.id == "demo-a" ? 0 : (g.id == "demo-b" ? 1 : 2)
                images[item.id] = Demo.thumbnail(kind: kind, t: item.state == .paused ? 0 : (t * 0.8).rounded(.down))
            }
        }
        thumbs = images
        onChange?()
    }
}

// MARK: Demo reel (frames for the README GIF)

/// One frame of the reel: a mock desktop with the widget and a pointer on it.
/// The reel is drawn from the same views the app uses, with demo data; the pointer and the motion are scripted.
struct ReelStage: View {
    static let size = CGSize(width: 900, height: 650)
    let store: Store
    let time: Double
    let capsuleSize: CGSize
    let panelSize: CGSize

    private static let menuBar: CGFloat = 26
    private static let topRight = CGPoint(x: size.width - 14, y: menuBar + 8)
    private static let bottomLeft = CGPoint(x: 14, y: size.height - 14)

    private struct Pose {
        var corner: CGPoint      // the widget's anchored corner on the stage
        var anchor: Anchor
        var expand: Double       // 0 capsule … 1 panel
        var pointer: CGPoint
        var click: Double?       // 0…1 ripple progress
    }

    private func ease(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }

    private func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    private func pose(_ t: Double) -> Pose {
        let tr = Self.topRight, bl = Self.bottomLeft
        let capCenterTR = CGPoint(x: tr.x - capsuleSize.width / 2, y: tr.y + capsuleSize.height / 2)
        let capCenterBL = CGPoint(x: bl.x + capsuleSize.width / 2, y: bl.y - capsuleSize.height / 2)
        let rest = CGPoint(x: Self.size.width * 0.52, y: Self.size.height * 0.56)
        let top = Anchor(h: .right, v: .top), bottom = Anchor(h: .left, v: .bottom)
        switch t {
        case ..<1.0:      // pointer travels to the capsule
            return Pose(corner: tr, anchor: top, expand: 0, pointer: mix(rest, capCenterTR, ease(t / 1.0)), click: nil)
        case ..<1.35:     // click
            return Pose(corner: tr, anchor: top, expand: 0, pointer: capCenterTR, click: (t - 1.0) / 0.35)
        case ..<1.75:     // expand
            return Pose(corner: tr, anchor: top, expand: ease((t - 1.35) / 0.4), pointer: capCenterTR, click: nil)
        case ..<5.6:      // watch the panel; pointer drifts to the collapse button
            let button = CGPoint(x: tr.x - 27, y: tr.y + 29)
            return Pose(corner: tr, anchor: top, expand: 1, pointer: mix(capCenterTR, button, ease((t - 4.6) / 0.9)), click: nil)
        case ..<5.95:
            return Pose(corner: tr, anchor: top, expand: 1, pointer: CGPoint(x: tr.x - 27, y: tr.y + 29), click: (t - 5.6) / 0.35)
        case ..<6.3:      // collapse
            return Pose(corner: tr, anchor: top, expand: 1 - ease((t - 5.95) / 0.35), pointer: CGPoint(x: tr.x - 27, y: tr.y + 29), click: nil)
        case ..<6.8:      // pointer back onto the capsule
            return Pose(corner: tr, anchor: top, expand: 0, pointer: mix(CGPoint(x: tr.x - 27, y: tr.y + 29), capCenterTR, ease((t - 6.3) / 0.5)), click: nil)
        case ..<8.2:      // drag towards the bottom-left corner (stops a little short, then snaps)
            let p = ease((t - 6.8) / 1.4)
            let short = CGPoint(x: capCenterBL.x + 26, y: capCenterBL.y - 22)
            let control = CGPoint(x: Self.size.width * 0.40, y: Self.size.height * 0.30)
            let a = mix(capCenterTR, control, p), b = mix(control, short, p)
            let c = mix(a, b, p)
            let corner = CGPoint(x: c.x - capsuleSize.width / 2, y: c.y + capsuleSize.height / 2)
            return Pose(corner: corner, anchor: bottom, expand: 0, pointer: c, click: nil)
        case ..<8.5:      // release: snaps into the corner
            let p = ease((t - 8.2) / 0.3)
            let short = CGPoint(x: bl.x + 26, y: bl.y - 22)
            return Pose(corner: mix(short, bl, p), anchor: bottom, expand: 0,
                        pointer: CGPoint(x: capCenterBL.x + 26, y: capCenterBL.y - 22), click: nil)
        case ..<9.0:      // click again
            let from = CGPoint(x: capCenterBL.x + 26, y: capCenterBL.y - 22)
            return Pose(corner: bl, anchor: bottom, expand: 0, pointer: mix(from, capCenterBL, ease((t - 8.5) / 0.25)),
                        click: t > 8.7 ? (t - 8.7) / 0.3 : nil)
        case ..<9.4:      // expands upward from the bottom-left
            return Pose(corner: bl, anchor: bottom, expand: ease((t - 9.0) / 0.4), pointer: capCenterBL, click: nil)
        case ..<10.9:     // watch it there
            return Pose(corner: bl, anchor: bottom, expand: 1, pointer: mix(capCenterBL, CGPoint(x: capCenterBL.x + 300, y: capCenterBL.y - 150), ease((t - 9.6) / 1.0)), click: nil)
        default:          // collapse; the loop restarts from the top-right
            return Pose(corner: bl, anchor: bottom, expand: 1 - ease((t - 10.9) / 0.35), pointer: CGPoint(x: capCenterBL.x + 300, y: capCenterBL.y - 150), click: nil)
        }
    }

    var body: some View {
        let p = pose(time)
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.19, blue: 0.38), Color(red: 0.30, green: 0.20, blue: 0.44), Color(red: 0.70, green: 0.40, blue: 0.36)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            // a hint of a desktop: menu bar and one window
            Rectangle().fill(.black.opacity(0.28)).frame(height: Self.menuBar)
            HStack(spacing: 14) {
                ForEach([34, 26, 30, 22], id: \.self) { w in
                    Capsule().fill(.white.opacity(0.5)).frame(width: CGFloat(w), height: 5)
                }
            }
            .offset(x: 18, y: 10.5)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .frame(width: 420, height: 300)
                .offset(x: 150, y: 120)

            widget(p)
            pointer(p)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    @ViewBuilder private func widget(_ p: Pose) -> some View {
        let unit = p.anchor.unitPoint
        if p.expand < 0.999 {
            CapsuleView(store: store)
                .scaleEffect(1 - 0.14 * p.expand, anchor: unit)
                .opacity(1 - p.expand)
                .offset(origin(of: capsuleSize, corner: p.corner, anchor: p.anchor))
        }
        if p.expand > 0.001 {
            PanelView(store: store)
                .scaleEffect(0.92 + 0.08 * p.expand, anchor: unit)
                .opacity(p.expand)
                .offset(origin(of: panelSize, corner: p.corner, anchor: p.anchor))
        }
    }

    private func origin(of size: CGSize, corner: CGPoint, anchor: Anchor) -> CGSize {
        CGSize(width: anchor.h == .left ? corner.x : corner.x - size.width,
               height: anchor.v == .top ? corner.y : corner.y - size.height)
    }

    @ViewBuilder private func pointer(_ p: Pose) -> some View {
        if let c = p.click {
            Circle()
                .stroke(.white.opacity(0.9 * (1 - c)), lineWidth: 2)
                .frame(width: 14 + 30 * c, height: 14 + 30 * c)
                .offset(x: p.pointer.x - (14 + 30 * c) / 2, y: p.pointer.y - (14 + 30 * c) / 2)
        }
        PointerShape()
            .fill(.white)
            .overlay(PointerShape().stroke(.black.opacity(0.85), lineWidth: 1))
            .frame(width: 13, height: 19)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            .offset(x: p.pointer.x, y: p.pointer.y)
    }
}

private struct PointerShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: r.height * 0.84))
        p.addLine(to: CGPoint(x: r.width * 0.30, y: r.height * 0.64))
        p.addLine(to: CGPoint(x: r.width * 0.52, y: r.height))
        p.addLine(to: CGPoint(x: r.width * 0.74, y: r.height * 0.90))
        p.addLine(to: CGPoint(x: r.width * 0.52, y: r.height * 0.58))
        p.addLine(to: CGPoint(x: r.width, y: r.height * 0.58))
        p.closeSubpath()
        return p
    }
}

/// Render the reel as PNG frames into `dir` (frame_0000.png …). Returns the frame count.
@MainActor
@discardableResult
func renderReel(to dir: String, fps: Int = 15, seconds: Double = 11.6, scale: CGFloat = 1.5) -> Int {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let store = Store()
    store.listMaxHeight = 372
    store.loadDemo(0)
    func measure<V: View>(_ v: V) -> CGSize {
        let c = NSHostingController(rootView: v.environment(\.snapshotMode, true).environment(\.colorScheme, .dark))
        let s = c.sizeThatFits(in: CGSize(width: 2000, height: 4000))
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }
    let capsule = measure(CapsuleView(store: store))
    let panel = measure(PanelView(store: store))
    let count = Int(seconds * Double(fps))
    for i in 0..<count {
        let t = Double(i) / Double(fps)
        store.loadDemo(t)
        let stage = ReelStage(store: store, time: t, capsuleSize: capsule, panelSize: panel)
            .environment(\.snapshotMode, true)
            .environment(\.demoPhase, t)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: stage)
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
        try? data.write(to: URL(fileURLWithPath: String(format: "%@/frame_%04d.png", dir, i)))
    }
    print("reel: \(count) frames → \(dir)")
    return count
}

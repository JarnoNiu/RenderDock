import AppKit
import SwiftUI

enum Layout {
    /// Transparent margin around the window, left for the shadow.
    static let pad: CGFloat = 20
    static let panelWidth: CGFloat = 388
    static let capsuleHeight: CGFloat = 42
    /// How close to a screen edge before the window snaps to it.
    static let snap: CGFloat = 34
    static let margin: CGFloat = 10
    static let headerHeight: CGFloat = 58
}

enum Theme {
    static let mint = Color(red: 0.31, green: 0.93, blue: 0.69)
    static let aqua = Color(red: 0.26, green: 0.76, blue: 1.00)
    static let amber = Color(red: 1.00, green: 0.74, blue: 0.27)
    static let coral = Color(red: 1.00, green: 0.43, blue: 0.41)
    static let lilac = Color(red: 0.70, green: 0.63, blue: 1.00)

    static func text(_ opacity: Double) -> Color { .white.opacity(opacity) }

    static let run = LinearGradient(colors: [mint, aqua], startPoint: .leading, endPoint: .trailing)

    static func color(_ s: ItemState) -> Color {
        switch s {
        case .rendering, .compositing, .finishing, .encoding, .preparing, .done: return mint
        case .paused: return amber
        case .stalled: return coral
        case .pending: return .white.opacity(0.35)
        }
    }

    static func color(_ s: GroupState) -> Color {
        switch s {
        case .running: return mint
        case .stalled: return coral
        case .paused: return amber
        case .waiting: return Color(red: 0.62, green: 0.70, blue: 0.86)
        }
    }

    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

private struct DemoPhaseKey: EnvironmentKey {
    static let defaultValue = 0.0
}

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when rendering still images: no behind-window blur, no scroll view.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }

    /// Time (seconds) used to place animated elements when rendering still frames.
    var demoPhase: Double {
        get { self[DemoPhaseKey.self] }
        set { self[DemoPhaseKey.self] = newValue }
    }
}

/// Behind-window blur (the dark HUD look).
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Background shared by the capsule and the panel: blur + darkening + hairline stroke + drop shadow.
struct HUDBackground<S: InsettableShape>: View {
    @Environment(\.snapshotMode) private var snapshot
    let shape: S

    var body: some View {
        ZStack {
            shape.fill(Color.black.opacity(0.9))
                .shadow(color: .black.opacity(0.42), radius: 13, y: 6)
            if snapshot {
                shape.fill(Color(red: 0.115, green: 0.125, blue: 0.15))
            } else {
                BehindWindowBlur().clipShape(shape)
            }
            shape.fill(LinearGradient(
                colors: [Color(red: 0.07, green: 0.08, blue: 0.11).opacity(0.50), Color(red: 0.03, green: 0.04, blue: 0.06).opacity(0.66)],
                startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                lineWidth: 0.8)
        }
    }
}

/// Progress ring with the number of shots rendering in the middle.
struct StatusRing: View {
    var fraction: Double?
    var count: Int
    var tint: Color
    var idleSymbol: String
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: lineWidth)
            if let f = fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, f))
                    .stroke(
                        AngularGradient(colors: [tint, tint == Theme.mint ? Theme.aqua : tint], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * max(0.02, f))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: f)
            } else if count > 0 {
                // Rendering but the total is unknown: a dashed ring, no made-up percentage
                Circle()
                    .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [3.2, 3.2]))
                    .rotationEffect(.degrees(-90))
            }
            if count > 0 {
                Text("\(count)").font(Theme.num(11.5, .bold)).foregroundStyle(.white)
            } else {
                Image(systemName: idleSymbol).font(.system(size: 9.5, weight: .bold)).foregroundStyle(tint.opacity(0.9))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Thin progress bar. When the total is unknown: active shots show a moving shimmer, paused ones a dashed outline.
struct ProgressBar: View {
    var fraction: Double?
    var state: ItemState
    var height: CGFloat = 5
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.demoPhase) private var demoPhase

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10))
                if let f = fraction {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, geo.size.width * f))
                        .animation(.easeOut(duration: 0.5), value: f)
                } else if state.isActive {
                    if snapshot {
                        let cycle = (demoPhase / 1.7).truncatingRemainder(dividingBy: 1)
                        Capsule().fill(Theme.run.opacity(0.75)).frame(width: geo.size.width * 0.36)
                            .offset(x: -geo.size.width * 0.36 + geo.size.width * 1.36 * (demoPhase == 0 ? 0.42 : cycle))
                    } else {
                        Shimmer(width: geo.size.width)
                    }
                } else if state == .paused || state == .stalled {
                    Capsule()
                        .stroke(Theme.color(state).opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .paused: return AnyShapeStyle(Theme.amber)
        case .stalled: return AnyShapeStyle(Theme.coral)
        default: return AnyShapeStyle(Theme.run)
        }
    }
}

private struct Shimmer: View {
    let width: CGFloat
    @State private var phase = false

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [Theme.mint.opacity(0), Theme.mint.opacity(0.9), Theme.aqua.opacity(0.9), Theme.aqua.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width * 0.36)
            .offset(x: phase ? width : -width * 0.36)
            .onAppear {
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { phase = true }
            }
    }
}

/// Segmented bar for the shots of one job: done ones are solid, rendering ones fill by progress, upcoming ones stay empty.
struct SegmentBar: View {
    let items: [RenderItem]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items) { item in
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.11))
                        switch item.state {
                        case .done:
                            Capsule().fill(Theme.mint.opacity(0.85))
                        case .pending:
                            EmptyView()
                        default:
                            Capsule()
                                .fill(Theme.color(item.state).opacity(item.fraction == nil ? 0.42 : 0.95))
                                .frame(width: item.fraction.map { max(5, geo.size.width * $0) } ?? geo.size.width)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 5)
    }
}

/// Small line chart.
struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            if pts.count >= 2 {
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.34), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        pts.dropFirst().forEach { p.addLine(to: $0) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            } else {
                Rectangle().fill(tint.opacity(0.25)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        // Few points right after launch: spread them over 24 slots first, then scroll left once there are enough
        let n = min(Store.historyLength, max(values.count, 24))
        let step = size.width / CGFloat(n - 1)
        let offset = CGFloat(n - values.count) * step
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: 1 + (size.height - 2) * (1 - CGFloat(min(1, max(0, v)))))
        }
    }
}

/// Icon button that lights up on hover.
struct IconButton: View {
    let symbol: String
    var active = false
    var help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Theme.mint : Theme.text(hover ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

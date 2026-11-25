import SwiftUI

/// The widget's face. Plain SwiftUI, so that the app can draw the same thing into a picture: the widget itself
/// only adds the system's background behind it.
package struct WidgetFace: View {
    let data: WidgetData?
    /// The medium size (two squares wide); otherwise the small square.
    let wide: Bool
    /// The moment this is drawn for.
    let now: Date
    @Environment(\.colorScheme) private var scheme

    package init(data: WidgetData?, wide: Bool, now: Date) {
        self.data = data
        self.wide = wide
        self.now = now
    }

    private var zh: Bool { data?.chinese ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true) }
    private func L(_ chinese: String, _ english: String) -> String { zh ? chinese : english }

    // The dock's own accents, bright on dark and deeper on light.
    private var mint: Color { scheme == .light ? Color(red: 0.00, green: 0.58, blue: 0.42) : Color(red: 0.31, green: 0.93, blue: 0.69) }
    private var aqua: Color { scheme == .light ? Color(red: 0.03, green: 0.46, blue: 0.86) : Color(red: 0.26, green: 0.76, blue: 1.00) }
    private var amber: Color { scheme == .light ? Color(red: 0.74, green: 0.45, blue: 0.00) : Color(red: 1.00, green: 0.74, blue: 0.27) }
    private var coral: Color { scheme == .light ? Color(red: 0.83, green: 0.23, blue: 0.21) : Color(red: 1.00, green: 0.43, blue: 0.41) }

    private var tint: Color {
        switch data?.state {
        case "stalled": return coral
        case "paused": return amber
        case "rendering": return mint
        default: return .secondary
        }
    }

    package var body: some View {
        Group {
            if let data, data.believable(at: now), data.state != "off" {
                if data.focus != nil || data.queued > 0 { wide ? AnyView(wideRender(data)) : AnyView(smallRender(data)) }
                else { quiet(data, title: L("没有渲染任务", "No render jobs"), symbol: "moon.stars.fill") }
            } else if data?.state == "off" || data != nil {
                quiet(nil, title: L("渲染坞没有在运行", "RenderDock is not running"), symbol: "powersleep")
            } else {
                quiet(nil, title: L("打开渲染坞后这里会显示进度", "Open RenderDock to see progress here"), symbol: "circle.dashed")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Pieces

    private func ring(_ data: WidgetData, size: CGFloat, line: CGFloat) -> some View {
        let fraction = data.focus?.fraction
        return ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: line)
            if let f = fraction {
                Circle().trim(from: 0, to: max(0.02, f))
                    .stroke(AngularGradient(colors: [tint, data.state == "rendering" ? aqua : tint], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(0.02, f))),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else if data.active > 0 {
                Circle().stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: line, lineCap: .butt, dash: [4, 4])).rotationEffect(.degrees(-90))
            }
            VStack(spacing: -1) {
                if let f = fraction {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(data.focus?.estimate == true ? "≈" : "")\(Int((f * 100).rounded(.down)))")
                            .font(.system(size: size * 0.34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("%").font(.system(size: size * 0.16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                } else if let done = data.focus?.framesDone, done > 0 {
                    Text("\(done)").font(.system(size: size * 0.30, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(L("帧", "frames")).font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: data.state == "paused" ? "pause.fill" : (data.state == "stalled" ? "exclamationmark" : "hourglass"))
                        .font(.system(size: size * 0.26, weight: .bold)).foregroundStyle(tint)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, line + 3)
        }
        .frame(width: size, height: size)
    }

    /// "25 分" / "1 时 24 分": how long is left, in the dock's own words.
    private func span(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return L("\(minutes) 分", "\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? L("\(h) 时", "\(h) h") : L("\(h) 时 \(m) 分", "\(h) h \(m) min")
    }

    private func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func word(_ data: WidgetData) -> String {
        switch data.state {
        case "rendering":
            if let eta = data.focus?.etaSec, eta > 0 { return L("剩约 \(span(eta))", "~\(span(eta)) left") }
            return data.active > 1 ? L("\(data.active) 段在渲", "\(data.active) rendering") : L("渲染中", "Rendering")
        case "paused": return L("已暂停", "Paused")
        case "stalled": return L("可能卡住了", "May be stuck")
        case "waiting": return data.queued > 1 ? L("\(data.queued) 条在排队", "\(data.queued) jobs queued") : L("排队等待", "Queued")
        default: return ""
        }
    }

    /// The agents, when they have something to say: who wants you first.
    private func agents(_ data: WidgetData) -> (String, Color)? {
        if data.agentsFailed > 0 { return (L("\(data.agentsFailed) 个 agent 出错", "\(data.agentsFailed) agent(s) failed"), coral) }
        if data.agentsWaiting > 0 { return (L("\(data.agentsWaiting) 个 agent 在等你", "\(data.agentsWaiting) agent(s) need you"), amber) }
        if data.agentsWorking > 0 { return (L("\(data.agentsWorking) 个 agent 在干活", "\(data.agentsWorking) agent(s) at work"), .secondary) }
        return nil
    }

    private func heading(_ data: WidgetData?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(L("渲染坞", "RenderDock")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let data, data.active > 1 {
                Text(L("\(data.active) 段在渲", "\(data.active) rendering")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    // MARK: The small square

    private func smallRender(_ data: WidgetData) -> some View {
        VStack(spacing: 0) {
            heading(nil)
            Spacer(minLength: 4)
            ring(data, size: 74, line: 7)
            Spacer(minLength: 5)
            Text(data.focus?.name ?? L("排队等待", "Queued")).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Text(word(data)).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(data.state == "rendering" ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint)).lineLimit(1)
        }
    }

    // MARK: Two squares wide

    private func wideRender(_ data: WidgetData) -> some View {
        HStack(spacing: 14) {
            ring(data, size: 96, line: 9)
            VStack(alignment: .leading, spacing: 0) {
                heading(data)
                Spacer(minLength: 5)
                if let job = data.focus?.job, !job.isEmpty, job != data.focus?.name {
                    Text(job).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(data.focus?.name ?? L("排队等待", "Queued")).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(word(data)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(data.state == "rendering" ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint)).lineLimit(1)
                    .padding(.top, 1)
                Spacer(minLength: 5)
                if let done = data.shotsDone, let total = data.shotsTotal, total > 1 {
                    HStack(spacing: 6) {
                        HStack(spacing: 2.5) {
                            ForEach(0..<min(total, 16), id: \.self) { i in
                                Capsule().fill(i < done ? AnyShapeStyle(mint.opacity(0.9)) : (i == done ? AnyShapeStyle(tint.opacity(0.55)) : AnyShapeStyle(Color.primary.opacity(0.12))))
                            }
                        }
                        .frame(height: 5)
                        Text(L("\(done)/\(total) 段", "\(done)/\(total)")).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                    if let queue = data.queueEtaSec, queue > 60 {
                        Text(L("整条队列 ≈ \(clock(data.at.addingTimeInterval(queue))) 渲完", "Whole queue done ≈ \(clock(data.at.addingTimeInterval(queue)))"))
                            .font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(aqua).lineLimit(1).padding(.top, 3)
                    }
                }
                if let (text, colour) = agents(data) {
                    Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(colour).lineLimit(1).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Nothing rendering

    private func quiet(_ data: WidgetData?, title: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: wide ? 26 : 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
            if let data, let (text, colour) = agents(data) {
                Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(colour).lineLimit(1)
            }
        }
    }
}

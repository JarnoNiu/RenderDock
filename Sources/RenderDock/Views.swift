import AppKit
import SwiftUI
import RenderDockCore

// MARK: Capsule (collapsed)

struct CapsuleView: View {
    let store: Store

    var body: some View {
        let groups = store.groups
        let focus = groups.focusItem
        HStack(spacing: 9) {
            StatusRing(fraction: ringFraction(focus), count: groups.activeCount, tint: ringTint(groups), idleSymbol: idleSymbol(groups))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1.5) {
                Text(primary(focus, groups))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(secondary(focus, groups))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.text(0.55))
            }
            .lineLimit(1)
            .monospacedDigit()
            .frame(maxWidth: 215, alignment: .leading)
            .fixedSize()

            Capsule().fill(.white.opacity(0.13)).frame(width: 1, height: 22)

            MiniStat(label: "GPU", value: store.metrics.gpu, tint: Theme.mint)
            MiniStat(label: L("内存", "MEM"), value: store.metrics.memFraction, tint: memTint(store.metrics))
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .frame(height: Layout.capsuleHeight)
        .background(HUDBackground(shape: Capsule()))
        .contentShape(Capsule())
    }

    private func ringFraction(_ focus: RenderItem?) -> Double? {
        guard let f = focus, f.state.isActive || f.state == .paused else { return nil }
        return f.fraction
    }

    private func ringTint(_ g: [RenderGroup]) -> Color {
        if g.stalledCount > 0 { return Theme.coral }
        if g.activeCount > 0 { return Theme.mint }
        if g.pausedCount > 0 { return Theme.amber }
        return Theme.text(0.6)
    }

    private func idleSymbol(_ g: [RenderGroup]) -> String {
        if g.stalledCount > 0 { return "exclamationmark" }
        if g.pausedCount > 0 { return "pause.fill" }
        if g.waitingCount > 0 { return "hourglass" }
        return "checkmark"
    }

    private func primary(_ focus: RenderItem?, _ g: [RenderGroup]) -> String {
        guard let f = focus else { return g.waitingCount > 0 ? L("排队等待", "Queued") : L("空闲", "Idle") }
        if let frac = f.fraction { return "\(f.name)  \(f.totalIsEstimate ? "≈" : "")\(Fmt.percent(frac))" }
        if let d = f.framesDone, d > 0 { return L("\(f.name)  \(d) 帧", "\(f.name)  \(d) frames") }
        return "\(f.name)  \(f.state.label)"
    }

    private func secondary(_ focus: RenderItem?, _ g: [RenderGroup]) -> String {
        guard focus != nil else { return g.waitingCount > 0 ? L("\(g.waitingCount) 条任务在排队", "\(g.waitingCount) jobs queued") : L("没有渲染任务", "No render jobs") }
        var parts: [String] = []
        if let e = focus?.eta { parts.append(L("剩约 \(Fmt.duration(e))", "~\(Fmt.duration(e)) left")) }
        if g.activeCount > 1 { parts.append(L("共 \(g.activeCount) 段在渲", "\(g.activeCount) rendering")) }
        else if g.activeCount == 1 { parts.append(L("1 段在渲", "1 rendering")) }
        if g.stalledCount > 0 { parts.append(L("\(g.stalledCount) 段卡住", "\(g.stalledCount) stalled")) }
        if g.pausedCount > 0 { parts.append(L("\(g.pausedCount) 段暂停", "\(g.pausedCount) paused")) }
        return parts.joined(separator: " · ")
    }
}

func memTint(_ m: Metrics) -> Color {
    switch m.memPressure {
    case 4: return Theme.coral
    case 2: return Theme.amber
    default: return Theme.lilac
    }
}

/// Small readout on the right of the capsule: a tiny bar plus a number.
private struct MiniStat: View {
    let label: String
    let value: Double?
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .bottom) {
                Capsule().fill(.white.opacity(0.13))
                Capsule().fill(tint).frame(height: max(3, 22 * CGFloat(value ?? 0)))
                    .animation(.easeOut(duration: 0.4), value: value)
            }
            .frame(width: 3.5, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(value.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                    .font(Theme.num(12.5))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.text(0.5))
            }
            .frame(minWidth: 21, alignment: .leading)
        }
    }
}

// MARK: Panel (expanded)

struct PanelView: View {
    let store: Store
    var onCollapse: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.8)
            taskList
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.8)
            SystemSection(store: store)
        }
        .frame(width: Layout.panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(HUDBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private var header: some View {
        let groups = store.groups
        return HStack(spacing: 10) {
            StatusRing(fraction: groups.focusItem?.fraction, count: groups.activeCount,
                       tint: groups.stalledCount > 0 ? Theme.coral : (groups.activeCount > 0 ? Theme.mint : (groups.pausedCount > 0 ? Theme.amber : Theme.text(0.6))),
                       idleSymbol: groups.pausedCount > 0 ? "pause.fill" : (groups.waitingCount > 0 ? "hourglass" : "checkmark"), lineWidth: 3.2)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("渲染任务", "Render Jobs")).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                Text(store.summary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text(0.55)).monospacedDigit()
            }
            Spacer(minLength: 6)
            IconButton(symbol: store.pinned ? "pin.fill" : "pin", active: store.pinned,
                       help: store.pinned ? L("取消固定：点别处会自动收起", "Unpin: collapse when you click elsewhere") : L("固定面板：点别处也不收起", "Pin: stay open when you click elsewhere")) {
                store.pinned.toggle()
            }
            IconButton(symbol: "chevron.up", help: L("收起成胶囊", "Collapse"), action: onCollapse)
        }
        .padding(.horizontal, 14)
        .frame(height: Layout.headerHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var taskList: some View {
        if snapshot {
            TaskListContent(store: store)
                .frame(maxHeight: store.listMaxHeight, alignment: .top)
                .clipped()
        } else {
            ScrollView(.vertical) {
                TaskListContent(store: store)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { store.listContentHeight = $0 }
            }
            .scrollIndicators(.never)
            .frame(height: min(max(store.listContentHeight, 60), store.listMaxHeight))
        }
    }
}

struct TaskListContent: View {
    let store: Store

    var body: some View {
        VStack(spacing: 8) {
            if store.groups.isEmpty {
                EmptyState(scanned: store.scanned)
            } else {
                ForEach(store.groups) { group in
                    GroupCard(group: group, store: store)
                }
            }
            if store.sleepRisk { SleepWarning() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: Layout.panelWidth)
    }
}

private struct EmptyState: View {
    let scanned: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 22))
                .foregroundStyle(LinearGradient(colors: [Theme.lilac, Theme.aqua], startPoint: .top, endPoint: .bottom))
            Text(scanned ? L("现在没有渲染任务", "No render jobs right now") : L("正在查看这台电脑…", "Looking around…"))
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text(0.9))
            Text(L("无界面的 Blender 一开渲，这里就会出现", "Start a headless Blender render and it shows up here"))
                .font(.system(size: 10.5)).foregroundStyle(Theme.text(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}

private struct SleepWarning: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 11)).foregroundStyle(Theme.amber)
            Text(L("有任务在渲，但没有防睡眠：电脑闲置睡眠会打断渲染", "Rendering with nothing keeping the Mac awake — idle sleep will interrupt it"))
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.amber)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amber.opacity(0.13)))
    }
}

// MARK: Job card

private struct GroupCard: View {
    let group: RenderGroup
    let store: Store

    var body: some View {
        let live = group.items.filter { $0.state != .done && $0.state != .pending }
        let pending = group.items.filter { $0.state == .pending }
        VStack(alignment: .leading, spacing: 9) {
            // Title row
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(Theme.color(group.state)).frame(width: 7, height: 7)
                    .shadow(color: Theme.color(group.state).opacity(0.7), radius: 3)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1.5 }
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                    .help(group.note ?? group.title)
                Spacer(minLength: 6)
                Text(group.state.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.color(group.state))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Theme.color(group.state).opacity(0.15)))
                    .fixedSize()
            }
            // Source row
            HStack(spacing: 5) {
                Text(group.project)
                if let s = group.script {
                    Text("·").foregroundStyle(Theme.text(0.3))
                    Text(s).font(.system(size: 10, design: .monospaced))
                }
                Text("·").foregroundStyle(Theme.text(0.3))
                Text(L("已跑 \(Fmt.duration(store.now.timeIntervalSince(group.startedAt)))", "up \(Fmt.duration(store.now.timeIntervalSince(group.startedAt)))"))
                if group.keepAwake {
                    Image(systemName: "cup.and.saucer.fill").font(.system(size: 8.5)).foregroundStyle(Theme.mint.opacity(0.85))
                        .help(L("这条任务有 caffeinate 按着，电脑不会闲置睡眠", "caffeinate is keeping the Mac awake for this job"))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.text(0.5))
            .lineLimit(1)
            .padding(.leading, 14)

            if group.items.count > 1 {
                HStack(spacing: 8) {
                    SegmentBar(items: group.items)
                    Text(L("\(group.doneCount)/\(group.items.count) 段", "\(group.doneCount)/\(group.items.count) shots"))
                        .font(Theme.num(10.5, .medium)).foregroundStyle(Theme.text(0.6)).fixedSize()
                }
                .padding(.leading, 14)
            }

            ForEach(live) { item in
                ItemRow(item: item, thumb: store.thumbs[item.id], now: store.now)
                    .padding(.leading, 14)
            }

            if !pending.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("待渲", "Up next")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text(0.45))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    Text(pending.map(\.name).joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text(0.5)).lineLimit(2)
                }
                .padding(.leading, 14)
            }

            if group.items.isEmpty {
                Text(L("脚本在等前面的任务结束，还没起渲染进程", "Waiting for earlier jobs; no render process yet"))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text(0.5))
                    .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.8))
        )
        .contextMenu {
            if let path = group.scriptPath {
                Button(L("在访达中显示脚本", "Show Script in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            Button(L("在访达中打开工作目录", "Open Working Folder")) { NSWorkspace.shared.open(URL(fileURLWithPath: group.cwd)) }
        }
    }
}

private struct ItemRow: View {
    let item: RenderItem
    let thumb: NSImage?
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: thumbWidth(thumb), height: 50)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
                    .help(L("最新渲出的一帧", "Latest rendered frame"))
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text(0.95))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = item.fraction {
                        Text(L("\(item.framesDone ?? 0)/\(item.totalIsEstimate ? "≈" : "")\(item.framesTotal ?? 0) 帧", "\(item.framesDone ?? 0)/\(item.totalIsEstimate ? "≈" : "")\(item.framesTotal ?? 0) frames"))
                            .font(Theme.num(10, .medium)).foregroundStyle(Theme.text(0.5))
                        Text("\(item.totalIsEstimate ? "≈" : "")\(Fmt.percent(f))")
                            .font(Theme.num(13)).foregroundStyle(.white)
                    } else if let d = item.framesDone, item.pid != nil {
                        Text("\(d)").font(Theme.num(13)).foregroundStyle(.white)
                        Text(L("帧", "frames")).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text(0.5))
                    }
                }
                if item.pid != nil { ProgressBar(fraction: item.fraction, state: item.state) }
                HStack(spacing: 5) {
                    Text(item.state.label).foregroundStyle(Theme.color(item.state))
                    ForEach(details, id: \.self) { d in
                        Text("·").foregroundStyle(Theme.text(0.3))
                        Text(d)
                    }
                    Spacer(minLength: 4)
                    if let usage { Text(usage) }
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.text(0.5))
                .lineLimit(1)
            }
        }
        .contextMenu {
            if let dir = item.outDir {
                Button(L("在访达中显示输出目录", "Show Output Folder in Finder")) {
                    if let frame = item.latestFrame {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: frame)])
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                    }
                }
            }
            if let pid = item.pid {
                Button(L("拷贝进程号 \(String(pid))", "Copy PID \(String(pid))")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(pid), forType: .string)
                }
            }
        }
    }

    /// Thumbnail width follows the aspect ratio: narrow for portrait, wide for landscape.
    private func thumbWidth(_ image: NSImage) -> CGFloat {
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        return min(86, max(28, 50 * aspect))
    }

    private var details: [String] {
        var d: [String] = []
        if item.state == .stalled, let last = item.lastFrameAt {
            d.append(L("已 \(Fmt.duration(now.timeIntervalSince(last))) 没出新帧", "no new frame for \(Fmt.duration(now.timeIntervalSince(last)))"))
        } else if item.state == .preparing, item.pid != nil {
            d.append(L("还没出帧", "no frames yet"))
        } else if item.state == .paused, item.pid == nil {
            d.append(L("这一路整条被暂停", "whole stream paused"))
        }
        if let s = item.secPerFrame { d.append(Fmt.secPerFrame(s)) }
        if let e = item.eta { d.append(L("剩约 \(Fmt.duration(e))", "~\(Fmt.duration(e)) left")) }
        return d
    }

    private var usage: String? {
        guard item.state != .paused else { return item.memBytes.map { Fmt.bytes($0) } }
        var parts: [String] = []
        if let c = item.cpuCores { parts.append(String(format: L("%.1f 核", "%.1f cores"), c)) }
        if let m = item.memBytes { parts.append(Fmt.bytes(m)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: This Mac

private struct SystemSection: View {
    let store: Store

    var body: some View {
        let m = store.metrics
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                MetricTile(title: "CPU", value: "\(Int((m.cpu * 100).rounded()))", unit: "%",
                           sub: L("\(ProcessInfo.processInfo.activeProcessorCount) 核", "\(ProcessInfo.processInfo.activeProcessorCount) cores"), history: store.cpuHistory, tint: Theme.aqua)
                MetricTile(title: L("显卡", "GPU"), value: m.gpu.map { "\(Int(($0 * 100).rounded()))" } ?? "–", unit: "%",
                           sub: m.gpuMemBytes.map { L("显存 \(Fmt.bytes($0))", "VRAM \(Fmt.bytes($0))") } ?? L("读不到", "n/a"), history: store.gpuHistory, tint: Theme.mint)
                MetricTile(title: L("内存", "Memory"), value: "\(Int((m.memFraction * 100).rounded()))", unit: "%",
                           sub: "\(Fmt.bytes(m.memUsed, digits: 0)) / \(Fmt.bytes(m.memTotal, digits: 0))", history: store.memHistory, tint: memTint(m))
                MetricTile(title: L("温度", "Temp"), value: m.tempC.map { "\(Int($0.rounded()))" } ?? "–", unit: L("℃", "°C"),
                           sub: thermalLabel(m), history: store.tempHistory, tint: thermalTint(m))
            }
            HStack(spacing: 6) {
                Chip(symbol: "arrow.left.arrow.right", text: L("交换 \(Fmt.bytes(m.swapUsed))", "Swap \(Fmt.bytes(m.swapUsed))"), tint: m.swapFraction > 0.85 || m.memPressure >= 2 ? Theme.amber : nil,
                     help: L("交换区已用 \(Fmt.bytes(m.swapUsed))，共 \(Fmt.bytes(m.swapTotal))。用得多说明内存不够、在往硬盘上倒", "Swap used: \(Fmt.bytes(m.swapUsed)) of \(Fmt.bytes(m.swapTotal)). Heavy use means memory is short and spilling to disk"))
                if let free = m.diskFree {
                    Chip(symbol: "internaldrive", text: L("剩 \(Fmt.bytes(free, digits: 0))", "\(Fmt.bytes(free, digits: 0)) free"), tint: free < 60 * 1_073_741_824 ? Theme.amber : nil,
                         help: L("磁盘可用空间", "Free disk space"))
                }
                if m.onAC == true {
                    Chip(symbol: "powerplug.fill", text: L("电源", "AC"), tint: nil, help: L("接着电源适配器", "Connected to the power adapter"))
                } else if let b = m.battery {
                    Chip(symbol: "battery.50", text: "\(b)%", tint: Theme.amber, help: L("在用电池", "On battery"))
                }
                Chip(symbol: m.awakeHeld ? "cup.and.saucer.fill" : "moon.zzz.fill", text: m.awakeHeld ? L("不睡", "Awake") : L("会睡", "May sleep"),
                     tint: m.awakeHeld ? Theme.mint : (store.sleepRisk ? Theme.amber : nil),
                     help: m.awakeHeld ? L("有程序按着不让电脑闲置睡眠", "Something is keeping the Mac from idle sleep") : L("没有防睡眠：电脑闲置一段时间会睡", "Nothing is preventing sleep: the Mac will sleep after sitting idle"))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func thermalLabel(_ m: Metrics) -> String {
        switch m.thermal {
        case .nominal: return m.tempMaxC.map { L("最高 \(Int($0.rounded()))℃", "max \(Int($0.rounded()))°C") } ?? L("正常", "Normal")
        case .fair: return L("偏热", "Warm")
        case .serious: return L("过热降速", "Throttling")
        case .critical: return L("严重过热", "Critical")
        @unknown default: return ""
        }
    }

    private func thermalTint(_ m: Metrics) -> Color {
        switch m.thermal {
        case .serious, .critical: return Theme.coral
        default: return (m.tempC ?? 0) >= 95 ? Theme.coral : Theme.amber
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let sub: String
    let history: [Double]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.6))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1.5) {
                Text(value).font(Theme.num(19)).foregroundStyle(.white)
                Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.5))
            }
            .padding(.top, 3)
            Sparkline(values: history, tint: tint)
                .frame(height: 20)
                .padding(.top, 3)
            Text(sub)
                .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.text(0.5))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.top, 5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.8))
        )
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    let tint: Color?
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(tint ?? Theme.text(0.6))
        .padding(.horizontal, 7).padding(.vertical, 3.5)
        .background(Capsule().fill((tint ?? .white).opacity(tint == nil ? 0.07 : 0.14)))
        .fixedSize()
        .help(help)
    }
}

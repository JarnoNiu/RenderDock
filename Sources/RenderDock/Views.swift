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
                    .foregroundStyle(Theme.ink)
                Text(secondary(focus, groups))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.text(0.55))
            }
            .lineLimit(1)
            .monospacedDigit()
            .frame(maxWidth: 215, alignment: .leading)
            .fixedSize()

            if !store.agentsNeedingYou.isEmpty { AgentBadge(count: store.agentsNeedingYou.count, failed: store.agents.count(.error) > 0) }
            if !store.inbox.questions.isEmpty { QuestionBadge(count: store.inbox.questions.count) }

            Capsule().fill(Theme.fill(0.13)).frame(width: 1, height: 22)

            MiniStat(label: "GPU", value: store.metrics.gpu, tint: Theme.mint)
            MiniStat(label: L("内存", "MEM"), value: store.metrics.memFraction, tint: memTint(store.metrics))
        }
        // The window is only as wide as the capsule was a moment ago. Without this, content that grows is
        // squeezed into the old width (text wraps) and the window never learns that it should widen.
        .fixedSize()
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .frame(height: Layout.capsuleHeight)
        .background(HUDBackground(shape: Capsule()))
        .contentShape(Capsule())
    }

    // (Not private: the notch form says the same things in less room.)
    func ringFraction(_ focus: RenderItem?) -> Double? {
        guard let f = focus, f.state.isActive || f.state == .paused else { return nil }
        return f.fraction
    }

    func ringTint(_ g: [RenderGroup]) -> Color {
        if g.stalledCount > 0 { return Theme.coral }
        if g.activeCount > 0 { return Theme.mint }
        if g.pausedCount > 0 { return Theme.amber }
        return Theme.text(0.6)
    }

    func idleSymbol(_ g: [RenderGroup]) -> String {
        if g.stalledCount > 0 { return "exclamationmark" }
        if g.pausedCount > 0 { return "pause.fill" }
        if g.waitingCount > 0 { return "hourglass" }
        return "checkmark"
    }

    func primary(_ focus: RenderItem?, _ g: [RenderGroup]) -> String {
        guard let f = focus else {
            if g.waitingCount > 0 { return L("排队等待", "Queued") }
            // Nothing renders: the capsule speaks for the agents instead.
            if let top = store.agents.top { return "\(AgentTool.displayName(top.tool))  \(top.state.label)" }
            return L("空闲", "Idle")
        }
        if let frac = f.fraction { return "\(f.name)  \(f.totalIsEstimate ? "≈" : "")\(Fmt.percent(frac))" }
        if let d = f.framesDone, d > 0 { return L("\(f.name)  \(d) 帧", "\(f.name)  \(d) frames") }
        return "\(f.name)  \(f.state.label)"
    }

    private func secondary(_ focus: RenderItem?, _ g: [RenderGroup]) -> String {
        guard focus != nil else {
            if g.waitingCount > 0 { return L("\(g.waitingCount) 条任务在排队", "\(g.waitingCount) jobs queued") }
            return store.agentSummary ?? L("没有渲染任务", "No render jobs")
        }
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

/// On the capsule while another program's question is waiting for an answer: how many.
private struct QuestionBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "questionmark.bubble.fill").font(.system(size: 8.5, weight: .bold))
            Text("\(count)").font(Theme.num(11))
        }
        .foregroundStyle(Theme.lilac)
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.lilac.opacity(0.18)))
        .fixedSize()
        .help(L("有问题在等你回答，展开面板作答", "A question is waiting for your answer: expand the panel"))
    }
}

/// On the capsule while a session is waiting for the user (or failed): how many.
private struct AgentBadge: View {
    let count: Int
    let failed: Bool

    var body: some View {
        let tint = failed ? Theme.coral : Theme.amber
        HStack(spacing: 3) {
            Image(systemName: failed ? "exclamationmark" : "hand.raised.fill").font(.system(size: 8.5, weight: .bold))
            Text("\(count)").font(Theme.num(11))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.18)))
        .fixedSize()
        .help(L("\(count) 个 agent 会话在等你", "\(count) agent session(s) need you"))
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
                Capsule().fill(Theme.fill(0.13))
                Capsule().fill(tint).frame(height: max(3, 22 * CGFloat(value ?? 0)))
                    .animation(.easeOut(duration: 0.4), value: value)
            }
            .frame(width: 3.5, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                // Room for three digits at all times: the capsule keeps its width when a reading reaches 100,
                // and the number can never be squeezed onto two lines.
                ZStack(alignment: .leading) {
                    Text("100").hidden()
                    Text(value.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                        .foregroundStyle(Theme.ink)
                }
                .font(Theme.num(12.5))
                .lineLimit(1)
                .fixedSize()
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.text(0.5))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

// MARK: Panel (expanded)

struct PanelView: View {
    let store: Store
    var onCollapse: () -> Void = {}
    /// Without its own ground and outline: for the notch form, which gives it both.
    var bare = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let content = VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.fill(0.08)).frame(height: 0.8)
            taskList
            Rectangle().fill(Theme.fill(0.08)).frame(height: 0.8)
            SystemSection(store: store)
        }
        .frame(width: Layout.panelWidth)
        if bare {
            content
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .background(HUDBackground(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
        }
    }

    private var header: some View {
        let groups = store.groups
        return HStack(spacing: 10) {
            StatusRing(fraction: groups.focusItem?.fraction, count: groups.activeCount,
                       tint: groups.stalledCount > 0 ? Theme.coral : (groups.activeCount > 0 ? Theme.mint : (groups.pausedCount > 0 ? Theme.amber : Theme.text(0.6))),
                       idleSymbol: groups.pausedCount > 0 ? "pause.fill" : (groups.waitingCount > 0 ? "hourglass" : "checkmark"), lineWidth: 3.2)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("渲染任务", "Render Jobs")).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(store.summary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text(0.55)).monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            // The agents get a mark up here: with several jobs in the list, their own block is below the fold.
            if let top = store.agents.top, let summary = store.agentSummary {
                HStack(spacing: 3) {
                    Image(systemName: top.state.symbol).font(.system(size: 8.5, weight: .bold))
                    Text("\(store.agents.count(top.state))").font(Theme.num(11))
                }
                .foregroundStyle(top.state.tint)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(top.state.tint.opacity(0.16)))
                .fixedSize()
                .help(L("Agent 会话：\(summary)。往下滚能看到每一个", "Agents' sessions: \(summary). Scroll down for each one"))
            }
            IconButton(symbol: store.pinned ? "pin.fill" : "pin", active: store.pinned,
                       help: store.pinned ? L("取消固定：点别处会自动收起", "Unpin: collapse when you click elsewhere") : L("固定面板：点别处也不收起", "Pin: stay open when you click elsewhere")) {
                store.pinned.toggle()
            }
            IconButton(symbol: "chevron.up", help: bare ? L("收起", "Collapse") : L("收起成胶囊", "Collapse"), action: onCollapse)
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
            ForEach(store.requests) { request in
                RequestCard(request: request, now: store.now) { store.answer(request.id, $0) }
            }
            ForEach(store.inbox.questions) { question in
                QuestionCard(question: question, now: store.now, pick: { store.answerQuestion(question.id, $0) }, dismiss: { store.dismissQuestion(question.id) })
            }
            if !store.agentsNeedingYou.isEmpty, store.requests.isEmpty { AgentAttention(sessions: store.agentsNeedingYou) }
            if !store.inbox.notices.isEmpty || !store.inbox.tasks.isEmpty { InboxSection(inbox: store.inbox, now: store.now, store: store) }
            if store.groups.isEmpty {
                // With agents or another program's things to show, a full-height "nothing here" would only push them down.
                if store.agents.isEmpty, store.inbox.isEmpty { EmptyState(scanned: store.scanned) }
            } else {
                ForEach(store.groups) { group in
                    GroupCard(group: group, store: store)
                }
            }
            if store.sleepRisk { SleepWarning() }
            if !store.agents.isEmpty { AgentSection(sessions: store.agents, summary: store.agentSummary, now: store.now, showTitles: store.agentTitles) }
            if !store.recentRuns.isEmpty { RecentRuns(runs: store.recentRuns, now: store.now) }
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

// MARK: Coding agents

extension AgentState {
    var tint: Color {
        switch self {
        case .error: return Theme.coral
        case .waiting: return Theme.amber
        case .working: return Theme.aqua
        case .done: return Theme.mint
        case .idle, .stale: return Theme.text(0.4)
        }
    }

    var symbol: String {
        switch self {
        case .error: return "xmark"
        case .waiting: return "hand.raised.fill"
        case .working: return "circle.dotted"
        case .done: return "checkmark"
        case .idle: return "moon.fill"
        case .stale: return "questionmark"
        }
    }
}

/// The one thing worth an interruption: a session is waiting for the user.
private struct AgentAttention: View {
    let sessions: [AgentSession]

    var body: some View {
        let first = sessions[0]
        let tint = first.state.tint
        HStack(spacing: 7) {
            Image(systemName: first.state.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(text(first)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(tint).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.13)))
    }

    private func text(_ s: AgentSession) -> String {
        let who = "\(AgentTool.displayName(s.tool)) · \(s.project)"
        let more = sessions.count - 1
        let rest = more > 0 ? L("，另有 \(more) 个", ", and \(more) more") : ""
        if s.state == .error { return L("\(who) 出错了\(rest)", "\(who) failed\(rest)") }
        return L("\(who) 在等你\(rest)", "\(who) needs you\(rest)")
    }
}

/// An agent is asking whether it may do something. What it would do is shown whole; the answer is for this once.
private struct RequestCard: View {
    let request: ControlRequest
    let now: Date
    let answer: (ControlDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.amber)
                Text("\(AgentTool.displayName(request.tool)) · \(request.project)")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(L("还等 \(Fmt.duration(max(0, request.expiresAt.timeIntervalSince(now))))", "\(Fmt.duration(max(0, request.expiresAt.timeIntervalSince(now)))) left"))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text(0.45)).fixedSize()
                    .help(L("到时间没人答，就回到 agent 自己的窗口里去问", "With no answer by then, the agent asks in its own window"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(request.action)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.amber)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.amber.opacity(0.16)))
                    .fixedSize()
                // What may be allowed is shown whole, however many lines that takes: nothing is cut out of it.
                // (How long it may be at all is the policy's limit.) What can only be denied here is cut short.
                Text(request.detail.isEmpty ? L("（没有说明）", "(no details)") : request.detail)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text(0.88))
                    .lineLimit(request.approvable ? nil : 2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 7) {
                if request.approvable {
                    AnswerButton(title: L("允许这一次", "Allow once"), tint: Theme.mint) { answer(.allow) }
                } else if let reason = request.reason {
                    Text(reason).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text(0.5)).lineLimit(2)
                }
                Spacer(minLength: 4)
                AnswerButton(title: L("拒绝", "Deny"), tint: Theme.coral) { answer(.deny) }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.amber.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.amber.opacity(0.35), lineWidth: 0.8)))
    }
}

private struct AnswerButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(hover ? 0.28 : 0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .fixedSize()
    }
}

// MARK: From other programs (the entry: `renderdock notify | progress | ask`)

/// Another program is asking the user something. Not a permission request, and drawn so it cannot be taken for
/// one: nothing is allowed by answering, and the answer goes back to whoever asked.
private struct QuestionCard: View {
    let question: InboxQuestion
    let now: Date
    let pick: (Int) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.lilac)
                Text(question.from.isEmpty ? L("有个程序问你", "A program asks") : L("\(question.from) 问你", "\(question.from) asks"))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                Text(L("还等 \(Fmt.duration(max(0, question.expiresAt.timeIntervalSince(now))))", "\(Fmt.duration(max(0, question.expiresAt.timeIntervalSince(now)))) left"))
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text(0.45)).fixedSize()
                    .help(L("到时间没人答，提问的程序会得到「没有回答」", "With no answer by then, the program that asked is told there was none"))
            }
            Text(question.text)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text(0.92))
                .lineLimit(6).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Side by side when they fit; one under another when they do not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { choices; Spacer(minLength: 4); skip }
                VStack(alignment: .leading, spacing: 6) { choices; skip }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.lilac.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.lilac.opacity(0.35), lineWidth: 0.8)))
    }

    @ViewBuilder private var choices: some View {
        ForEach(Array(question.choices.enumerated()), id: \.offset) { index, label in
            AnswerButton(title: label, tint: Theme.lilac) { pick(index) }
        }
    }

    private var skip: some View {
        Button(action: dismiss) {
            Text(L("不回答", "No answer")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text(0.45))
                .padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("提问的程序会得到「没有回答」", "The program that asked is told there was no answer"))
    }
}

/// What other programs report: the tasks they are working through, and what they have said lately.
private struct InboxSection: View {
    let inbox: InboxView
    let now: Date
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("其他程序报来的", "From Other Programs"))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.45))
            ForEach(inbox.tasks) { task in InboxTaskRow(task: task, now: now) { store.dismissTask(task.id) } }
            ForEach(inbox.notices) { notice in InboxNoticeRow(notice: notice, now: now) { store.dismissNotice(notice.id) } }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.fill(0.035)))
    }
}

/// The name a program gave for itself, as a small tag. It is whatever the program said: nothing checks it.
private struct SenderTag: View {
    let name: String

    var body: some View {
        if !name.isEmpty {
            Text(name)
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text(0.7))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Theme.fill(0.08)))
                .lineLimit(1).fixedSize()
        }
    }
}

private struct CloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.text(0.35))
                .frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct InboxTaskRow: View {
    let task: InboxTask
    let now: Date
    let dismiss: () -> Void

    var body: some View {
        let tint = task.state == "error" ? Theme.coral : task.state == "done" ? Theme.mint : Theme.aqua
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SenderTag(name: task.from)
                Text(task.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text(0.92)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                if let f = task.fraction, task.state == "working" {
                    Text(Fmt.percent(f)).font(Theme.num(12)).foregroundStyle(Theme.ink).fixedSize()
                }
                CloseButton(help: L("从这里拿掉（那个程序自己不受影响）", "Take it off this list (the program itself is not affected)"), action: dismiss)
            }
            if task.state == "working" { ProgressBar(fraction: task.fraction, state: .rendering) .frame(height: 5) }
            Text(detail).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(tint).lineLimit(1)
        }
    }

    private var detail: String {
        switch task.state {
        case "done": return L("做完了 · \(Fmt.duration(now.timeIntervalSince(task.updatedAt)))前", "Done · \(Fmt.duration(now.timeIntervalSince(task.updatedAt))) ago")
        case "error": return L("失败了 · \(Fmt.duration(now.timeIntervalSince(task.updatedAt)))前", "Failed · \(Fmt.duration(now.timeIntervalSince(task.updatedAt))) ago")
        default:
            var parts = [L("进行中 · 已 \(Fmt.duration(now.timeIntervalSince(task.startedAt)))", "Working · \(Fmt.duration(now.timeIntervalSince(task.startedAt)))")]
            if let eta = task.etaSec { parts.append(L("剩约 \(Fmt.duration(TimeInterval(eta)))", "~\(Fmt.duration(TimeInterval(eta))) left")) }
            // A program that has gone quiet may have stopped without saying so.
            let quiet = now.timeIntervalSince(task.updatedAt)
            if quiet > 90 { parts.append(L("\(Fmt.duration(quiet)) 没有新消息", "no word for \(Fmt.duration(quiet))")) }
            return parts.joined(separator: " · ")
        }
    }
}

private struct InboxNoticeRow: View {
    let notice: InboxNotice
    let now: Date
    let dismiss: () -> Void

    var body: some View {
        let tint = notice.level == .error ? Theme.coral : notice.level == .done ? Theme.mint : Theme.aqua
        let symbol = notice.level == .error ? "xmark" : notice.level == .done ? "checkmark" : "bubble.left.fill"
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint).frame(width: 11)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    SenderTag(name: notice.from)
                    if !notice.title.isEmpty {
                        Text(notice.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text(0.92)).lineLimit(1).layoutPriority(1)
                    }
                    Spacer(minLength: 4)
                    Text(L("\(Fmt.duration(now.timeIntervalSince(notice.at)))前", "\(Fmt.duration(now.timeIntervalSince(notice.at))) ago"))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text(0.4)).fixedSize()
                }
                if !notice.body.isEmpty {
                    Text(notice.body).font(.system(size: 11)).foregroundStyle(Theme.text(0.72))
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            CloseButton(help: L("知道了", "Dismiss"), action: dismiss)
        }
    }
}

/// Coding agents' sessions: the ones doing something, then one line for the idle rest.
private struct AgentSection: View {
    let sessions: [AgentSession]
    let summary: String?
    let now: Date
    let showTitles: Bool

    private static let maxRows = 8

    var body: some View {
        let live = sessions.filter { $0.state != .idle }
        let idle = sessions.count - live.count
        let hidden = max(0, live.count - Self.maxRows)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("Agent 任务", "Agents"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.45))
                Spacer(minLength: 4)
                if let summary {
                    Text(summary).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text(0.5)).lineLimit(1)
                }
            }
            ForEach(live.prefix(Self.maxRows)) { session in
                AgentRow(session: session, now: now, showTitle: showTitles)
            }
            if hidden > 0 || idle > 0 {
                Text(rest(hidden: hidden, idle: idle))
                    .font(.system(size: 10)).foregroundStyle(Theme.text(0.4))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.fill(0.035)))
    }

    private func rest(hidden: Int, idle: Int) -> String {
        var parts: [String] = []
        if hidden > 0 { parts.append(L("还有 \(hidden) 个没列出", "\(hidden) more not listed")) }
        if idle > 0 { parts.append(sessions.count == idle ? L("\(idle) 个会话，都空闲", "\(idle) session(s), all idle") : L("另有 \(idle) 个空闲", "\(idle) more idle")) }
        return parts.joined(separator: " · ")
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let now: Date
    let showTitle: Bool

    var body: some View {
        let tint = session.state.tint
        HStack(spacing: 6) {
            Image(systemName: session.state.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint).frame(width: 11)
            Text(AgentTool.displayName(session.tool))
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text(0.7))
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Capsule().fill(Theme.fill(0.08)))
                .fixedSize()
            // The project name is the part to keep: the title gives way first when the row is tight.
            Text(session.project).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text(0.85)).lineLimit(1).layoutPriority(1)
            if showTitle, let title = session.title, !title.isEmpty {
                Text(title).font(.system(size: 10)).foregroundStyle(Theme.text(0.4)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(detail).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(tint).fixedSize()
        }
        .help(tooltip)
    }

    private var detail: String {
        var parts = [session.state.label]
        if session.state == .waiting, let what = session.waitingFor, !what.isEmpty {
            parts.append(what.count > 20 ? String(what.prefix(19)) + "…" : what)
        }
        if let since = session.since { parts.append(Fmt.duration(now.timeIntervalSince(since))) }
        return parts.joined(separator: " · ")
    }

    private var tooltip: String {
        let origin = session.source == "official"
            ? L("来自这个工具自己的命令", "Reported by the tool's own command")
            : L("从这个工具的本地文件读到，尽力而为；「在等批准」这样读不出来", "Read from the tool's local files, best effort; a pending approval cannot be seen this way")
        guard session.state == .waiting, let what = session.waitingFor, !what.isEmpty else { return origin }
        return L("在等：\(what)\n\(origin)", "Waiting for: \(what)\n\(origin)")
    }
}

/// One line of hint under a shot: frames worth a second look.
private struct OddFrames: View {
    let symbol: String
    let tint: Color
    let text: String
    let help: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(tint)
        .help(help)
    }
}

/// What ended most recently, from history.
private struct RecentRuns: View {
    let runs: [HistoryRun]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("最近结束", "Recently ended"))
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.45))
            ForEach(runs, id: \.id) { run in
                HStack(spacing: 6) {
                    Image(systemName: symbol(run)).font(.system(size: 9, weight: .bold)).foregroundStyle(tint(run)).frame(width: 11)
                    Text(run.shot).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text(0.85)).lineLimit(1)
                    Text(run.jobTitle).font(.system(size: 10)).foregroundStyle(Theme.text(0.4)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(detail(run)).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(Theme.text(0.5)).fixedSize()
                }
                .help(tooltip(run))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.fill(0.035)))
    }

    private func symbol(_ r: HistoryRun) -> String {
        switch r.outcome {
        case "failed": return "xmark"
        case "ended": return "minus"
        default: return "checkmark"
        }
    }

    private func tint(_ r: HistoryRun) -> Color {
        switch r.outcome {
        case "failed": return Theme.coral
        case "ended": return Theme.text(0.45)
        default: return Theme.mint
        }
    }

    private func detail(_ r: HistoryRun) -> String {
        var parts: [String] = []
        if r.outcome == "failed", let code = r.exitCode { parts.append(L("退出码 \(code)", "exit \(code)")) }
        if let d = r.duration { parts.append(Fmt.duration(d)) }
        if let f = r.framesDone, f > 0 { parts.append(L("\(f) 帧", "\(f) frames")) }
        if let energy = r.energyWh, energy >= 0.05 { parts.append(Fmt.energy(energy)) }
        if let e = r.endedAt { parts.append(Fmt.clock(Date(timeIntervalSince1970: e))) }
        return parts.joined(separator: " · ")
    }

    private func tooltip(_ r: HistoryRun) -> String {
        switch r.outcome {
        case "finished": return L("渲完了（包装命令记下的退出码是 0）", "Finished (the wrapper recorded exit status 0)")
        case "failed": return L("失败（包装命令记下了退出码）", "Failed (the wrapper recorded the exit status)")
        case "done": return L("队列已经渲到它后面去了", "The queue moved on past it")
        default: return L("进程没了，分不清是渲完还是中断", "Its processes are gone; RenderDock cannot tell finished from interrupted")
        }
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

/// Why a job is held, as one line for its card.
enum HoldWords {
    static func word(_ reason: HoldReason) -> String {
        switch reason {
        case .manual: return L("你在这里暂停的", "paused here by you")
        case .heat: return L("电脑过热降速", "the Mac is slowed down for heat")
        case .battery: return L("电脑在用电池", "the Mac is on its battery")
        case .turns: return L("等前一条渲完", "waiting for the job before it")
        }
    }

    static func line(_ reasons: [HoldReason]) -> String? {
        guard let first = reasons.first else { return nil }
        if first == .manual, reasons.count == 1 { return word(.manual) }
        let rules = reasons.filter { $0 != .manual }.map(word).joined(separator: L("；", "; "))
        return reasons.contains(.manual) ? L("你在这里暂停的；另外：\(rules)", "Paused here by you; also: \(rules)") : L("渲染坞暂停的：\(rules)", "Paused by RenderDock: \(rules)")
    }
}

/// One of the small round buttons on a job's title row.
private struct HandButton: View {
    let symbol: String
    let lit: Bool
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(lit ? tint : Theme.text(0.6))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(lit ? tint.opacity(0.18) : Theme.fill(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }
}

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
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .help(group.note ?? group.title)
                Spacer(minLength: 6)
                // Hands on: only where the switch for it is on, and only for a job with a render process of its own.
                if store.handsVersion >= 0, store.canHandle(group) {
                    let held = !store.holdReasons(group.id).isEmpty
                    if store.handsSettings.yield {
                        HandButton(symbol: "tortoise.fill", lit: store.isYielding(group.id), tint: Theme.aqua,
                                   help: store.isYielding(group.id)
                                       ? L("已让路：这条任务只用电脑空出来的力气。点一下恢复", "Out of the way: this job runs on what the Mac has to spare. Click to put it back")
                                       : L("让路：让这条任务只用电脑空出来的力气，你先用电脑", "Out of the way: let this job run on what the Mac has to spare while you use it")) {
                            store.toggleYield(group.id)
                        }
                    }
                    if store.handsSettings.manual {
                        let stopped = held || group.state == .paused
                        HandButton(symbol: stopped ? "play.fill" : "pause.fill", lit: stopped, tint: Theme.amber,
                                   help: stopped ? L("继续这条任务", "Let this job go on") : L("暂停这条任务（停在原地，不丢进度）", "Pause this job (it stops where it is and loses nothing)")) {
                            if stopped { store.resumeJob(group.id) } else { store.pauseJob(group.id) }
                        }
                    }
                }
                Text(group.state.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.color(group.state))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Theme.color(group.state).opacity(0.15)))
                    .fixedSize()
            }
            // Why RenderDock is holding this job, in words.
            if store.handsVersion >= 0, let why = HoldWords.line(store.holdReasons(group.id)) {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 9.5, weight: .semibold))
                    Text(why)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.amber)
                .lineLimit(1)
                .padding(.leading, 14)
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

            if let eta = group.queueETA {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                    Text(L("整条队列约 \(Fmt.duration(eta.seconds))后渲完，≈ \(Fmt.clock(store.now.addingTimeInterval(eta.seconds)))",
                           "Queue done in ~\(Fmt.duration(eta.seconds)), ≈ \(Fmt.clock(store.now.addingTimeInterval(eta.seconds)))")
                         + (eta.guessed > 0 ? L("（粗估）", " (rough)") : ""))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.aqua.opacity(0.9))
                .lineLimit(1)
                .padding(.leading, 14)
                .help(eta.guessed > 0
                      ? L("按历史估算。有 \(eta.guessed) 段以前没渲过，用的是这条队列已渲完各段的平均时长", "Estimated from history. \(eta.guessed) shot(s) never ran before and were given this queue's average")
                      : L("按历史估算：在渲的段用它自己的剩余时间，没渲的段用它上一次的时长", "Estimated from history: the shot in progress by its own time left, the others by how long they took last time"))
            }

            ForEach(live) { item in
                ItemRow(item: item, thumb: store.thumbs[item.id], now: store.now, onPreview: item.outDir == nil ? nil : { store.onPreview?(item) })
                    .padding(.leading, 14)
            }

            if !pending.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("待渲", "Up next")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.text(0.45))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.fill(0.08)))
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
                .fill(Theme.fill(0.055))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.fill(0.07), lineWidth: 0.8))
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
    /// Opens the larger look at this shot's frames. Nil when there is no output folder to look into.
    var onPreview: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let thumb {
                Image(nsImage: thumb)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: thumbWidth(thumb), height: 50)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.fill(0.14), lineWidth: 0.8))
                    .help(onPreview == nil ? L("最新渲出的一帧", "Latest rendered frame") : L("最新渲出的一帧。点一下看大图，回看已渲的帧", "Latest rendered frame. Click for a larger look, and to go back through the frames"))
                    .onTapGesture { onPreview?() }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text(0.95))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = item.fraction {
                        // An encode counts in time, not frames: how much of the output is written, of how long it will be.
                        Text(item.framesTotal == nil && item.mediaTotal != nil
                             ? "\(Fmt.media(item.mediaDone ?? 0)) / \(item.totalIsEstimate ? "≈" : "")\(Fmt.media(item.mediaTotal ?? 0))"
                             : L("\(item.framesDone ?? 0)/\(item.totalIsEstimate ? "≈" : "")\(item.framesTotal ?? 0) 帧", "\(item.framesDone ?? 0)/\(item.totalIsEstimate ? "≈" : "")\(item.framesTotal ?? 0) frames"))
                            .font(Theme.num(10, .medium)).foregroundStyle(Theme.text(0.5))
                            .lineLimit(1).fixedSize()
                        Text("\(item.totalIsEstimate ? "≈" : "")\(Fmt.percent(f))")
                            .font(Theme.num(13)).foregroundStyle(Theme.ink)
                            .lineLimit(1).fixedSize()
                    } else if let d = item.framesDone, item.pid != nil {
                        Text("\(d)").font(Theme.num(13)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                        Text(L("帧", "frames")).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text(0.5)).lineLimit(1).fixedSize()
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
                if !item.smallFrames.isEmpty {
                    OddFrames(symbol: "exclamationmark.triangle.fill", tint: Theme.amber,
                              text: L("\(item.smallFrames.count) 帧文件明显偏小：", "\(item.smallFrames.count) frame(s) with an unusually small file: ") + item.smallFrames.map { "#\($0)" }.joined(separator: " "),
                              help: L("这几帧的文件不到平时的四分之一，可能是空帧或黑帧，值得看一眼。只是提示，不是结论", "These files are under a quarter of the usual size. They may be empty or black and are worth a look. A hint, not a verdict"))
                }
                if !item.slowFrames.isEmpty {
                    OddFrames(symbol: "tortoise.fill", tint: Theme.text(0.55),
                              text: L("\(item.slowFrames.count) 帧间隔特别长：", "\(item.slowFrames.count) frame(s) took unusually long: ") + item.slowFrames.map { "#\($0)" }.joined(separator: " "),
                              help: L("这几帧之前的间隔是平时的五倍以上：可能是特别难渲的帧，也可能是任务中途被暂停过", "The gap before these frames was over five times the usual one: a hard frame, or the job was paused"))
                }
            }
        }
        .contextMenu {
            if let onPreview {
                Button(L("看大图，回看已渲的帧", "Larger Look, and Back Through the Frames")) { onPreview() }
            }
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
        if item.state == .rendering, let sd = item.sampleDone, let st = item.sampleTotal { d.append(L("采样 \(sd)/\(st)", "sample \(sd)/\(st)")) }
        if let s = item.secPerFrame { d.append(Fmt.secPerFrame(s)) }
        // An encode whose length is not known still says how much it has written; one that reports its speed says that too.
        if item.fraction == nil, let written = item.mediaDone { d.append(L("已写出 \(Fmt.media(written))", "\(Fmt.media(written)) written")) }
        if item.state == .encoding, let speed = item.mediaSpeed { d.append(String(format: "%.1f×", speed)) }
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
            // The fans and the draw, on a Mac that reports them: a row of their own, the one above being full.
            if m.fanRpm != nil || m.powerW != nil {
                HStack(spacing: 6) {
                    if let rpm = m.fanRpm {
                        // Amber when a fan is close to as fast as it goes: the Mac has nothing left to cool itself with.
                        Chip(symbol: "fanblades.fill", text: L("\(Int(rpm.rounded())) 转", "\(Int(rpm.rounded())) rpm"), tint: (m.fanFraction ?? 0) >= 0.9 ? Theme.amber : nil,
                             help: m.fans.count > 1
                                ? L("风扇转速（每分钟）：\(m.fans.map { String(Int($0.rpm.rounded())) }.joined(separator: "、"))", "Fan speeds, turns a minute: \(m.fans.map { String(Int($0.rpm.rounded())) }.joined(separator: ", "))")
                                : L("风扇转速，每分钟", "Fan speed, turns a minute"))
                    }
                    if let watts = m.powerW {
                        Chip(symbol: "bolt.fill", text: "\(Int(watts.rounded())) W", tint: nil,
                             help: L("整机功耗，电脑自己的控制器报的数，不是在插座上量的", "What the whole Mac is drawing, as its own controller reports it; not measured at the wall"))
                    }
                    Spacer(minLength: 0)
                }
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
                Text(value).font(Theme.num(19)).foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text(0.5))
            }
            .lineLimit(1)
            .fixedSize()
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
                .fill(Theme.fill(0.055))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.fill(0.07), lineWidth: 0.8))
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
        .background(Capsule().fill(tint.map { $0.opacity(0.14) } ?? Theme.fill(0.07)))
        .fixedSize()
        .help(help)
    }
}

import AppKit
import SwiftUI
import RenderDockCore

/// The shape the dock takes: a capsule that floats where it is put, or part of the notch.
enum DockForm: String, CaseIterable {
    case capsule, notch

    static let key = "form"
    static var saved: DockForm { DockForm(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .capsule }
}

/// The notch of the screen the dock hangs from, in points. A screen without one has width 0: the dock is then
/// a small island of its own at the top edge.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat

    var real: Bool { width > 0 }

    /// What a screen has: the gap between the two areas beside its notch, as tall as the safe area above.
    static func of(_ screen: NSScreen) -> NotchMetrics {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 20 { return NotchMetrics(width: width, height: top) }
        }
        return NotchMetrics(width: 0, height: 26)
    }

    /// The screen the notch form goes to: the one with a notch if there is one, else the main one.
    static func screen() -> NSScreen {
        NSScreen.screens.first { of($0).real } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

/// Square where it meets the top edge of the screen, round below: the notch's own outline, grown.
private func notchShape(_ radius: CGFloat) -> UnevenRoundedRectangle {
    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: 0), style: .continuous)
}

/// What stands beside the notch: how the renders are doing on the left, the number that matters on the right.
/// Shared by the collapsed form and the strip on top of the open panel, so nothing jumps when it opens.
private struct NotchEars: View {
    let store: Store
    let notch: NotchMetrics
    /// The ears' width when something is going on. With nothing going on they close up, and only the notch is left.
    static let ear: CGFloat = 58

    var body: some View {
        let glance = CapsuleView(store: store)
        let groups = store.groups
        let focus = groups.focusItem
        HStack(spacing: 0) {
            StatusRing(fraction: glance.ringFraction(focus), count: groups.activeCount, tint: glance.ringTint(groups),
                       idleSymbol: glance.idleSymbol(groups), lineWidth: 2.6)
                .frame(width: 21, height: 21)
                .frame(width: Self.ear)
            Color.clear.frame(width: notch.width)
            right(focus).frame(width: Self.ear)
        }
        .frame(height: notch.height)
    }

    /// The one number: how far the render in front is; or, with none, how many sessions want you, or are at work.
    @ViewBuilder private func right(_ focus: RenderItem?) -> some View {
        if let f = focus, let fraction = f.fraction {
            Text("\(f.totalIsEstimate ? "≈" : "")\(Fmt.percent(fraction))").font(Theme.num(12.5)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
        } else if let f = focus, let done = f.framesDone, done > 0 {
            Text("\(done)").font(Theme.num(12.5)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
        } else if !store.agentsNeedingYou.isEmpty {
            let failed = store.agents.count(.error) > 0
            HStack(spacing: 3) {
                Image(systemName: failed ? "exclamationmark" : "hand.raised.fill").font(.system(size: 9, weight: .bold))
                Text("\(store.agentsNeedingYou.count)").font(Theme.num(12))
            }
            .foregroundStyle(failed ? Theme.coral : Theme.amber)
        } else if !store.inbox.questions.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 9, weight: .bold))
                Text("\(store.inbox.questions.count)").font(Theme.num(12))
            }
            .foregroundStyle(Theme.lilac)
        } else if store.agents.count(.working) > 0 {
            HStack(spacing: 3) {
                Image(systemName: AgentState.working.symbol).font(.system(size: 9, weight: .bold))
                Text("\(store.agents.count(.working))").font(Theme.num(12))
            }
            .foregroundStyle(Theme.aqua)
        } else {
            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.text(0.5))
        }
    }
}

extension Store {
    /// Whether there is anything to say beside the notch. With nothing, the notch form shows nothing at all.
    var notchBusy: Bool {
        !groups.isEmpty || !agentsNeedingYou.isEmpty || agents.count(.working) > 0 || !inbox.questions.isEmpty
    }
}

/// The dock as part of the notch, closed: the notch grown wider by two ears. On a screen without a notch, a
/// small black island at the top edge that says the same in one line.
struct NotchView: View {
    let store: Store
    let notch: NotchMetrics

    var body: some View {
        Group {
            if notch.real {
                if store.notchBusy {
                    NotchEars(store: store, notch: notch)
                } else {
                    // Nothing going on: only the notch itself, which can still be clicked.
                    Color.clear.frame(width: notch.width, height: notch.height)
                }
            } else {
                island
            }
        }
        .background(notchShape(notch.real ? 11 : 13).fill(.black))
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
    }

    /// Without a notch to stand beside: the ring and one line.
    private var island: some View {
        let glance = CapsuleView(store: store)
        let groups = store.groups
        let focus = groups.focusItem
        return HStack(spacing: 7) {
            StatusRing(fraction: glance.ringFraction(focus), count: groups.activeCount, tint: glance.ringTint(groups),
                       idleSymbol: glance.idleSymbol(groups), lineWidth: 2.4)
                .frame(width: 18, height: 18)
            Text(glance.primary(focus, groups))
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: 230, alignment: .leading)
                .fixedSize()
        }
        .fixedSize()
        .padding(.leading, 9).padding(.trailing, 13)
        .frame(height: notch.height)
    }
}

/// The dock as part of the notch, open: the panel hangs from the top edge of the screen. The strip the notch
/// takes is left to it, empty (the panel's own heading says what the ears said), and the content starts below.
struct NotchPanelView: View {
    let store: Store
    let notch: NotchMetrics
    var onCollapse: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if notch.real { Color.clear.frame(width: Layout.panelWidth, height: notch.height) }
            PanelView(store: store, onCollapse: onCollapse, bare: true)
        }
        .frame(width: Layout.panelWidth)
        .clipShape(notchShape(24))
        .background(notchShape(24).fill(.black).shadow(color: .black.opacity(0.5), radius: 14, y: 7))
        .environment(\.colorScheme, .dark)
    }
}

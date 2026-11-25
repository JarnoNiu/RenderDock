import AppKit
import Observation
import SwiftUI
import RenderDockCore

/// A larger look at what a shot has rendered: one frame, large, and a slider through all the frames that are on
/// disk so far. Opened from a shot's thumbnail. It only ever reads the files in the shot's output folder.
@Observable
final class PreviewModel {
    private(set) var title = ""
    private(set) var dir = ""
    private(set) var frames: [TaskScanner.FrameFile] = []
    /// Which of `frames` is on the screen.
    private(set) var index = 0
    /// Stay on the newest frame as more arrive. Looking at an earlier one switches this off.
    var follow = true {
        didSet { if follow, !frames.isEmpty { show(frames.count - 1, byHand: false) } }
    }
    private(set) var image: NSImage?
    /// The file the picture on the screen was read from, and the one being read now.
    private(set) var imagePath = ""
    @ObservationIgnored private var wanted = ""
    @ObservationIgnored private let loading = DispatchQueue(label: "renderdock.preview", qos: .userInitiated)

    var current: TaskScanner.FrameFile? { frames.indices.contains(index) ? frames[index] : nil }

    func open(dir: String, title: String) {
        self.dir = dir
        self.title = title
        frames = []
        index = 0
        image = nil
        imagePath = ""
        follow = true
        reload()
    }

    /// Lists the folder again. The frame being looked at stays the one on the screen, unless the newest is followed.
    func reload() {
        guard !dir.isEmpty else { return }
        let looking = current?.number
        let listed = TaskScanner.frameFiles(in: dir)
        guard listed != frames else { return }
        frames = listed
        if follow || looking == nil {
            show(max(0, listed.count - 1), byHand: false)
        } else {
            // The same frame by its number; if it is gone, the nearest one before it.
            let at = listed.lastIndex { $0.number <= (looking ?? 0) } ?? 0
            show(at, byHand: false)
        }
    }

    func step(_ by: Int) { show(index + by, byHand: true) }

    /// Puts frame `i` on the screen. `byHand`: the user asked for it, which is what stops following the newest.
    func show(_ i: Int, byHand: Bool) {
        guard !frames.isEmpty else { return }
        let target = min(frames.count - 1, max(0, i))
        if byHand, follow, target != frames.count - 1 { follow = false }
        index = target
        let path = frames[target].path
        guard path != imagePath, path != wanted else { return }
        wanted = path
        loading.async { [weak self] in
            // Large enough for a window that fills a screen, without reading a 16-bit frame at full size every time.
            let picture = Store.thumbnail(path, maxPixel: 2400)
            DispatchQueue.main.async {
                guard let self, self.wanted == path else { return }
                self.wanted = ""
                self.image = picture
                self.imagePath = path
            }
        }
    }
}

struct PreviewView: View {
    @Bindable var model: PreviewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text(model.frames.isEmpty ? L("这个输出目录里还没有渲出来的帧", "No rendered frames in this output folder yet") : L("正在读这一帧…", "Reading the frame…"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.step(-1); return .handled }
        .onKeyPress(.rightArrow) { model.step(1); return .handled }
    }

    private var bar: some View {
        let count = model.frames.count
        return HStack(spacing: 10) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(model.index <= 0)
                .help(L("上一帧（←）", "Previous frame (←)"))
            Slider(value: Binding(get: { Double(model.index) }, set: { model.show(Int($0.rounded()), byHand: true) }),
                   in: 0...Double(max(1, count - 1)))
                .disabled(count < 2)
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.index >= count - 1)
                .help(L("下一帧（→）", "Next frame (→)"))
            if let frame = model.current {
                // Which frame by its own number, and where that is among the ones rendered so far.
                Text(L("第 \(frame.number) 帧 · \(model.index + 1)/\(count)", "Frame \(frame.number) · \(model.index + 1)/\(count)"))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                    .frame(minWidth: 132, alignment: .leading)
                    .help((frame.path as NSString).lastPathComponent)
            }
            Toggle(L("跟着最新一帧", "Follow the Newest"), isOn: $model.follow)
                .toggleStyle(.checkbox).font(.system(size: 12))
                .help(L("有新的帧渲出来就跳过去；拖动或翻到前面的帧时自动关掉", "Jumps to each new frame as it is rendered; switched off by going back to an earlier one"))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(red: 0.09, green: 0.10, blue: 0.13))
    }
}

/// The window the larger look lives in. One at a time: opening another shot's frames takes this one over.
final class PreviewController: NSObject, NSWindowDelegate {
    let model = PreviewModel()
    private var window: NSWindow?
    private var timer: Timer?

    func show(dir: String, title: String) {
        model.open(dir: dir, title: title)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.minSize = NSSize(width: 520, height: 360)
            w.contentView = NSHostingView(rootView: PreviewView(model: model).environment(\.colorScheme, .dark))
            w.delegate = self
            w.center()
            window = w
        }
        window?.title = L("\(title) · 已渲的帧", "\(title) · rendered frames")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // New frames keep arriving while the shot renders: look at the folder again every few seconds while the window is open.
        timer?.invalidate()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.model.reload() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    /// For the debug hook: the window as it is drawn, to a PNG.
    func debugShot(_ path: String) {
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

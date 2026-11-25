// Checks for RenderDockCore. Run with `swift run rd-checks`; exits non-zero if anything fails.
// A plain executable rather than an XCTest bundle so it works with the Command Line Tools alone.
import Foundation
import Network
import SQLite3
import RenderDockCore

var total = 0
var failures = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, line: UInt = #line) {
    total += 1
    if !condition() {
        failures += 1
        print("✗ \(name)  (line \(line))")
    }
}

func section(_ name: String) { print("· \(name)") }

// MARK: Frame numbers in file names

section("frame numbers")
check("beauty pass", TaskScanner.frameIndex("beauty_00548.png") == 548)
check("pass with a suffix letter", TaskScanner.frameIndex("beauty_00548b.png") == 548)
check("bare number", TaskScanner.frameIndex("0064.png") == 64)
check("prefix and number", TaskScanner.frameIndex("f_00012.png") == 12)
check("longest run wins over a version digit", TaskScanner.frameIndex("frame_0012_v2.png") == 12)
check("shot digit before frame number", TaskScanner.frameIndex("shot3_0100.exr") == 100)
check("no digits", TaskScanner.frameIndex("notes.png") == nil)

// MARK: Blender frame lists and ranges

section("frame lists")
check("list", TaskScanner.parseFrameList("1,5,9") == [1, 5, 9])
check("range", TaskScanner.parseFrameList("1..250")?.count == 250)
check("mixed", TaskScanner.parseFrameList("1..3,10") == [1, 2, 3, 10])
check("relative start is not resolvable", TaskScanner.parseFrameList("+10") == nil)
check("relative end is not resolvable", TaskScanner.parseFrameList("-1") == nil)
check("garbage", TaskScanner.parseFrameList("abc") == nil)
check("empty", TaskScanner.parseFrameList("") == nil)
check("reversed range", TaskScanner.parseFrameList("9..3") == nil)

section("Blender command lines")
check("-s -e -a", TaskScanner.blenderFrames(["blender", "-b", "a.blend", "-s", "1", "-e", "250", "-a"])?.count == 250)
check("-j", TaskScanner.blenderFrames(["blender", "-b", "a.blend", "-s", "1", "-e", "250", "-j", "2", "-a"])?.count == 125)
check("range without -a renders nothing", TaskScanner.blenderFrames(["blender", "-b", "a.blend", "-s", "1", "-e", "250"]) == nil)
check("-f range", TaskScanner.blenderFrames(["blender", "-b", "a.blend", "-f", "1..10"])?.count == 10)
check("long options with =", TaskScanner.blenderFrames(["blender", "--background", "--frame-start=5", "--frame-end=8", "--render-anim"]) == [5, 6, 7, 8])
check("end before start", TaskScanner.blenderFrames(["blender", "-b", "-s", "9", "-e", "3", "-a"]) == nil)
check("no range given", TaskScanner.blenderFrames(["blender", "-b", "a.blend", "-a"]) == nil)

section("the frame range stored in a .blend")
do {
    // A file put together here in the shape Blender writes: a header, the file's globals, two scenes, and the
    // block in which the file describes its own structs. `large` is the block heading Blender 5 uses.
    func blend(large: Bool, pointer: Int = 8, activeSecond: Bool = false) -> Data {
        func le(_ value: Int, _ size: Int) -> [UInt8] { (0..<size).map { UInt8((UInt64(bitPattern: Int64(value)) >> UInt64(8 * $0)) & 0xFF) } }
        func block(_ code: String, structIndex: Int, address: Int, _ body: [UInt8]) -> [UInt8] {
            let name = Array(code.utf8) + [UInt8](repeating: 0, count: 4 - code.utf8.count)
            if large { return name + le(structIndex, 4) + le(address, 8) + le(body.count, 8) + le(1, 8) + body }
            return name + le(body.count, 4) + le(address, pointer) + le(structIndex, 4) + le(1, 4) + body
        }
        // Types: 0 int, 1 char, 2 ID, 3 RenderData, 4 Scene, 5 FileGlobal, 6 short.
        let nameList = ["*next", "name[66]", "pad", "sfra", "efra", "frame_step", "id", "*camera", "r", "*curscene", "flag"]
        let types = ["int", "char", "ID", "RenderData", "Scene", "FileGlobal", "short"]
        let idSize = pointer + 66 + 2, renderSize = 4 * 4, sceneSize = idSize + pointer + renderSize
        let sizes = [4, 1, idSize, renderSize, sceneSize, 4 + pointer, 2]
        func pad(_ bytes: [UInt8]) -> [UInt8] { bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4) }
        var dna = Array("SDNA".utf8) + Array("NAME".utf8) + le(nameList.count, 4)
        dna += pad(nameList.flatMap { Array($0.utf8) + [0] })
        dna += Array("TYPE".utf8) + le(types.count, 4) + pad(types.flatMap { Array($0.utf8) + [0] })
        dna += Array("TLEN".utf8) + pad(sizes.flatMap { le($0, 2) })
        let structs: [(Int, [(Int, Int)])] = [
            (2, [(2, 0), (1, 1), (6, 2)]),                 // ID: *next, name[66], pad
            (3, [(0, 10), (0, 3), (0, 4), (0, 5)]),        // RenderData: flag, sfra, efra, frame_step
            (4, [(2, 6), (4, 7), (3, 8)]),                 // Scene: id, *camera, r
            (5, [(0, 10), (4, 9)]),                        // FileGlobal: flag, *curscene
        ]
        dna += Array("STRC".utf8) + le(structs.count, 4)
        for (type, fields) in structs { dna += le(type, 2) + le(fields.count, 2) + fields.flatMap { le($0.0, 2) + le($0.1, 2) } }

        func scene(_ name: String, _ start: Int, _ end: Int, _ step: Int) -> [UInt8] {
            let text = Array(("SC" + name).utf8)
            return le(0, pointer) + text + [UInt8](repeating: 0, count: 66 - text.count) + le(0, 2) + le(0, pointer) + le(0, 4) + le(start, 4) + le(end, 4) + le(step, 4)
        }
        var file = large ? Array("BLENDER17-01v0502".utf8) : Array("BLENDER\(pointer == 8 ? "-" : "_")v404".utf8)
        file += block("GLOB", structIndex: 3, address: 16, le(0, 4) + le(activeSecond ? 0x2000 : 0x1000, pointer))
        file += block("SC", structIndex: 2, address: 0x1000, scene("Scene", 101, 180, 2))
        file += block("DATA", structIndex: 0, address: 0x1800, [1, 2, 3, 4, 5, 6, 7, 8])
        file += block("SC", structIndex: 2, address: 0x2000, scene("镜头 B", 10, 40, 1))
        file += block("DNA1", structIndex: 0, address: 0, dna)
        file += block("ENDB", structIndex: 0, address: 0, [])
        return Data(file)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rdb-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ name: String, _ data: Data) -> String {
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url)
        return url.path
    }
    let modern = write("modern.blend", blend(large: true))
    let scenes = BlendFile.scenes(at: modern)
    check("both scenes are found, by the names the file gives them", scenes?.map(\.name) == ["Scene", "镜头 B"])
    check("…each with its own range, and which one is active", scenes?.first?.range == BlendFile.FrameRange(start: 101, end: 180, step: 2)
          && scenes?.first?.active == true && scenes?.last?.active == false && scenes?.last?.range == BlendFile.FrameRange(start: 10, end: 40, step: 1))
    check("the active scene's range is the file's range", BlendFile.frameRange(at: modern) == BlendFile.FrameRange(start: 101, end: 180, step: 2))
    check("a scene can be asked for by name", BlendFile.frameRange(at: modern, scene: "镜头 B")?.end == 40 && BlendFile.frameRange(at: modern, scene: "No such scene") == nil)
    check("whichever scene was in front when the file was saved is the active one",
          BlendFile.frameRange(at: write("second.blend", blend(large: true, activeSecond: true)))?.start == 10)
    check("the layout before Blender 5 reads the same, with 64-bit pointers", BlendFile.frameRange(at: write("older.blend", blend(large: false))) == BlendFile.FrameRange(start: 101, end: 180, step: 2))
    check("…and with 32-bit ones", BlendFile.scenes(at: write("older32.blend", blend(large: false, pointer: 4)))?.map(\.range.end) == [180, 40])
    check("the frames of a range", BlendFile.FrameRange(start: 101, end: 180, step: 2).frames?.count == 40 && BlendFile.FrameRange(start: 9, end: 3, step: 1).frames == nil)
    check("a compressed file is not read", BlendFile.scenes(at: write("zstd.blend", Data([0x28, 0xB5, 0x2F, 0xFD] + [UInt8](repeating: 7, count: 200)))) == nil)
    check("nor a file cut short, a file that is something else, or one that is not there",
          BlendFile.scenes(at: write("cut.blend", blend(large: true).prefix(300))) == nil && BlendFile.scenes(at: write("text.blend", Data("BLENDER is not what this is".utf8))) == nil
          && BlendFile.scenes(at: dir.appendingPathComponent("missing.blend").path) == nil)

    func read(_ file: String, _ scene: String?) -> BlendFile.FrameRange? { BlendFile.frameRange(at: file, scene: scene) }
    check("a command line that leaves the range to the file gets it from there",
          TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-a"], read: read)?.frames.count == 40
          && TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-a"], read: read)?.rough == false)
    check("what the command line does say takes the place of the file's value",
          TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-s", "171", "-a"], read: read)?.frames == [171, 173, 175, 177, 179]
          && TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-j", "40", "-a"], read: read)?.frames == [101, 141])
    check("-S picks the scene", TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-S", "镜头 B", "-a"], read: read)?.frames.count == 31)
    check("with a script on the command line the file's range is only a best guess",
          TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-P", "setup.py", "-a"], read: read)?.rough == true)
    check("no -a, an explicit frame list, or no file: nothing is read",
          TaskScanner.blenderFramesFromFile(["blender", "-b", modern], read: read) == nil && TaskScanner.blenderFramesFromFile(["blender", "-b", modern, "-f", "3"], read: read) == nil
          && TaskScanner.blenderFramesFromFile(["blender", "-b", "-a"], read: read) == nil)

    // Files saved by a real Blender, when a folder of them is at hand (see the comment in Blend.swift).
    if let samples = ProcessInfo.processInfo.environment["RENDERDOCK_BLEND_SAMPLES"], !samples.isEmpty {
        check("a file saved by Blender: the active scene's range", BlendFile.frameRange(at: samples + "/range-101-180-step-2.blend") == BlendFile.FrameRange(start: 101, end: 180, step: 2))
        check("a file saved by Blender: three scenes, the first active",
              BlendFile.scenes(at: samples + "/three-scenes.blend")?.map(\.name) == ["Scene", "Shot B", "镜头三"]
              && BlendFile.frameRange(at: samples + "/three-scenes.blend") == BlendFile.FrameRange(start: 1, end: 250, step: 1)
              && BlendFile.frameRange(at: samples + "/three-scenes.blend", scene: "镜头三") == BlendFile.FrameRange(start: 5, end: 9, step: 1))
        check("a file saved by Blender with another scene in front", BlendFile.frameRange(at: samples + "/second-active.blend") == BlendFile.FrameRange(start: 10, end: 40, step: 1))
        check("a file saved by Blender with compression on is not read", BlendFile.scenes(at: samples + "/compressed.blend") == nil)
    }
    try? FileManager.default.removeItem(at: dir)
}

// MARK: Arguments, queue specs, titles

section("arguments")
check("value after a name", TaskScanner.argValue(["--out", "x"], ["--out"]) == "x")
check("--name=value", TaskScanner.argValue(["--fps=30"], ["--fps"]) == "30")
check("missing", TaskScanner.argValue(["--fps", "30"], ["--out"]) == nil)
check("name without a value", TaskScanner.argValue(["--out"], ["--out"]) == nil)

section("queue specs")
check("scene:shot", TaskScanner.parseSpec("s040-explode:explode").map { "\($0.scene)|\($0.shot)" } == "s040-explode|explode")
check("a time is not a spec", TaskScanner.parseSpec("12:30") == nil)
check("a URL is not a spec", TaskScanner.parseSpec("http://example.com") == nil)
check("three parts", TaskScanner.parseSpec("a:b:c") == nil)
check("empty side", TaskScanner.parseSpec(":b") == nil)
check("name collapses when the shot repeats the scene", TaskScanner.specName(("s040-explode", "explode")) == "s040-explode")
check("name keeps a different shot", TaskScanner.specName(("s050-return", "ret")) == "s050-return · ret")

section("queue rules")
do {
    let standard = QueueRule.standard
    let item = standard.parse("s040-explode:explode")
    check("the standard rule reads scene:shot", item?.fields == ["scene": "s040-explode", "shot": "explode"] && item?.key == "s040-explode-explode")
    check("…names it as before", item.map(standard.title(for:)) == "s040-explode" && standard.parse("s050-return:ret").map(standard.title(for:)) == "s050-return · ret")
    check("…ties a render to it by its --scene and --shot",
          item.map { standard.matches(arguments: ["blender", "-b", "--", "--scene", "s040-explode", "--shot", "explode"], $0) } == true
          && item.map { standard.matches(arguments: ["blender", "-b", "--", "--scene", "s040-explode", "--shot", "wide"], $0) } == false)
    check("…or, without those, by the two names joined in an argument",
          item.map { standard.matches(arguments: ["node", "paste.js", "out/s040-explode-explode/frames"], $0) } == true
          && item.map { standard.matches(arguments: ["node", "paste.js", "out/s050-return-ret/frames"], $0) } == false)
    check("…and with both flags present, the joined name alone is not enough",
          item.map { standard.matches(arguments: ["x", "--scene", "other", "--shot", "explode", "s040-explode-explode"], $0) } == false)
    check("a script's items are its arguments that read as items; options are not", standard.items(in: ["queue.sh", "--fast", "s010:a", "notes.txt", "s020:b"]).map(\.key) == ["s010-a", "s020-b"])

    let folders = QueueRule(script: "render_all.sh", item: "{seq}/{shot}", flags: ["--seq": "{seq}", "--shot": "{shot}"], title: "{seq} / {shot}", doneFile: "{cwd}/out/{seq}_{shot}.mov")
    check("another way of writing items: a rule of your own", folders.parse("ep04/intro")?.fields == ["seq": "ep04", "shot": "intro"] && folders.parse("ep04:intro") == nil && folders.parse("ep04/") == nil)
    check("…with its own name for them", folders.parse("ep04/intro").map(folders.title(for:)) == "ep04 / intro")
    check("…only for the script it names", folders.items(in: ["scripts/render_all.sh", "ep04/intro", "ep04/table"]).count == 2 && folders.items(in: ["other.sh", "ep04/intro"]).isEmpty)
    check("…and the script's own path is not one of its items", QueueRule(script: "all.sh", item: "{shot}").items(in: ["./all.sh", "intro", "table"]).map(\.key) == ["intro", "table"])
    check("a part ends at the first place the text after it appears", QueueRule(item: "{a}-{b}").parse("s040-explode-wide")?.values == ["s040", "explode-wide"])
    check("a template with no parts, or two parts run together, reads nothing", QueueRule(item: "plain").parse("plain") == nil && QueueRule(item: "{a}{b}").parse("ab") == nil)
    check("a time or an address is still not an item", QueueRule(item: "{a}:{b}").parse("12:30") == nil && QueueRule(item: "{a}:{b}").parse("http://example.com") == nil)

    let file = Data("{\"queueDoneFile\":\"{cwd}/out/{scene}-{shot}.mp4\",\"queues\":[{\"script\":\"render_all.sh\",\"item\":\"{seq}/{shot}\",\"contains\":\"{seq}_{shot}\"}]}".utf8)
    let rules = try? JSONDecoder().decode(AdapterRules.self, from: file)
    check("rules from the file come first, then the standard one, which keeps the done-file set for it",
          rules?.queueRules.map(\.item) == ["{seq}/{shot}", "{scene}:{shot}"] && rules?.queueRules.last?.doneFile == "{cwd}/out/{scene}-{shot}.mp4")
    check("with no file there is only the standard rule", AdapterRules().queueRules == [QueueRule.standard])
    check("the standard rule can be switched off", (try? JSONDecoder().decode(AdapterRules.self, from: Data("{\"standardQueue\":false}".utf8)))?.queueRules.isEmpty == true)
}

section("titles from a script's first comment")
check("ASCII colon", TaskScanner.shortTitle("Fake render: a stand-in for a headless Blender job") == "Fake render")
check("full stop, but not inside a version", TaskScanner.shortTitle("Render v2.1 of the hero shots. Uses 64 samples") == "Render v2.1 of the hero shots")
check("dash", TaskScanner.shortTitle("Night queue - runs after 22:00") == "Night queue")
check("full-width bracket", TaskScanner.shortTitle("产品片正式渲染（第 3 版）：两路并行") == "产品片正式渲染")
check("punctuation inside quotes is kept", TaskScanner.shortTitle("重排队列「先暂停：别并行」：一次一路") == "重排队列「先暂停：别并行」")
check("nothing to cut", TaskScanner.shortTitle("Hero shots") == "Hero shots")

// MARK: Events

section("events")
func job(_ id: String, _ state: GroupState, _ shots: [(String, ItemState)]) -> RenderGroup {
    RenderGroup(id: id, title: "Job \(id)", script: "run.sh", scriptPath: "/private/secret/run.sh", note: nil, project: "demo",
                cwd: "/private/secret", startedAt: Date(timeIntervalSince1970: 1_800_000_000), keepAwake: true, state: state,
                items: shots.map { RenderItem(id: "\(id)/\($0.0)", name: $0.0, state: $0.1) })
}
var detector = EventDetector()
check("the first scan announces nothing", detector.update([job("a", .running, [("s1", .rendering)])]).isEmpty)
check("no change, no events", detector.update([job("a", .running, [("s1", .rendering)])]).isEmpty)
var events = detector.update([job("a", .running, [("s1", .done), ("s2", .rendering)]), job("b", .waiting, [])])
check("shot.done and job.started", events.map(\.type) == [.shotDone, .jobStarted] && events[0].shot == "s1" && events[1].jobId == "b")
events = detector.update([job("a", .stalled, [("s1", .done), ("s2", .stalled)]), job("b", .waiting, [])])
check("job.stalled", events.map(\.type) == [.jobStalled])
events = detector.update([job("a", .running, [("s1", .done), ("s2", .rendering)]), job("b", .waiting, [])])
check("job.resumed", events.map(\.type) == [.jobResumed])
events = detector.update([job("a", .paused, [("s1", .done), ("s2", .paused)]), job("b", .waiting, [])])
check("job.paused", events.map(\.type) == [.jobPaused])
events = detector.update([job("b", .waiting, [])])
check("job.ended", events.map(\.type) == [.jobEnded] && events[0].jobId == "a")
check("an event is one line of JSON", !String(decoding: events[0].json(), as: UTF8.self).contains("\n"))

// MARK: State snapshot

section("state snapshot")
var rendering = RenderItem(id: "a/s2", name: "s2", state: .rendering)
rendering.framesDone = 360
rendering.framesTotal = 720
rendering.secPerFrame = 6.25
var estimated = RenderItem(id: "c/x", name: "x", state: .paused)
estimated.framesDone = 100
estimated.framesTotal = 400
estimated.totalIsEstimate = true
var groupA = job("a", .running, [("s1", .done)])
groupA.items.append(rendering)
groupA.items.append(RenderItem(id: "a/s3", name: "s3", state: .pending))
var groupC = job("c", .paused, [])
groupC.items = [estimated]
var machine = Metrics()
machine.cpu = 0.6249
machine.gpu = 0.86
machine.awakeHeld = true
let snapshot = StateSnapshot.make(groups: [groupA, groupC, job("d", .waiting, [])], metrics: machine, host: "test-mac")
let text = String(decoding: snapshot.json(), as: UTF8.self)
check("summary counts", snapshot.summary.rendering == 1 && snapshot.summary.paused == 1 && snapshot.summary.queued == 1 && snapshot.summary.stalled == 0)
check("focus is the running shot", snapshot.summary.focus?.name == "s2" && snapshot.summary.focus?.fraction == 0.5 && snapshot.summary.focus?.exact == true)
check("eta from frames left × seconds per frame", snapshot.summary.focus?.etaSec == 2250)
check("job and shot states use wire names", snapshot.jobs.map(\.state) == ["running", "paused", "queued"] && snapshot.jobs[0].shots.map(\.state) == ["done", "rendering", "pending"])
check("shots done / total", snapshot.jobs[0].shotsDone == 1 && snapshot.jobs[0].shotsTotal == 3)
check("an estimated total is not exact", snapshot.jobs[1].shots[0].exact == false && snapshot.jobs[1].shots[0].fraction == 0.25)
check("an unknown total has no fraction", snapshot.jobs[0].shots[2].fraction == nil && snapshot.jobs[0].shots[2].exact == false)
check("numbers are rounded", snapshot.metrics.cpu == 0.625)
check("single-line JSON", !text.contains("\n"))
check("no file-system paths leave the machine's own UI", !text.contains("/private/secret"))
check("round trip", (try? JSONDecoder().decode(StateSnapshot.self, from: snapshot.json())) == snapshot)
var sampling = RenderItem(id: "s/1", name: "long-frame", state: .rendering)
sampling.framesDone = 3
sampling.framesTotal = 10
sampling.sampleDone = 32
sampling.sampleTotal = 64
check("a half-sampled frame counts as half a frame", sampling.fraction == 0.35)

// MARK: Reading a renderer's output

section("progress from Blender 5.x output")
var p5 = ProgressParser()
for line in [
    "00:00.248  render           | Rendering animation (frames 1..4)",
    "00:00.249  render           | Rendering frame 1",
    "00:00.261  render           | Fra: 1 | Mem: 0M | Synchronizing object | Cube",
    "00:00.403  render           | Fra: 1 | Remaining: 00:00.00 | Mem: 1M | Sample 3/8",
] { p5.feed(line) }
check("total from the animation range", p5.total == 4)
check("current frame and samples", p5.frame == 1 && p5.sampleDone == 3 && p5.sampleTotal == 8)
check("nothing finished yet", p5.done == 0)
p5.feed("00:00.455  render           | Saved: '/tmp/out/shot_0001.png'")
check("a saved file finishes a frame", p5.done == 1 && p5.outDir == "/tmp/out")
check("samples reset with the frame", p5.sampleDone == nil)
p5.feed("00:00.455  render           | Time: 00:00.05 (Saving: 00:00.05)")
check("a timing line changes nothing", p5.done == 1)
p5.feed("00:00.486  render           | Fra: 2 | Rendering 1 / 4 samples")
check("EEVEE sample wording", p5.frame == 2 && p5.sampleDone == 1 && p5.sampleTotal == 4)

section("progress from Blender 4.x output")
var p4 = ProgressParser(totalFromCommandLine: 125)
p4.feed("Fra:12 Mem:120.50M (Peak 130.00M) | Time:00:05.32 | Mem:80.00M, Peak:90.00M | Scene, ViewLayer | Sample 12/128")
check("frame and samples", p4.frame == 12 && p4.sampleDone == 12 && p4.sampleTotal == 128)
p4.feed("Saved: '/out/f_0012.png'")
p4.feed("Saved: '/out/f_0013.png'")
check("frames counted", p4.done == 2)
check("the command line's total is kept (it knows about -j)", p4.total == 125)
var movie = ProgressParser()
movie.feed("Append frame 1")
movie.feed("Append frame 2")
movie.feed("Append frame 2")
check("frames appended to a movie count once each", movie.done == 2)

section("progress: several files per frame, temporary files, explicit lines")
var passes = ProgressParser()
for name in ["beauty_00007.png", "shadow_00007.png", "_mb_tmp.png", "beauty_00007b.png", "beauty_00008.png"] {
    passes.feed("Saved: '/out/\(name)'")
}
check("passes of one frame count once; temporary files do not count", passes.done == 2)
var still = ProgressParser()
still.feed("Saved: '/out/render.png'")
check("an unnumbered still is one frame", still.done == 1)
var explicitLines = ProgressParser()
explicitLines.feed("FRAME 12/720 t=0.40 elapsed 93s")
check("FRAME i/N", explicitLines.done == 12 && explicitLines.total == 720)
explicitLines.feed("Saved: '/out/a_0001.png'")
check("explicit lines win over counting saved files", explicitLines.done == 12)
explicitLines.feed("progress 13/720")
check("PROGRESS i/N, any case", explicitLines.done == 13)
var unrelated = ProgressParser()
check("an unrelated line is not progress", !unrelated.feed("Read blend: /tmp/a.blend") && unrelated.done == 0 && unrelated.total == nil)

section("progress of an ffmpeg encode")
do {
    // Lines as ffmpeg 9 prints them (the status line is rewritten in place, with a carriage return).
    let banner = [
        "ffmpeg version 9.0.1 Copyright (c) 2000-2026 the FFmpeg developers",
        "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'input.mp4':",
        "  Duration: 00:00:40.00, start: 0.000000, bitrate: 15578 kb/s",
        "Stream mapping:",
        "Output #0, mp4, to 'out.mp4':",
    ]
    var p = ProgressParser(ffmpegArguments: ["ffmpeg", "-y", "-i", "input.mp4", "-c:v", "libx264", "out.mp4"])
    for line in banner { p.feed(line) }
    check("nothing is known before the first status line", p.mediaDone == nil && p.mediaTotal == nil)
    check("a status line gives the place in the output, its length and the speed",
          p.feed("frame=   28 fps= 28 q=24.0 size=     768KiB time=00:00:05.15 bitrate=1220.6kbits/s speed=5.12x elapsed=0:00:01.00    ")
          && p.mediaDone == 5.15 && p.mediaTotal == 40 && p.mediaSpeed == 5.12 && !p.mediaTotalIsRough)
    check("the last line reaches the end", p.feed("frame= 1200 fps= 43 q=-1.0 Lsize=   42996KiB time=00:00:40.00 bitrate=8805.6kbits/s speed=1.44x elapsed=0:00:27.77    ") && p.mediaDone == 40)
    check("an encode has no frames", p.done == 0 && p.total == nil)

    var audio = ProgressParser(ffmpegArguments: ["ffmpeg", "-i", "input.mp4", "-vn", "a.mp3"])
    for line in banner { audio.feed(line) }
    check("sound alone has a status line without frames", audio.feed("size=     313KiB time=00:00:20.00 bitrate=  64.1kbits/s speed= 266x elapsed=0:00:00.15") && audio.mediaDone == 20 && audio.mediaSpeed == 266)

    var machine = ProgressParser(ffmpegArguments: ["ffmpeg", "-nostats", "-progress", "pipe:1", "-t", "3", "-i", "input.mp4", "p.mp4"])
    for line in ["  Duration: 00:00:40.00, start: 0.000000, bitrate: 15578 kb/s", "frame=45", "out_time_us=1500000", "out_time_ms=1500000", "out_time=00:00:01.500000", "speed=11.6x", "progress=continue"] { machine.feed(line) }
    check("what -progress prints is read too, and -t is the length", machine.mediaDone == 1.5 && machine.mediaTotal == 3 && !machine.mediaTotalIsRough)
    check("…and its last word finishes it", machine.feed("progress=end") && machine.mediaDone == 3)

    var quiet = ProgressParser(ffmpegArguments: ["ffmpeg", "-loglevel", "error", "-stats", "-i", "input.mp4", "out.mp4"])
    check("with the inputs' lengths not printed, the place is known and the length is not",
          quiet.feed("frame=   28 fps= 28 q=24.0 size=     768KiB time=00:00:05.15 bitrate=1220.6kbits/s speed=5.12x") && quiet.mediaDone == 5.15 && quiet.mediaTotal == nil)

    var two = ProgressParser(ffmpegArguments: ["ffmpeg", "-i", "video.mp4", "-i", "music.m4a", "out.mp4"])
    for line in ["  Duration: 00:00:40.00, start: 0.000000, bitrate: 15578 kb/s", "  Duration: 00:03:10.00, start: 0.000000, bitrate: 128 kb/s"] { two.feed(line) }
    two.feed("frame=   28 fps= 28 q=24.0 size=     768KiB time=00:00:05.15 bitrate=1220.6kbits/s speed=5.12x")
    check("inputs of different lengths: the longest, marked as a best guess", two.mediaTotal == 190 && two.mediaTotalIsRough)
    check("…and when the output runs past it, the guess is dropped for good",
          two.feed("frame= 9000 fps= 28 q=24.0 size=   90768KiB time=00:03:30.00 bitrate=1220.6kbits/s speed=5.12x") && two.mediaTotal == nil
          && { two.feed("frame= 9100 fps= 28 q=24.0 size=   91768KiB time=00:03:31.00 bitrate=1220.6kbits/s speed=5.12x"); return two.mediaTotal == nil }())

    var joined = ProgressParser(ffmpegArguments: ["ffmpeg", "-i", "a.mp4", "-i", "b.mp4", "-filter_complex", "[0:v][1:v]concat=n=2:v=1[v]", "-map", "[v]", "out.mp4"])
    for line in ["  Duration: 00:00:40.00, start: 0.000000, bitrate: 1 kb/s", "  Duration: 00:00:20.00, start: 0.000000, bitrate: 1 kb/s"] { joined.feed(line) }
    joined.feed("frame=   28 fps= 28 q=24.0 size=     768KiB time=00:00:05.00 bitrate=1220.6kbits/s speed=5.12x")
    check("inputs joined end to end add up, as a best guess", joined.mediaTotal == 60 && joined.mediaTotalIsRough)

    check("what a command line says about the output's length",
          ProgressParser.encodePlan(["ffmpeg", "-i", "a.mp4", "-t", "0:01:30", "out.mp4"]) == ProgressParser.EncodePlan(limit: 90, rough: false, joined: false)
          && ProgressParser.encodePlan(["ffmpeg", "-ss", "10", "-i", "a.mp4", "out.mp4"]).rough
          && ProgressParser.encodePlan(["ffmpeg", "-i", "a.mp4", "-vf", "setpts=0.5*PTS", "out.mp4"]).rough
          && !ProgressParser.encodePlan(["ffmpeg", "-i", "a.mp4", "-vf", "scale=1280:-2", "out.mp4"]).rough)
    check("times as ffmpeg takes them", ProgressParser.mediaTime("90") == 90 && ProgressParser.mediaTime("1:30") == 90 && ProgressParser.mediaTime("0:01:30.5") == 90.5
          && ProgressParser.mediaTime("1500ms") == 1.5 && ProgressParser.mediaTime("soon") == nil)
    var cut = ProgressParser(ffmpegArguments: ["ffmpeg", "-ss", "5", "-i", "input.mp4", "-t", "10", "out.mp4"])
    cut.feed("  Duration: 00:00:40.00, start: 0.000000, bitrate: 15578 kb/s")
    cut.feed("frame=   28 fps= 28 q=24.0 size=     768KiB time=00:00:05.15 bitrate=1220.6kbits/s speed=5.12x")
    check("a -t shorter than the input is the exact length, whatever else is on the line", cut.mediaTotal == 10 && !cut.mediaTotalIsRough)

    var blender = ProgressParser()
    check("a render's lines are not taken for an encode", !blender.feed("Fra:12 Mem:1.2G (Peak 2G) | Time:00:10.21 | Remaining:00:05.00 | Rendering 8/64 samples") || blender.mediaDone == nil)

    var report = JobReport(pid: 1, startedAt: 0, source: "wrapper")
    report.absorb(p, now: 10)
    check("the report carries it", report.mediaDone == 40 && report.mediaTotal == 40 && report.mediaRough == false && report.mediaSpeed == 1.44)
    var item = RenderItem(id: "x", name: "encode", state: .encoding)
    item.mediaDone = 10
    item.mediaTotal = 40
    item.mediaSpeed = 2
    check("an encode's fraction and time left come from its place in the output and its speed", item.fraction == 0.25 && item.eta == 15)
    check("a place in a clip is written the way a player writes it", Fmt.media(5.9) == "0:05" && Fmt.media(750) == "12:30" && Fmt.media(3723) == "1:02:03")
}

section("job reports")
var jobReport = JobReport(pid: 4242, startedAt: 1_800_000_000, source: "wrapper", name: "hero")
var feed = ProgressParser(totalFromCommandLine: 10)
for (i, t) in [10.0, 16.0, 22.5, 28.5].enumerated() {
    feed.feed("Saved: '/out/f_000\(i + 1).png'")
    jobReport.absorb(feed, now: 1_800_000_000 + t)
}
check("done, total and output folder are carried over", jobReport.done == 4 && jobReport.total == 10 && jobReport.outDir == "/out")
check("one timestamp per finished frame", jobReport.recent.count == 4)
check("seconds per frame is the median gap", jobReport.secPerFrame == 6.0)
check("round trip through JSON", (try? JSONDecoder().decode(JobReport.self, from: JSONEncoder().encode(jobReport))) == jobReport)

section("how a job ended")
var ending = EventDetector()
_ = ending.update([job("w", .running, [("s1", .rendering)]), job("x", .running, [("s1", .rendering)]), job("y", .running, [("s1", .rendering)])])
events = ending.update([job("y", .running, [("s1", .rendering)])], outcomes: ["w": JobOutcome(exitCode: 0), "x": JobOutcome(exitCode: 139)])
check("finished and failed are told apart when the wrapper recorded it",
      events.map(\.outcome) == ["finished", "failed"] && events[1].exitCode == 139)
events = ending.update([])
check("no record, no claim; and the queue is announced empty", events.map(\.type) == [.jobEnded, .allEnded] && events[0].outcome == nil)
check("an empty queue staying empty is not news", ending.update([]).isEmpty)

// MARK: History

section("history")
let historyFile = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-history-\(ProcessInfo.processInfo.processIdentifier).sqlite")
try? FileManager.default.removeItem(at: historyFile)
func queueShot(_ name: String, _ state: ItemState, done: Int? = nil, total: Int? = nil, spf: Double? = nil) -> RenderItem {
    var item = RenderItem(id: "q1/stream/\(name)", name: name, state: state)
    item.framesDone = done
    item.framesTotal = total
    item.secPerFrame = spf
    item.pid = state.isActive ? 100 : nil
    return item
}
func queue(_ shots: [RenderItem], state: GroupState = .running) -> RenderGroup {
    RenderGroup(id: "q1", title: "Queue", script: "queue.sh", scriptPath: "/private/secret/queue.sh", note: nil, project: "proj",
                cwd: "/private/secret", startedAt: Date(timeIntervalSince1970: 1_800_000_000), keepAwake: true, state: state, items: shots)
}
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
if let store = HistoryStore(file: historyFile) {
    // shot a renders for 600 s, then the queue moves on to b
    store.record([queue([queueShot("a", .rendering, done: 0, total: 100), queueShot("b", .pending), queueShot("c", .pending)])], now: t0)
    store.record([queue([queueShot("a", .rendering, done: 50, total: 100, spf: 6), queueShot("b", .pending), queueShot("c", .pending)])], now: t0.addingTimeInterval(300))
    check("nothing has ended yet", store.recent().isEmpty)
    check("a shot that never ran has no expected duration", store.expectedDuration(project: "proj", shot: "a") == nil)
    let midQueue = queue([queueShot("a", .rendering, done: 50, total: 100, spf: 6), queueShot("b", .pending), queueShot("c", .pending)])
    let early = store.queueETA(for: midQueue, now: t0.addingTimeInterval(300))
    check("with nothing finished, the shot in progress stands in for the rest", early?.seconds == 300 + 600 + 600 && early?.guessed == 2 && early?.known == 1)
    store.record([queue([queueShot("a", .done), queueShot("b", .rendering, done: 10, total: 100, spf: 6), queueShot("c", .pending)])], now: t0.addingTimeInterval(600))
    let recent = store.recent()
    check("the finished shot is remembered with its duration", recent.count == 1 && recent[0].shot == "a" && recent[0].duration == 600 && recent[0].outcome == "done")
    check("a completed shot with an exact total rendered all of it, even if the last frames fell between scans", recent[0].framesDone == 100 && recent[0].framesTotal == 100 && recent[0].exact)
    check("it now has an expected duration", store.expectedDuration(project: "proj", shot: "a") == 600)
    let later = store.queueETA(for: queue([queueShot("a", .done), queueShot("b", .rendering, done: 10, total: 100, spf: 6), queueShot("c", .pending)]),
                               now: t0.addingTimeInterval(660))
    check("b by its own time left, c by the queue's average so far", later?.seconds == 540 + 600 && later?.known == 1 && later?.guessed == 1)
    check("no estimate for a queue that is not running",
          store.queueETA(for: queue([queueShot("a", .done), queueShot("b", .paused), queueShot("c", .pending)], state: .paused)) == nil)
    check("no queue estimate for a single job", store.queueETA(for: job("solo", .running, [("s1", .rendering)])) == nil)
    // the whole job disappears: the wrapper said it failed
    store.record([], outcomes: ["q1": JobOutcome(exitCode: 3)], now: t0.addingTimeInterval(900))
    let ended = store.recent()
    check("a vanished shot takes the job's recorded outcome", ended.first?.shot == "b" && ended.first?.outcome == "failed" && ended.first?.exitCode == 3)
    check("a failed run does not set expectations", store.expectedDuration(project: "proj", shot: "b") == nil)
    check("history carries no paths", !String(decoding: (try? JSONEncoder().encode(ended)) ?? Data(), as: UTF8.self).contains("/private/secret"))
} else {
    check("the history file opens", false)
}
// a second launch: a shot left open by the first one, and gone meanwhile, is closed at its last sighting
if let first = HistoryStore(file: historyFile) {
    first.record([job("left-open", .running, [("s1", .rendering)])], now: t0.addingTimeInterval(1000))
}
if let second = HistoryStore(file: historyFile) {
    second.record([], now: t0.addingTimeInterval(9000))
    let closed = second.recent().first { $0.jobId == "left-open" }
    check("a shot that ended while RenderDock was closed ends at its last sighting, not now", closed?.endedAt == t0.addingTimeInterval(1000).timeIntervalSince1970 && closed?.outcome == "ended")
    second.prune(olderThanDays: 1, now: t0.addingTimeInterval(10 * 86_400))
    check("old history can be pruned", second.recent().isEmpty)
}
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: historyFile.path + suffix) }

// two parallel streams of one queue: the longer one decides
section("history: parallel streams")
let parallelFile = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-parallel-\(ProcessInfo.processInfo.processIdentifier).sqlite")
try? FileManager.default.removeItem(at: parallelFile)
if let store = HistoryStore(file: parallelFile) {
    func shot(_ stream: String, _ name: String, _ state: ItemState, eta: (done: Int, total: Int, spf: Double)? = nil) -> RenderItem {
        var item = RenderItem(id: "q2/\(stream)/\(name)", name: name, state: state)
        if let eta { item.framesDone = eta.done; item.framesTotal = eta.total; item.secPerFrame = eta.spf }
        return item
    }
    let g = RenderGroup(id: "q2", title: "Two streams", script: nil, scriptPath: nil, note: nil, project: "proj", cwd: "/", startedAt: t0,
                        keepAwake: false, state: .running,
                        items: [shot("A", "a1", .rendering, eta: (50, 100, 10)), shot("A", "a2", .pending),
                                shot("B", "b1", .rendering, eta: (90, 100, 10))])
    store.record([g], now: t0)
    let eta = store.queueETA(for: g, now: t0.addingTimeInterval(500))
    check("streams are summed separately and the longest counts", eta?.seconds == 500 + 1000)
}
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: parallelFile.path + suffix) }
// what the estimates said, against what happened
section("controls: stopping and letting go, on a process of our own")
do {
    // A stand-in that does nothing. No other process is touched by these checks.
    let standIn = Process()
    standIn.executableURL = URL(fileURLWithPath: "/bin/sleep")
    standIn.arguments = ["600"]
    try? standIn.run()
    let pid = standIn.processIdentifier
    Thread.sleep(forTimeInterval: 0.2)
    if let ref = ProcessControl.ref(for: pid) {
        check("a process is named by its number and its start", ref.pid == pid && abs(ref.startedAt - Date().timeIntervalSince1970) < 30 && ProcessControl.problem(with: ref) == nil)
        check("the same number with another start is not the same process: nothing is done to it",
              ProcessControl.pause(ProcessRef(pid: pid, startedAt: ref.startedAt - 3600)) == .notTheSame && ProcessControl.isStopped(pid) == false)
        // A process of another user's, found by asking whether a signal could be sent to it (signal 0 sends none).
        let foreign = (Int32(2)...Int32(3000)).first { errno = 0; return kill($0, 0) == -1 && errno == EPERM }
        check("a process of another user's is refused before anything is tried",
              foreign != nil && foreign.map { ProcessControl.pause(ProcessRef(pid: $0, startedAt: 0)) } == .notOurs
              && foreign.map { ProcessControl.setYielding(ProcessRef(pid: $0, startedAt: 0), true) } == .notOurs && foreign.flatMap(ProcessControl.ref(for:)) == nil)
        check("the first process, and no process at all, are refused", ProcessControl.pause(ProcessRef(pid: 1, startedAt: 0)) == .gone
              && ProcessControl.resume(ProcessRef(pid: 0, startedAt: 0)) == .gone && ProcessControl.pause(ProcessRef(pid: -1, startedAt: 0)) == .gone)
        check("paused: it is stopped where it is", ProcessControl.pause(ref) == nil && { Thread.sleep(forTimeInterval: 0.15); return ProcessControl.isStopped(pid) == true }())
        check("let go: it runs again", ProcessControl.resume(ref) == nil && { Thread.sleep(forTimeInterval: 0.15); return ProcessControl.isStopped(pid) == false }())
        let before = ProcessControl.schedulingPriority(pid) ?? -1
        check("moved out of the way: the scheduler has it in the background band",
              ProcessControl.setYielding(ref, true) == nil && { Thread.sleep(forTimeInterval: 0.4); return (ProcessControl.schedulingPriority(pid) ?? 99) <= 6 }())
        check("and back: it is where it was, or higher", ProcessControl.setYielding(ref, false) == nil
              && { Thread.sleep(forTimeInterval: 0.4); return (ProcessControl.schedulingPriority(pid) ?? -1) >= max(before, 10) }())
        standIn.terminate()
        standIn.waitUntilExit()
        check("once it has ended there is nothing to act on", ProcessControl.pause(ref) == .gone && ProcessControl.setYielding(ref, true) == .gone)
    } else {
        check("the stand-in process could be started", false)
        standIn.terminate()
    }
}

section("controls: what the rules ask for")
do {
    func job(_ id: String, at start: Double, active: Bool = true, pids: [Int32] = [1000]) -> ControlJob {
        ControlJob(id: id, title: id.uppercased(), startedAt: start, active: active, processes: pids.map { ProcessRef(pid: $0, startedAt: 1) })
    }
    func held(_ reasons: Set<HoldReason>) -> Hold { Hold(reasons: reasons, processes: [ProcessRef(pid: 1000, startedAt: 1)], since: 0) }
    let a = job("a", at: 100), b = job("b", at: 200), c = job("c", at: 300)
    func wanted(_ jobs: [ControlJob], held: [String: Hold] = [:], freed: Set<String> = [], _ settings: ControlSettings, battery: Bool = false, hot: Bool = false) -> [String: Set<HoldReason>] {
        ControlPlanner.wanted(jobs: jobs, held: held, freed: freed, settings: settings, onBattery: battery, hot: hot).filter { !$0.value.isEmpty }
    }
    check("every switch off: nothing is asked for, on battery and hot or not", wanted([a, b, c], ControlSettings(), battery: true, hot: true).isEmpty)
    check("on battery with that rule on: every job at work is held for it", wanted([a, b], ControlSettings(pauseOnBattery: true), battery: true) == ["a": [.battery], "b": [.battery]])
    check("on mains, or with only the other rule on: not", wanted([a, b], ControlSettings(pauseOnBattery: true), battery: false).isEmpty
          && wanted([a, b], ControlSettings(pauseWhenHot: true), battery: true).isEmpty)
    check("hot with that rule on: held for heat; both at once: for both", wanted([a], ControlSettings(pauseWhenHot: true), hot: true) == ["a": [.heat]]
          && wanted([a], ControlSettings(pauseOnBattery: true, pauseWhenHot: true), battery: true, hot: true) == ["a": [.battery, .heat]])
    check("one at a time: the oldest goes on, the others wait", wanted([c, a, b], ControlSettings(turns: true)) == ["b": [.turns], "c": [.turns]])
    check("…and the next oldest goes on once the first is gone", wanted([c, b], held: ["b": held([.turns]), "c": held([.turns])], ControlSettings(turns: true)) == ["c": [.turns]])
    check("a job waiting its turn stays in the queue though it is not at work", wanted([a, job("b", at: 200, active: false)], held: ["b": held([.turns])], ControlSettings(turns: true)) == ["b": [.turns]])
    check("a job held by hand is not waited for: the next one goes on",
          wanted([job("a", at: 100, active: false), b, c], held: ["a": held([.manual])], ControlSettings(manual: true, turns: true)) == ["c": [.turns]])
    check("a job the user let go on by hand is held by no rule", wanted([a, b], freed: ["b"], ControlSettings(turns: true, pauseOnBattery: true), battery: true) == ["a": [.battery]])
    check("a job stopped by somebody else (not at work, not held here) is nobody's to hold or let go",
          wanted([job("a", at: 100, active: false), b], ControlSettings(turns: true, pauseOnBattery: true), battery: true) == ["b": [.battery]])
    check("a job with no process of its own is left out", wanted([job("a", at: 100, pids: []), b], ControlSettings(turns: true)).isEmpty)
}

section("controls: doing it, undoing it, and remembering")
do {
    // A made-up world: jobs, and which of their processes are stopped. The engine reaches it through the same
    // three calls it uses on real processes.
    final class World {
        var jobs: [(id: String, start: Double, pids: [Int32])] = []
        var stopped = Set<Int32>()
        var background = Set<Int32>()
        var calls: [String] = []
        var refuse = Set<Int32>()
        func ref(_ pid: Int32) -> ProcessRef { ProcessRef(pid: pid, startedAt: 1) }
        var view: [ControlJob] {
            jobs.map { j in ControlJob(id: j.id, title: "Job \(j.id.uppercased())", startedAt: j.start, active: !j.pids.allSatisfy(stopped.contains), processes: j.pids.map(ref)) }
        }
        func job(_ id: String) -> ControlJob { view.first { $0.id == id }! }
        var actuator: ControlEngine.Actuator {
            ControlEngine.Actuator(
                pause: { [unowned self] p in
                    if self.refuse.contains(p.pid) { return .refused(1) }
                    self.calls.append("pause \(p.pid)"); self.stopped.insert(p.pid); return nil
                },
                resume: { [unowned self] p in self.calls.append("resume \(p.pid)"); self.stopped.remove(p.pid); return nil },
                yield: { [unowned self] p, on in
                    self.calls.append("\(on ? "yield" : "unyield") \(p.pid)")
                    if on { self.background.insert(p.pid) } else { self.background.remove(p.pid) }
                    return nil
                })
        }
    }
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    let quiet = World()
    quiet.jobs = [("a", 100, [11]), ("b", 200, [21, 22])]
    let off = ControlEngine(actuator: quiet.actuator)
    off.tick(jobs: quiet.view, onBattery: true, hot: true, now: at(0))
    check("every switch off: nothing is ever done, and nothing by hand either",
          quiet.calls.isEmpty && !off.pause(quiet.job("a")) && !off.resume(quiet.job("a")) && !off.setYielding(quiet.job("a"), true) && quiet.calls.isEmpty && off.isIdle)

    // On battery.
    let w = World()
    w.jobs = [("a", 100, [11]), ("b", 200, [21, 22])]
    var lines: [String] = []
    let engine = ControlEngine(settings: ControlSettings(pauseOnBattery: true), actuator: w.actuator, log: { lines.append($0) })
    engine.tick(jobs: w.view, onBattery: false, hot: false, now: at(0))
    check("on mains: nothing", w.calls.isEmpty)
    engine.tick(jobs: w.view, onBattery: true, hot: false, now: at(2))
    check("the Mac goes onto its battery: every render process is stopped, once", w.calls == ["pause 11", "pause 21", "pause 22"] && w.stopped == [11, 21, 22])
    check("each job says why it is held", engine.reasons(for: "a") == [.battery] && engine.reasons(for: "b") == [.battery] && engine.reasons(for: "z").isEmpty)
    engine.tick(jobs: w.view, onBattery: true, hot: false, now: at(4))
    check("looking again changes nothing", w.calls.count == 3)
    engine.tick(jobs: w.view, onBattery: false, hot: false, now: at(6))
    check("back on mains: they go on, and nothing is held", Array(w.calls.suffix(3)).sorted() == ["resume 11", "resume 21", "resume 22"] && w.stopped.isEmpty && engine.isIdle)
    check("what was done is written down, with the job's name and the reason",
          lines.contains("paused \"Job A\" (1 process): the Mac is on its battery") && lines.contains("paused \"Job B\" (2 processes): the Mac is on its battery")
          && lines.contains("let \"Job A\" go on: the Mac is on mains again"))

    // By hand, and how it sits with a rule.
    engine.settings.manual = true
    check("paused by hand", engine.pause(w.job("a"), now: at(10)) && w.stopped == [11] && engine.reasons(for: "a") == [.manual])
    engine.tick(jobs: w.view, onBattery: true, hot: false, now: at(12))
    check("a rule adds its reason to a job held by hand without stopping it twice", engine.reasons(for: "a") == [.manual, .battery] && w.calls.filter { $0 == "pause 11" }.count == 2)
    engine.tick(jobs: w.view, onBattery: false, hot: false, now: at(14))
    check("the rule's reason goes; what was paused by hand stays paused", engine.reasons(for: "a") == [.manual] && w.stopped == [11])
    check("let go by hand", engine.resume(w.job("a")) && w.stopped.isEmpty && engine.reasons(for: "a").isEmpty)
    engine.tick(jobs: w.view, onBattery: true, hot: false, now: at(16))
    check("a job let go by hand is not held again by the rule; the other one is", !w.stopped.contains(11) && w.stopped == [21, 22])
    engine.settings.pauseOnBattery = false
    engine.tick(jobs: w.view, onBattery: true, hot: false, now: at(18))
    check("a rule switched off lets go of what it held", w.stopped.isEmpty && engine.isIdle)
    check("pausing by hand, then the switch for it going off: the job goes on", {
        _ = engine.pause(w.job("b"), now: at(20))
        engine.settings.manual = false
        engine.tick(jobs: w.view, onBattery: false, hot: false, now: at(22))
        return w.stopped.isEmpty && engine.isIdle
    }())

    // Heat: slow to let go.
    let h = World()
    h.jobs = [("a", 100, [11])]
    let heat = ControlEngine(settings: ControlSettings(pauseWhenHot: true), actuator: h.actuator)
    heat.tick(jobs: h.view, onBattery: false, hot: true, now: at(0))
    heat.tick(jobs: h.view, onBattery: false, hot: false, now: at(10))
    heat.tick(jobs: h.view, onBattery: false, hot: false, now: at(60))
    check("slowed down for heat: stopped, and still stopped a minute short of cool", h.stopped == [11] && heat.reasons(for: "a") == [.heat])
    heat.tick(jobs: h.view, onBattery: false, hot: true, now: at(65))
    heat.tick(jobs: h.view, onBattery: false, hot: false, now: at(70))
    heat.tick(jobs: h.view, onBattery: false, hot: false, now: at(125))
    check("hot again in between starts the minute afresh", h.stopped == [11])
    heat.tick(jobs: h.view, onBattery: false, hot: false, now: at(131))
    check("cool for a whole minute: it goes on", h.stopped.isEmpty && heat.isIdle)

    // One at a time.
    let q = World()
    q.jobs = [("b", 200, [21]), ("a", 100, [11]), ("c", 300, [31])]
    let turns = ControlEngine(settings: ControlSettings(turns: true), actuator: q.actuator)
    turns.tick(jobs: q.view, onBattery: false, hot: false, now: at(0))
    check("one at a time: the oldest goes on, the others are stopped", q.stopped == [21, 31] && turns.reasons(for: "b") == [.turns] && turns.reasons(for: "a").isEmpty)
    q.jobs.removeAll { $0.id == "a" }
    turns.tick(jobs: q.view, onBattery: false, hot: false, now: at(10))
    check("the first one ends: the next oldest goes on, the last still waits", q.stopped == [31] && turns.reasons(for: "b").isEmpty && turns.reasons(for: "c") == [.turns])
    q.jobs.append(("d", 50, [41]))   // a job that turns up later, though it began before the others
    turns.tick(jobs: q.view, onBattery: false, hot: false, now: at(12))
    check("order is by when each began, whenever it was first seen", q.stopped == [21, 31])
    q.jobs = q.jobs.map { $0.id == "c" ? ("c", 300, [31, 32]) : $0 }   // the waiting job's script starts another process
    q.stopped.remove(32)
    turns.tick(jobs: q.view, onBattery: false, hot: false, now: at(14))
    check("a waiting job that starts another process has that one stopped too", q.stopped == [21, 31, 32])
    turns.releaseEverything(why: "RenderDock is quitting")
    check("quitting lets go of everything it stopped", q.stopped.isEmpty && turns.isIdle)

    // Out of the way.
    let y = World()
    y.jobs = [("a", 100, [11, 12])]
    let yielding = ControlEngine(settings: ControlSettings(yield: true), actuator: y.actuator)
    check("moved out of the way by hand, and back", yielding.setYielding(y.job("a"), true) && y.background == [11, 12] && yielding.isYielding("a")
          && !yielding.setYielding(y.job("a"), true) && yielding.setYielding(y.job("a"), false) && y.background.isEmpty && !yielding.isYielding("a"))
    _ = yielding.setYielding(y.job("a"), true)
    yielding.settings.yield = false
    yielding.tick(jobs: y.view, onBattery: false, hot: false, now: at(0))
    check("the switch going off moves it back", y.background.isEmpty && yielding.isIdle)

    // A process that will not be stopped.
    let r = World()
    r.jobs = [("a", 100, [11, 12])]
    r.refuse = [12]
    var said: [String] = []
    let partial = ControlEngine(settings: ControlSettings(pauseOnBattery: true), actuator: r.actuator, log: { said.append($0) })
    partial.tick(jobs: r.view, onBattery: true, hot: false, now: at(0))
    check("a process the system will not stop is said so, and is not counted as stopped by RenderDock",
          r.stopped == [11] && partial.held["a"]?.processes.map(\.pid) == [11] && said.contains { $0.hasPrefix("could not pause a process of \"Job A\"") })

    // Across a restart.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-controls-\(ProcessInfo.processInfo.processIdentifier).json")
    try? FileManager.default.removeItem(at: file)
    let p = World()
    p.jobs = [("a", 100, [11])]
    let first = ControlEngine(settings: ControlSettings(pauseOnBattery: true), actuator: p.actuator, stateFile: file)
    first.tick(jobs: p.view, onBattery: true, hot: false, now: at(0))
    check("what is held is written to a file", p.stopped == [11] && FileManager.default.fileExists(atPath: file.path))
    let second = ControlEngine(settings: ControlSettings(pauseOnBattery: true), actuator: p.actuator, stateFile: file)
    check("a new start knows what the last one held", second.reasons(for: "a") == [.battery])
    second.tick(jobs: p.view, onBattery: true, hot: false, now: at(5))
    check("…and does not stop it a second time", p.calls.filter { $0 == "pause 11" }.count == 1)
    let third = ControlEngine(settings: ControlSettings(), actuator: p.actuator, stateFile: file)
    third.tick(jobs: p.view, onBattery: true, hot: false, now: at(10))
    check("started with every switch off, it lets go of what an earlier start held, and the file goes", p.stopped.isEmpty && !FileManager.default.fileExists(atPath: file.path))
    try? FileManager.default.removeItem(at: file)
}

section("the frames in an output folder, for looking back through them")
do {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-frames-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, bytes: Int) { FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(repeating: 1, count: bytes)) }
    write("shot_0010.png", bytes: 400)
    write("shot_0002.png", bytes: 400)
    write("shot_0001.png", bytes: 400)
    write("shot_shadow_0002.png", bytes: 9000)      // a pass beside the picture, larger than it
    write("shot_0003.exr", bytes: 300)
    write("shot_0003.png", bytes: 500)              // two pictures of one frame: the larger
    write("_tmp_0004.png", bytes: 400)              // still being written
    write(".hidden_0005.png", bytes: 400)
    write("notes_0006.txt", bytes: 400)             // not a picture
    write("preview.png", bytes: 400)                // no number
    write("mask_0007.png", bytes: 200)              // a mask with nothing else for that frame is still its frame
    let frames = TaskScanner.frameFiles(in: folder.path)
    func name(_ n: Int) -> String? { frames.first { $0.number == n }.map { ($0.path as NSString).lastPathComponent } }
    check("one file for each frame, in the order of the numbers", frames.map(\.number) == [1, 2, 3, 7, 10])
    check("the picture, not the shadow pass beside it, however large", name(2) == "shot_0002.png")
    check("of two pictures of one frame, the larger", name(3) == "shot_0003.png")
    check("a mask that is all there is of a frame still stands for it", name(7) == "mask_0007.png")
    check("what is half-written, hidden, not a picture or not numbered is left out",
          !frames.contains { $0.path.contains("_tmp_") || $0.path.contains(".hidden") || $0.path.hasSuffix(".txt") || $0.path.hasSuffix("preview.png") })
    check("a folder that is not there has no frames", TaskScanner.frameFiles(in: folder.appendingPathComponent("nowhere").path).isEmpty)
    try? FileManager.default.removeItem(at: folder)
}

section("fans and power: what the controller's bytes say")
do {
    func float(_ value: Float) -> [UInt8] { withUnsafeBytes(of: value) { Array($0) } }
    check("a float is read as the processor keeps it", SMCReader.decode(type: "flt ", bytes: float(5353)) == 5353 && SMCReader.decode(type: "flt ", bytes: float(142.5)) == 142.5)
    check("the older fixed-point kinds are read high byte first", SMCReader.decode(type: "fpe2", bytes: [0x53, 0xA4]) == 5353
          && SMCReader.decode(type: "sp78", bytes: [0x47, 0x80]) == 71.5 && SMCReader.decode(type: "sp78", bytes: [0xFF, 0x00]) == -1)
    check("whole numbers of one, two and four bytes", SMCReader.decode(type: "ui8 ", bytes: [2]) == 2 && SMCReader.decode(type: "ui16", bytes: [0x5C, 0x2C]) == 23596
          && SMCReader.decode(type: "ui32", bytes: [0, 0, 1, 0]) == 256)
    check("a kind that is not read here, or too few bytes, is nothing rather than nought",
          SMCReader.decode(type: "si16", bytes: [0xFB, 0x02]) == nil && SMCReader.decode(type: "flt ", bytes: [1, 2]) == nil
          && SMCReader.decode(type: "ui8 ", bytes: []) == nil && SMCReader.decode(type: "flt ", bytes: float(.nan)) == nil)
    check("a key is its four letters, both ways", SMCReader.code("PSTR") == 0x50535452 && SMCReader.text(0x46304163) == "F0Ac")
    check("a fan between its slowest and its fastest", Fan(rpm: 3350, min: 1350, max: 5350).fraction == 0.5 && Fan(rpm: 5787, min: 1350, max: 5777).fraction == 1
          && Fan(rpm: 900, min: 1350, max: 5350).fraction == 0 && Fan(rpm: 2000).fraction == nil && Fan(rpm: 2000, min: 1350, max: 1350).fraction == nil)
    var working = Metrics()
    working.fans = [Fan(rpm: 3350, min: 1350, max: 5350), Fan(rpm: 5777, min: 1350, max: 5777)]
    working.powerW = 142.94
    check("of several fans: the fastest, and the one working hardest", working.fanRpm == 5777 && working.fanFraction == 1 && Metrics().fanRpm == nil && Metrics().fanFraction == nil)
    let busy = StateSnapshot.make(groups: [], metrics: working, now: agentNow, host: "Test Mac").metrics
    check("the snapshot has each fan, how hard they work, and the draw to a tenth of a watt", busy.fanRpm == [3350, 5777] && busy.fanFraction == 1 && busy.powerW == 142.9)
    let silent = StateSnapshot.make(groups: [], metrics: Metrics(), now: agentNow, host: "Test Mac")
    check("a Mac that does not say has none of the three, and the JSON leaves them out",
          silent.metrics.fanRpm == nil && silent.metrics.powerW == nil && !String(decoding: silent.json(), as: UTF8.self).contains("powerW"))
    let line = String(decoding: BuddyProtocol.mac(working, cores: 10), as: UTF8.self)
    check("a device is told the draw in whole watts and the fans as a percentage", line.contains("\"w\":143") && line.contains("\"fan\":100"))
    check("what a shot drew, in as few figures as say enough", Fmt.energy(0.42) == "0.4 Wh" && Fmt.energy(8.26) == "8.3 Wh" && Fmt.energy(118.4) == "118 Wh"
          && Fmt.energy(994) == "994 Wh" && Fmt.energy(1240) == "1.2 kWh")
}

section("history: what a shot drew")
do {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-energy-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    try? FileManager.default.removeItem(at: file)
    func shot(_ name: String, _ state: ItemState, done: Int? = nil) -> RenderItem {
        var item = RenderItem(id: "w/stream/\(name)", name: name, state: state)
        item.framesDone = done
        item.framesTotal = 100
        return item
    }
    func group(_ shots: [RenderItem]) -> RenderGroup {
        RenderGroup(id: "w", title: "Queue", script: "queue.sh", scriptPath: nil, note: nil, project: "watts", cwd: "/", startedAt: t0,
                    keepAwake: false, state: .running, items: shots)
    }
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    if let store = HistoryStore(file: file) {
        // Shot a alone for 20 s at 180 W; then a and b together for 20 s at 360 W; then a is done and b goes on
        // alone for 10 s at 180 W. Looks are 10 s apart, so every stretch counts in full.
        store.record([group([shot("a", .rendering, done: 0), shot("b", .pending)])], powerW: 180, now: at(0))
        store.record([group([shot("a", .rendering, done: 10), shot("b", .pending)])], powerW: 180, now: at(10))
        store.record([group([shot("a", .rendering, done: 20), shot("b", .rendering, done: 0)])], powerW: 180, now: at(20))
        store.record([group([shot("a", .rendering, done: 30), shot("b", .rendering, done: 10)])], powerW: 360, now: at(30))
        store.record([group([shot("a", .rendering, done: 40), shot("b", .rendering, done: 20)])], powerW: 360, now: at(40))
        store.record([group([shot("a", .done), shot("b", .rendering, done: 30)])], powerW: 180, now: at(50))
        store.record([group([shot("a", .done), shot("b", .rendering, done: 40)])], powerW: 180, now: at(60))
        // A long silence (the Mac slept): only the first quarter of a minute of it is counted.
        store.record([group([shot("a", .done), shot("b", .rendering, done: 50)])], powerW: 180, now: at(3660))
        store.record([], powerW: 180, now: at(3670))
        let runs = store.recent(limit: 10)
        let a = runs.first { $0.shot == "a" }?.energyWh ?? -1, b = runs.first { $0.shot == "b" }?.energyWh ?? -1
        // a: 10 s at 180 alone, 10 s at 180 alone (b had not been seen rendering before that look), 10 s and 10 s
        // at 360 shared in two = 0.5 + 0.5 + 0.5 + 0.5 = 2.0 Wh. It was done by the look at 50 s, which adds nothing.
        check("a shot alone gets all the Mac drew; two together share it equally", abs(a - 2.0) < 0.0001)
        // b: from the look at 30 s: 0.5 + 0.5 shared; 10 s at 180 alone = 0.5, twice... 50 s and 60 s; then 15 s of the hour = 0.75.
        check("the other shot's share, and no more than a quarter of a minute of a long silence", abs(b - (0.5 + 0.5 + 0.5 + 0.5 + 0.75)) < 0.0001)
        check("a look with no reading adds nothing", {
            let before = store.recent(limit: 10).compactMap(\.energyWh).reduce(0, +)
            store.record([group([shot("c", .rendering, done: 0)])], powerW: nil, now: at(4000))
            store.record([group([shot("c", .rendering, done: 10)])], powerW: nil, now: at(4010))
            store.record([], now: at(4020))
            let c = store.recent(limit: 10).first { $0.shot == "c" }
            return c != nil && c?.energyWh == nil && store.recent(limit: 10).compactMap(\.energyWh).reduce(0, +) == before
        }())
    } else {
        check("the history file for what a shot drew can be made", false)
    }
    try? FileManager.default.removeItem(at: file)

    // A file made by 0.3 has no such column.
    let old = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-energy-old-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    try? FileManager.default.removeItem(at: old)
    var db: OpaquePointer?
    sqlite3_open(old.path, &db)
    sqlite3_exec(db, """
        CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT NOT NULL UNIQUE, job_id TEXT NOT NULL, job_title TEXT NOT NULL,
          project TEXT NOT NULL, script TEXT, shot TEXT NOT NULL, started_at REAL NOT NULL, updated_at REAL NOT NULL, ended_at REAL,
          frames_done INTEGER, frames_total INTEGER, exact INTEGER NOT NULL DEFAULT 0, sec_per_frame REAL, outcome TEXT, exit_code INTEGER);
        CREATE TABLE samples (run_id INTEGER NOT NULL, at REAL NOT NULL, frames_done INTEGER NOT NULL);
        INSERT INTO runs (item_id, job_id, job_title, project, shot, started_at, updated_at, ended_at, frames_done, frames_total, exact, outcome)
          VALUES ('o/1', 'o', 'Old queue', 'old', 'before', 100, 200, 200, 50, 50, 1, 'done');
        """, nil, nil, nil)
    sqlite3_close(db)
    let readOld = HistoryStore(file: old, readOnly: true)?.recent(limit: 5)
    check("an older file that is only read still gives its shots, with nothing said about what they drew",
          readOld?.count == 1 && readOld?.first?.shot == "before" && readOld?.first?.energyWh == nil)
    let opened = HistoryStore(file: old)
    check("opened to write, it gains the column and keeps what was there", opened?.recent(limit: 5).first?.shot == "before" && opened?.recent(limit: 5).first?.energyWh == nil)
    try? FileManager.default.removeItem(at: old)
}

section("history: estimates against what happened")
let estimatesFile = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-estimates-\(ProcessInfo.processInfo.processIdentifier).sqlite")
try? FileManager.default.removeItem(at: estimatesFile)
if let store = HistoryStore(file: estimatesFile) {
    func shot(_ queue: String, _ name: String, _ state: ItemState, done: Int? = nil, total: Int? = nil, spf: Double? = nil) -> RenderItem {
        var item = RenderItem(id: "\(queue)/stream/\(name)", name: name, state: state)
        item.framesDone = done
        item.framesTotal = total
        item.secPerFrame = spf
        return item
    }
    func group(_ id: String, _ shots: [RenderItem]) -> RenderGroup {
        RenderGroup(id: id, title: "Queue", script: "queue.sh", scriptPath: nil, note: nil, project: "est", cwd: "/", startedAt: t0,
                    keepAwake: false, state: .running, items: shots)
    }
    // Two shots of 100 frames. The first really takes 10 s a frame, and is said to take 12 at first, then 10.
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    store.record([group("e1", [shot("e1", "a", .rendering, done: 0, total: 100), shot("e1", "b", .pending)])], now: at(0))
    store.record([group("e1", [shot("e1", "a", .rendering, done: 10, total: 100, spf: 12), shot("e1", "b", .pending)])], now: at(100))
    store.record([group("e1", [shot("e1", "a", .rendering, done: 11, total: 100, spf: 12), shot("e1", "b", .pending)])], now: at(110))
    store.record([group("e1", [shot("e1", "a", .rendering, done: 50, total: 100, spf: 10), shot("e1", "b", .pending)])], now: at(500))
    let early = store.estimateReport(days: 1, now: at(600))
    check("an estimate whose shot is still going is not judged", early.lines.isEmpty && early.leftOut["still running"] == 4)
    store.record([group("e1", [shot("e1", "a", .rendering, done: 100, total: 100, spf: 10), shot("e1", "b", .pending)])], now: at(1000))
    store.record([group("e1", [shot("e1", "a", .done), shot("e1", "b", .rendering, done: 0, total: 100)])], now: at(1010))
    store.record([group("e1", [shot("e1", "a", .done), shot("e1", "b", .rendering, done: 50, total: 100, spf: 10)])], now: at(1500))
    store.record([group("e1", [shot("e1", "a", .done), shot("e1", "b", .rendering, done: 100, total: 100, spf: 10)])], now: at(2000))
    store.record([], now: at(2010))
    let report = store.estimateReport(days: 1, now: at(3000))
    let shots = report.lines.first { $0.kind == "shot" && $0.horizon == "all" }
    // Shot a: at 100 s it said 90 x 12 = 1080 and 900 were left (off by 180, 20%); the look at 110 s came too soon
    // after to be written down; at 500 s it said 500 and 500 were left. Shot b: at 1500 s it said 500, and 500 were left.
    check("estimates are written down once a minute, not at every look", shots?.estimates == 3 && shots?.targets == 2)
    check("a shot's estimate is held against the moment its last frame was counted", shots?.medianOff == 0 && shots?.medianBias == 0 && shots?.withinFifth == 1)
    let queues = report.lines.first { $0.kind == "queue" && $0.horizon == "all" }
    // The queue ends at 2010 s. At 100 s it said 1080 for a plus 1180 for b (a projected to its end stands in):
    // 2260 against 1910 left, 350 too long. At 500 s: 500 + 1000 against 1510, 10 short. At 1000 s a has all its
    // frames and nothing says how long is left: no estimate. At 1010 s nothing is known of b yet, a's 1010 stands
    // in, against 1000: 10 long. At 1500 s: 500 against 510. At 2000 s: 20 against 10.
    check("a queue's estimate is held against the end of its last shot", queues?.estimates == 5 && queues?.targets == 1 && queues?.medianOff == 10 && queues?.medianBias == 10)
    check("how many came within a fifth of the time that was left", queues?.withinFifth == 0.8)
    check("the lines are split by how much time really was left", report.lines.contains { $0.kind == "queue" && $0.horizon == "10 to 60 min" && $0.estimates == 3 }
          && report.lines.contains { $0.kind == "queue" && $0.horizon == "under 10 min" && $0.estimates == 2 && $0.medianBias == 0 })
    check("the report says which stretch of time it covers", report.from == at(100).timeIntervalSince1970 && report.to == at(2000).timeIntervalSince1970)
    // A queue that is stopped with a shot still to come says nothing about its estimate.
    store.record([group("e2", [shot("e2", "c", .rendering, done: 50, total: 100, spf: 10), shot("e2", "d", .pending)])], now: at(5000))
    store.record([], now: at(5100))
    let stopped = store.estimateReport(days: 1, now: at(6000))
    check("a queue stopped half-way is left out, not counted as a wrong estimate", stopped.leftOut["did not finish"] == 2
          && stopped.lines.first { $0.kind == "queue" && $0.horizon == "all" }?.estimates == 5)
    // A shot that is simply gone, with all but its last frames counted, did come to its end; one gone at half did not.
    store.record([group("e3", [shot("e3", "f", .rendering, done: 50, total: 100, spf: 10)])], now: at(7000))
    store.record([group("e3", [shot("e3", "f", .rendering, done: 98, total: 100, spf: 10)])], now: at(7480))
    store.record([], now: at(7500))
    let gone = store.estimateReport(days: 1, now: at(8000))
    check("a shot gone with nearly all its frames counted is taken to have ended then", gone.lines.first { $0.kind == "shot" && $0.horizon == "all" }?.estimates == 5
          && gone.leftOut["did not finish"] == 2)
    // A shot that counts its frames twice: rendered to 100 at 9300 s, then composited from 0 again to 100 at 9700 s.
    store.record([group("e4", [shot("e4", "h", .rendering, done: 50, total: 100, spf: 6)])], now: at(9000))
    store.record([group("e4", [shot("e4", "h", .rendering, done: 100, total: 100, spf: 6)])], now: at(9300))
    store.record([group("e4", [shot("e4", "h", .compositing, done: 20, total: 100, spf: 4)])], now: at(9380))
    store.record([group("e4", [shot("e4", "h", .compositing, done: 100, total: 100, spf: 4)])], now: at(9700))
    store.record([], now: at(9710))
    let twice = store.estimateReport(days: 1, now: at(9800))
    // At 9000 s it said 300 and the count was full 300 s later; at 9380 s it said 320, and the count was full again 320 s later.
    check("each estimate is held against the next time the count is full, not the first", twice.lines.first { $0.kind == "shot" && $0.horizon == "all" }?.estimates == 7
          && twice.lines.first { $0.kind == "shot" && $0.horizon == "all" }?.medianOff == 0 && twice.leftOut["already over"] == nil)
    check("the report carries no names and no paths", !String(decoding: (try? JSONEncoder().encode(stopped)) ?? Data(), as: UTF8.self).contains("Queue"))
    store.prune(olderThanDays: 1, now: at(10 * 86_400))
    check("old estimates are pruned with the rest", store.estimateReport(days: 365, now: at(10 * 86_400)).lines.isEmpty)
} else {
    check("the estimates file opens", false)
}
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: estimatesFile.path + suffix) }
let neverCreated = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-readonly-\(ProcessInfo.processInfo.processIdentifier).sqlite")
check("looking things up does not create a history file", HistoryStore(file: neverCreated, readOnly: true) == nil && !FileManager.default.fileExists(atPath: neverCreated.path))

// MARK: Odd frames

section("odd frames")
func frames(_ n: Int, size: (Int) -> Int = { _ in 800_000 }, gap: (Int) -> Double = { _ in 6 }) -> [(index: Int, at: Date, size: Int)] {
    var at = t0
    return (0..<n).map { i in
        at = at.addingTimeInterval(gap(i))
        return (index: i, at: at, size: size(i))
    }
}
check("nothing odd in an even run", TaskScanner.oddFrames(frames(40)).small.isEmpty && TaskScanner.oddFrames(frames(40)).slow.isEmpty)
check("a frame a tenth the usual size is flagged", TaskScanner.oddFrames(frames(40, size: { $0 == 33 ? 60_000 : 800_000 })).small == [33])
check("a frame half the usual size is not", TaskScanner.oddFrames(frames(40, size: { $0 == 33 ? 400_000 : 800_000 })).small.isEmpty)
check("tiny frames are not judged when tiny is normal", TaskScanner.oddFrames(frames(40, size: { $0 == 33 ? 500 : 9_000 })).small.isEmpty)
check("a gap far beyond the usual is flagged", TaskScanner.oddFrames(frames(40, gap: { $0 == 20 ? 300 : 6 })).slow == [20])
check("a longer gap that is still short is not", TaskScanner.oddFrames(frames(40, gap: { $0 == 20 ? 15 : 2 })).slow.isEmpty)
check("too few frames to judge by", TaskScanner.oddFrames(frames(8, size: { $0 == 5 ? 100 : 800_000 })).small.isEmpty)
check("at most the five latest are listed", TaskScanner.oddFrames(frames(60, size: { $0 % 5 == 0 ? 10_000 : 800_000 })).small.count == 5)

// MARK: Following a log file

section("following a redirected log")
let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-\(ProcessInfo.processInfo.processIdentifier).log")
FileManager.default.createFile(atPath: logFile.path, contents: nil)
let sleeper = Process()
sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
sleeper.arguments = ["30"]
sleeper.standardOutput = FileHandle(forWritingAtPath: logFile.path)
try? sleeper.run()
func appendLog(_ text: String) {
    guard let h = FileHandle(forWritingAtPath: logFile.path) else { return }
    h.seekToEndOfFile()
    h.write(Data(text.utf8))
    try? h.close()
}
let follower = LogFollower()
check("an empty log says nothing", follower.progress(pid: sleeper.processIdentifier, totalFromCommandLine: nil) == nil)
appendLog("Saved: '/old/run/f_0001.png'\nSaved: '/old/run/f_0002.png'\nBlender quit\n")
appendLog("00:00.2  render           | Rendering animation (frames 1..20)\n00:00.3  render           | Saved: '/new/run/f_0001.png'\n")
var followed = follower.progress(pid: sleeper.processIdentifier, totalFromCommandLine: nil)
check("an earlier render in the same log is not counted", followed?.done == 1 && followed?.total == 20 && followed?.outDir == "/new/run")
appendLog("00:00.4  render           | Saved: '/new/run/f_0002.png'\n00:00.5  render           | Fra: 3 | Mem: 1M | Sam")
followed = follower.progress(pid: sleeper.processIdentifier, totalFromCommandLine: nil)
check("new lines are picked up; a half-written line waits", followed?.done == 2 && followed?.frame != 3)
appendLog("ple 4/8\n")
followed = follower.progress(pid: sleeper.processIdentifier, totalFromCommandLine: nil)
check("the rest of the line completes it", followed?.frame == 3 && followed?.sampleDone == 4)
check("a process whose output is not a file is not followed", follower.progress(pid: ProcessInfo.processInfo.processIdentifier, totalFromCommandLine: nil) == nil
      || isatty(1) == 0)
sleeper.terminate()
try? FileManager.default.removeItem(at: logFile)

// MARK: Adapter rules

section("adapter rules")
let rulesJSON = #"""
{
  "adapters": [
    { "name": "composite", "process": "node", "args": ["render.mjs", "--scene"], "notAbove": "blender",
      "state": "compositing", "frames": "{cwd}/out/frames/{--scene}-{--shot}",
      "total": { "jsonFile": "{cwd}/out/blender/{--scene}-{--shot}/meta.json", "countOf": "frames" }, "freshDir": true },
    { "name": "encoder", "process": "MyEncoder", "title": "encode {--job}", "total": { "arg": "--frames" } }
  ],
  "queueDoneFile": "{cwd}/out/{scene}-{shot}.mp4"
}
"""#
let rules = try? JSONDecoder().decode(AdapterRules.self, from: Data(rulesJSON.utf8))
check("the file parses", rules?.adapters.count == 2 && rules?.queueDoneFile != nil)
if let rules {
    let composite = rules.adapters[0], encoder = rules.adapters[1]
    check("process name and arguments must match", composite.matches(process: "node", args: ["node", "/tools/render.mjs", "--scene", "a", "--shot", "b"]))
    check("a script name also matches a bare argument", composite.matches(process: "node", args: ["node", "render.mjs", "--scene", "a"]))
    check("a missing argument does not match", !composite.matches(process: "node", args: ["node", "render.mjs"]))
    check("another process does not match", !composite.matches(process: "python3", args: ["render.mjs", "--scene", "a"]))
    check("process names are case-insensitive", encoder.matches(process: "myencoder", args: []))
    check("states", composite.itemState == .compositing && encoder.itemState == .rendering)
    let args = ["node", "render.mjs", "--scene", "s040", "--shot=explode"]
    check("templates take values from arguments, either spelling",
          AdapterRules.expand(composite.frames!, args: args, cwd: "/proj") == "/proj/out/frames/s040-explode")
    check("a placeholder without a value gives no path at all",
          AdapterRules.expand(composite.frames!, args: ["node", "render.mjs", "--scene", "s040"], cwd: "/proj") == nil)
    check("queue done-file template",
          AdapterRules.expand(rules.queueDoneFile!, args: [], cwd: "/proj", extra: ["scene": "s040", "shot": "explode"]) == "/proj/out/s040-explode.mp4")
    check("an unclosed placeholder is refused", AdapterRules.expand("{cwd}/x/{oops", args: [], cwd: "/proj") == nil)
    check("text without placeholders passes through", AdapterRules.expand("/fixed/path", args: [], cwd: "") == "/fixed/path")
}
check("no file means no extra rules", AdapterRules.load(from: URL(fileURLWithPath: "/nonexistent/adapters.json")) == AdapterRules())
check("an empty object is fine", (try? JSONDecoder().decode(AdapterRules.self, from: Data("{}".utf8))) == AdapterRules())

// MARK: Notifications

section("notification channels")
func bodyObject(_ r: OutgoingRequest?) -> [String: Any] {
    (r?.body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
}
var bark = NotifyChannel(type: "bark")
check("bark without a key builds nothing", Notify.request(for: bark, title: "T", body: "B", event: "job.ended") == nil)
bark.key = "KEY"
var r = Notify.request(for: bark, title: "渲染完成", body: "第 4 集", event: "job.ended")
check("bark", r?.url == "https://api.day.app/push" && r?.method == "POST" && bodyObject(r)["device_key"] as? String == "KEY" && bodyObject(r)["title"] as? String == "渲染完成")
bark.server = "http://127.0.0.1:9000/"
check("bark on your own server", Notify.request(for: bark, title: "T", body: "B", event: "e")?.url == "http://127.0.0.1:9000/push")
var ntfy = NotifyChannel(type: "ntfy")
ntfy.topic = "renders"
r = Notify.request(for: ntfy, title: "T", body: "B", event: "e")
check("ntfy publishes JSON, so titles need not be ASCII", r?.url == "https://ntfy.sh/" && bodyObject(r)["topic"] as? String == "renders" && bodyObject(r)["message"] as? String == "B")
var feishu = NotifyChannel(type: "feishu")
feishu.url = "https://example.invalid/hook"
r = Notify.request(for: feishu, title: "T", body: "B", event: "e")
check("feishu", bodyObject(r)["msg_type"] as? String == "text" && (bodyObject(r)["content"] as? [String: Any])?["text"] as? String == "T\nB")
var wecom = NotifyChannel(type: "wecom")
wecom.url = "https://example.invalid/send?key=k"
r = Notify.request(for: wecom, title: "T", body: "", event: "e")
check("wecom, and an empty body is just the title", (bodyObject(r)["text"] as? [String: Any])?["content"] as? String == "T")
var telegram = NotifyChannel(type: "telegram")
telegram.token = "123:abc"
telegram.chatId = "42"
r = Notify.request(for: telegram, title: "T", body: "B", event: "e")
check("telegram", r?.url == "https://api.telegram.org/bot123:abc/sendMessage" && bodyObject(r)["chat_id"] as? String == "42")
var hook = NotifyChannel(type: "webhook")
hook.url = "http://127.0.0.1:9000/hook"
hook.body = #"{"t": "{title}", "b": "{body}", "e": "{event}"}"#
r = Notify.request(for: hook, title: "He said \"done\"", body: "line1\nline2", event: "job.ended")
check("webhook template stays valid JSON when values need escaping",
      bodyObject(r)["t"] as? String == "He said \"done\"" && bodyObject(r)["b"] as? String == "line1\nline2" && bodyObject(r)["e"] as? String == "job.ended")
hook.body = nil
check("webhook without a template sends a plain JSON object", bodyObject(Notify.request(for: hook, title: "T", body: "B", event: "e", job: "J", project: "P"))["job"] as? String == "J")
check("unknown channel type", Notify.request(for: NotifyChannel(type: "pigeon"), title: "T", body: "B", event: "e") == nil)

section("notification settings and wording")
let parsed = try? JSONDecoder().decode(NotifyConfig.self, from: Data(Notify.template.utf8))
check("the starter file parses and everything in it is off", parsed?.channels.count == 5 && parsed?.channels.allSatisfy { $0.enabled == false } == true)
var picky = NotifyChannel(type: "ntfy")
picky.events = ["shot.done"]
check("a channel announces only what it asks for", picky.wants("shot.done") && !picky.wants("job.ended"))
check("by default: ended, stalled, all ended, but not every shot", ntfy.wants("job.ended") && ntfy.wants("job.stalled") && !ntfy.wants("shot.done"))
picky.enabled = false
check("a disabled channel wants nothing", !picky.wants("shot.done"))
Lang.current = .en
func ended(_ outcome: String?, _ code: Int32?) -> RenderEvent {
    RenderEvent(type: .jobEnded, jobId: "a", jobTitle: "Hero shots", project: "p", shot: nil, outcome: outcome, exitCode: code, at: "")
}
check("finished", Notify.message(for: ended("finished", 0))?.title == "Render finished")
check("failed carries the exit status", Notify.message(for: ended("failed", 139))?.body == "Hero shots · exit status 139")
check("unknown ending makes no claim", Notify.message(for: ended(nil, nil))?.title == "Render job ended")
check("the last job says the queue is empty", Notify.message(for: ended("finished", 0), lastOne: true)?.body == "Hero shots · nothing else is running")
check("starting a job is not announced", Notify.message(for: RenderEvent(type: .jobStarted, jobId: "a", jobTitle: "x", project: "p", shot: nil, outcome: nil, exitCode: nil, at: "")) == nil)

// MARK: Coding agents' sessions

section("agent states")
check("states are ordered by how much they need the user", AgentState.allCases == [.error, .waiting, .working, .done, .idle, .stale])
check("waiting outranks working", AgentState.waiting.rank < AgentState.working.rank)
check("busy is working", ClaudeCodeSource.state(status: "busy") == .working)
check("idle is idle", ClaudeCodeSource.state(status: "idle") == .idle)
check("waiting is waiting", ClaudeCodeSource.state(status: "waiting") == .waiting)
check("an unknown status is idle, never working", ClaudeCodeSource.state(status: "some-new-word") == .idle)
check("a blocked background session is waiting", ClaudeCodeSource.state(status: "busy", background: "blocked") == .waiting)
check("a failed background session is an error", ClaudeCodeSource.state(status: nil, background: "failed") == .error)
check("a finished background session is done", ClaudeCodeSource.state(status: "idle", background: "done") == .done)
check("a stopped background session is idle", ClaudeCodeSource.state(status: nil, background: "stopped") == .idle)
check("a working background session without a status is working", ClaudeCodeSource.state(status: nil, background: "working") == .working)

let agentNow = Date(timeIntervalSince1970: 1_800_000_000)
check("idle a moment after working is 'just finished'",
      ClaudeCodeSource.settled(.idle, since: agentNow.addingTimeInterval(-100), startedAt: agentNow.addingTimeInterval(-5000), now: agentNow) == .done)
check("…and plain idle once the window has passed",
      ClaudeCodeSource.settled(.idle, since: agentNow.addingTimeInterval(-400), startedAt: agentNow.addingTimeInterval(-5000), now: agentNow) == .idle)
check("a session that went idle right after starting has finished nothing",
      ClaudeCodeSource.settled(.idle, since: agentNow.addingTimeInterval(-100), startedAt: agentNow.addingTimeInterval(-103), now: agentNow) == .idle)
check("a working session is left alone",
      ClaudeCodeSource.settled(.working, since: agentNow.addingTimeInterval(-100), startedAt: agentNow.addingTimeInterval(-5000), now: agentNow) == .working)

section("Claude Code sessions")
do {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("rd-claude-\(UUID().uuidString)")
    let registryDir = home.appendingPathComponent("sessions")
    let project = home.appendingPathComponent("work/demo-site")
    try? fm.createDirectory(at: registryDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: project, withIntermediateDirectories: true)
    let me = ProcessInfo.processInfo.processIdentifier
    func registry(pid: Int32, id: String, status: String) -> String {
        "{\"pid\":\(pid),\"sessionId\":\"\(id)\",\"cwd\":\"\(project.path)\",\"startedAt\":1799990000000,\"name\":\"Fix the login\",\"kind\":\"interactive\",\"status\":\"\(status)\",\"statusUpdatedAt\":1799999000000}"
    }
    let mine = registryDir.appendingPathComponent("\(me).json")
    try? registry(pid: me, id: "11111111-aaaa-bbbb-cccc-000000000001", status: "busy").write(to: mine, atomically: true, encoding: .utf8)
    try? registry(pid: 999_999, id: "22222222-aaaa-bbbb-cccc-000000000002", status: "idle")
        .write(to: registryDir.appendingPathComponent("999999.json"), atomically: true, encoding: .utf8)

    let listing = """
    [{"pid":\(me),"cwd":"\(project.path)","kind":"interactive","startedAt":1799990000000,"sessionId":"11111111-aaaa-bbbb-cccc-000000000001","name":"Fix the login","status":"waiting","waitingFor":"permission prompt"},
     {"pid":4242,"cwd":"\(project.path)","kind":"interactive","startedAt":1799990000000,"sessionId":"33333333-aaaa-bbbb-cccc-000000000003","name":"Other","status":"busy","waitingFor":"left over"},
     {"id":"bg1","cwd":"\(project.path)","kind":"background","startedAt":1799990000000,"sessionId":"44444444-aaaa-bbbb-cccc-000000000004","state":"failed"}]
    """
    var calls = 0
    var answer: Data? = Data(listing.utf8)
    let source = ClaudeCodeSource(home: home, binary: "/nonexistent/claude", runner: { _ in
        calls += 1
        return answer
    })
    let found = source.scan(now: agentNow)
    let waiting = found.first { $0.state == .waiting }
    check("every listed session is returned", found.count == 3)
    check("what the command reports is marked official", found.allSatisfy { $0.source == "official" } && source.lastSource == "official")
    check("a waiting session says what it waits for", waiting?.waitingFor == "permission prompt")
    check("waitingFor is dropped unless the session is waiting", found.first { $0.state == .working }?.waitingFor == nil)
    check("the project is a directory name, never a path", found.allSatisfy { $0.project == "demo-site" })
    check("the id is the tool and a short id", waiting?.id == "claude-code:11111111")
    check("the session's name is kept, for this Mac only", waiting?.title == "Fix the login")
    check("a failed background session is an error", found.contains { $0.state == .error && $0.id == "claude-code:44444444" })
    check("the time of the last change comes from the registry file", waiting?.since != nil)

    _ = source.scan(now: agentNow.addingTimeInterval(3))
    check("nothing changed: the command is not run again", calls == 1)
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: mine.path)
    _ = source.scan(now: agentNow.addingTimeInterval(6))
    check("a change in the registry runs it again", calls == 2)
    _ = source.scan(now: agentNow.addingTimeInterval(120))
    check("…and so does a while without news", calls == 3)

    answer = nil
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(9)], ofItemAtPath: mine.path)
    let fallback = source.scan(now: agentNow.addingTimeInterval(130))
    check("without the command, the registry is read and dead processes are dropped",
          fallback.count == 1 && fallback.first?.pid == me && fallback.first?.source == "files" && source.lastSource == "files")

    var untouched = 0
    let absent = ClaudeCodeSource(home: home.appendingPathComponent("nope"), binary: "/nonexistent/claude", runner: { _ in
        untouched += 1
        return nil
    })
    check("no Claude Code directory: nothing is run and nothing is found", absent.scan().isEmpty && untouched == 0)
    try? fm.removeItem(at: home)
}

section("Codex sessions")
do {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("rd-codex-\(UUID().uuidString)")
    let day = home.appendingPathComponent("sessions/2027/01/15")
    let cwd = home.appendingPathComponent("work/billing-api")
    try? fm.createDirectory(at: day, withIntermediateDirectories: true)
    try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func stamp(_ ago: TimeInterval) -> String { iso.string(from: now.addingTimeInterval(-ago)) }
    func meta(_ id: String, subagent: Bool = false) -> String {
        let source = subagent ? "{\"subagent\":{\"other\":\"review\"}}" : "\"vscode\""
        // The real first line carries the whole base prompt, tens of kilobytes of it.
        return "{\"timestamp\":\"\(stamp(3600))\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd.path)\",\"source\":\(source),\"thread_source\":\"\(subagent ? "subagent" : "user")\",\"base_instructions\":{\"text\":\"\(String(repeating: "x", count: 30_000))\"}}}"
    }
    func event(_ type: String, ago: TimeInterval) -> String {
        "{\"timestamp\":\"\(stamp(ago))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"t\"}}"
    }
    let chatter = "{\"timestamp\":\"\(stamp(1))\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"the log said task_complete and then task_started\"}}"
    func write(_ name: String, _ lines: [String], modifiedAgo: TimeInterval = 0) {
        let url = day.appendingPathComponent("rollout-\(name).jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if modifiedAgo > 0 { try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-modifiedAgo)], ofItemAtPath: url.path) }
    }
    write("working", [meta("aaaaaaaa-0000-0000-0000-000000000001"), event("task_started", ago: 300), event("task_complete", ago: 200),
                      event("task_started", ago: 120), chatter])
    write("done", [meta("bbbbbbbb-0000-0000-0000-000000000002"), event("task_started", ago: 400), event("task_complete", ago: 60), chatter])
    write("old", [meta("cccccccc-0000-0000-0000-000000000003"), event("task_started", ago: 9000), event("task_complete", ago: 8000)])
    write("aborted", [meta("dddddddd-0000-0000-0000-000000000004"), event("task_started", ago: 90), event("turn_aborted", ago: 30)])
    write("sub", [meta("eeeeeeee-0000-0000-0000-000000000005", subagent: true), event("task_started", ago: 50)])
    write("quiet", [meta("ffffffff-0000-0000-0000-000000000006"), event("task_started", ago: 3000)], modifiedAgo: 1500)
    try? "{\"id\":\"aaaaaaaa-0000-0000-0000-000000000001\",\"thread_name\":\"Add invoice export\",\"updated_at\":\"x\"}\n"
        .write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

    let running = CodexSource(home: home, alive: { true }).scan(now: now)
    func state(_ short: String, in list: [AgentSession]) -> AgentState? { list.first { $0.id == "codex:\(short)" }?.state }
    check("a turn that started and has not ended is working", state("aaaaaaaa", in: running) == .working)
    check("a turn that ended a minute ago is done; words inside a message are not events", state("bbbbbbbb", in: running) == .done)
    check("a turn that ended hours ago is not listed", state("cccccccc", in: running) == nil)
    check("an interrupted turn is not listed", state("dddddddd", in: running) == nil)
    check("a subagent's thread is not listed", state("eeeeeeee", in: running) == nil)
    check("a turn with nothing written for a long while has gone quiet", state("ffffffff", in: running) == .stale)
    check("Codex sessions never show as waiting", !running.contains { $0.state == .waiting })
    check("the project is a directory name and the source says files", !running.isEmpty && running.allSatisfy { $0.project == "billing-api" && $0.source == "files" })
    check("the thread's name is picked up", running.first { $0.id == "codex:aaaaaaaa" }?.title == "Add invoice export")
    let stopped = CodexSource(home: home, alive: { false }).scan(now: now)
    check("with Codex not running, an unfinished turn is not shown; a finished one still is",
          state("aaaaaaaa", in: stopped) == nil && state("ffffffff", in: stopped) == nil && state("bbbbbbbb", in: stopped) == .done)
    check("no Codex directory: nothing", CodexSource(home: home.appendingPathComponent("nope"), alive: { true }).scan().isEmpty)
    try? fm.removeItem(at: home)
}

section("Hermes")
do {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("rd-hermes-\(UUID().uuidString)")
    try? fm.createDirectory(at: home, withIntermediateDirectories: true)
    let me = ProcessInfo.processInfo.processIdentifier
    func gateway(_ state: String, pid: Int32, agents: Int) {
        try? "{\"gateway_state\":\"\(state)\",\"pid\":\(pid),\"active_agents\":\(agents),\"updated_at\":\"2027-01-15T08:00:00.123456+00:00\",\"start_time\":1800000000}"
            .write(to: home.appendingPathComponent("gateway_state.json"), atomically: true, encoding: .utf8)
    }
    let source = HermesSource(home: home)
    check("no Hermes directory content: nothing", source.scan().isEmpty)
    gateway("running", pid: me, agents: 0)
    let idle = source.scan()
    check("a running gateway with nothing active is idle", idle.count == 1 && idle[0].state == .idle && idle[0].id == "hermes:gateway")
    check("a timestamp with microseconds is understood", idle.first?.since != nil)
    gateway("running", pid: me, agents: 2)
    check("active agents make it working", source.scan().first?.state == .working)
    gateway("stopped", pid: me, agents: 0)
    check("a gateway that says it stopped is not listed", source.scan().isEmpty)
    gateway("running", pid: 999_999, agents: 1)
    check("a gateway whose process is gone is not listed", source.scan().isEmpty)

    var db: OpaquePointer?
    let file = home.appendingPathComponent("kanban.db")
    if sqlite3_open(file.path, &db) == SQLITE_OK {
        sqlite3_exec(db, """
            CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, workspace_path TEXT, worker_pid INTEGER, started_at INTEGER, completed_at INTEGER);
            INSERT INTO tasks VALUES ('t1', 'Sort the inbox', '/tmp/somewhere/inbox-tools', \(me), 1800000000, NULL);
            INSERT INTO tasks VALUES ('t2', 'Already done', '', \(me), 1800000000, 1800000100);
            INSERT INTO tasks VALUES ('t3', 'Worker is gone', '', 999999, 1800000000, NULL);
            INSERT INTO tasks VALUES ('t4', 'Not started', '', NULL, NULL, NULL);
            """, nil, nil, nil)
        sqlite3_close(db)
    }
    let tasks = source.scan()
    check("a kanban task with a live worker is working", tasks.count == 1 && tasks[0].id == "hermes:task-t1" && tasks[0].state == .working)
    check("its project is a directory name", tasks.first?.project == "inbox-tools" && tasks.first?.title == "Sort the inbox")
    try? fm.removeItem(at: home)
}

section("agents in the state document")
do {
    let sessions = [
        AgentSession(id: "claude-code:a", tool: "claude-code", project: "demo-site", title: "A private title", state: .working,
                     since: agentNow.addingTimeInterval(-30), pid: 4321, source: "official"),
        AgentSession(id: "codex:b", tool: "codex", project: "billing-api", state: .idle, source: "files"),
        AgentSession(id: "claude-code:c", tool: "claude-code", project: "docs", state: .waiting, waitingFor: "permission prompt",
                     since: agentNow.addingTimeInterval(-5), source: "official"),
    ]
    let snap = StateSnapshot.make(groups: [], metrics: Metrics(), agents: sessions, now: agentNow, host: "Test Mac")
    let text = String(decoding: snap.json(), as: UTF8.self)
    check("most urgent first", snap.agents.map(\.state) == ["waiting", "working", "idle"])
    check("seconds in the state, when known", snap.agents[1].sinceSec == 30 && snap.agents[2].sinceSec == nil)
    check("what it waits for is carried", snap.agents[0].waitingFor == "permission prompt")
    check("no title leaves this Mac", !text.contains("A private title"))
    check("no process id for agent sessions", !text.contains("4321"))
    check("the session that most needs attention", sessions.top?.id == "claude-code:c" && sessions.count(.working) == 1)
    check("idle sessions alone need no attention", [sessions[1]].top == nil)
    let empty = String(decoding: StateSnapshot.make(groups: [], metrics: Metrics(), now: agentNow, host: "Test Mac").json(), as: UTF8.self)
    check("no agents is an empty list, not a missing field", empty.contains("\"agents\":[]"))
    check("tool names for display", AgentTool.displayName("claude-code") == "Claude Code" && AgentTool.displayName("something-else") == "something-else")
}

section("summary for small displays")
do {
    func agent(_ id: String, _ state: AgentState, tool: String = "claude-code", project: String = "demo-site", waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: "\(tool):\(id)", tool: tool, project: project, title: "A private title", state: state, waitingFor: waitingFor,
                     since: agentNow.addingTimeInterval(-20), source: "official")
    }
    func run(_ outcome: String, ago: Double) -> HistoryRun {
        HistoryRun(id: 1, jobId: "j", jobTitle: "Job", project: "demo", script: nil, shot: "s9", startedAt: agentNow.timeIntervalSince1970 - ago - 600,
                   endedAt: agentNow.timeIntervalSince1970 - ago, framesDone: 10, framesTotal: 10, exact: true, secPerFrame: 1, outcome: outcome, exitCode: outcome == "failed" ? 1 : 0)
    }
    func summary(groups: [RenderGroup] = [], agents: [AgentSession] = [], recent: [HistoryRun] = []) -> StateSnapshot.Summary {
        StateSnapshot.make(groups: groups, metrics: Metrics(), agents: agents, recent: recent, now: agentNow, host: "Test Mac").summary
    }
    let nothing = summary()
    check("nothing going on is idle, with no top item", nothing.state == "idle" && nothing.top == nil && nothing.line == "idle")

    let rendering = summary(groups: [groupA])
    check("a render alone is working, and the top item is the shot with its percentage",
          rendering.state == "working" && rendering.top?.kind == "render" && rendering.top?.name == "s2" && rendering.top?.fraction == 0.5 && rendering.line == "render 50%")

    let both = summary(groups: [groupA], agents: [agent("a", .working), agent("b", .idle)])
    check("render and agent both working: the render is the top item", both.state == "working" && both.top?.kind == "render" && both.line == "render 50% | 1 working")
    check("agent counts", both.agents.working == 1 && both.agents.idle == 1 && both.agents.waiting == 0)

    let waiting = summary(groups: [groupA], agents: [agent("a", .working), agent("c", .waiting, project: "docs", waitingFor: "permission prompt")])
    check("a waiting session outranks a running render", waiting.state == "waiting" && waiting.top?.kind == "agent" && waiting.top?.name == "docs")
    check("the top item says what it waits for", waiting.top?.waitingFor == "permission prompt" && waiting.top?.tool == "claude-code")
    check("the line puts waiting first and drops what does not fit", waiting.line == "1 waiting | render 50%")

    let failing = summary(agents: [agent("a", .error), agent("c", .waiting)])
    check("an error outranks waiting", failing.state == "error" && failing.top?.state == "error" && failing.line == "1 failed | 1 waiting")

    let stalled = summary(groups: [job("x", .stalled, [("s1", .stalled)])])
    check("a stalled render is the renders' way of waiting", stalled.state == "waiting" && stalled.top?.kind == "render" && stalled.top?.name == "s1" && stalled.line == "1 waiting")
    let paused = summary(groups: [groupC])
    check("a paused render is not treated as waiting for you", paused.state == "idle" && paused.line == "idle")

    check("a render that failed a minute ago still shows as an error", summary(recent: [run("failed", ago: 60)]).state == "error")
    check("…and one that finished a minute ago as done", summary(recent: [run("finished", ago: 60)]).state == "done" && summary(recent: [run("finished", ago: 60)]).line == "1 done")
    check("after a few minutes it no longer counts", summary(recent: [run("finished", ago: 400)]).state == "idle")
    check("a job that merely vanished is not claimed as done", summary(recent: [run("ended", ago: 60)]).state == "idle")
    check("an agent that just finished is done", summary(agents: [agent("a", .done)]).state == "done" && summary(agents: [agent("a", .done)]).top?.name == "demo-site")

    let crowded = summary(groups: [groupA], agents: (0..<12).map { agent("w\($0)", .working) } + (0..<11).map { agent("q\($0)", .waiting) } + [agent("e", .error)])
    check("the line never exceeds 23 characters and is plain ASCII",
          crowded.line.count <= StateSnapshot.lineLimit && crowded.line.allSatisfy { $0.isASCII } && crowded.line.hasPrefix("1 failed | 11 waiting"))
    let json = String(decoding: StateSnapshot.make(groups: [groupA], metrics: Metrics(), agents: [agent("a", .waiting)], now: agentNow, host: "Test Mac").json(), as: UTF8.self)
    check("the summary carries no session title", !json.contains("A private title"))
}

section("agent events")
do {
    func agent(_ id: String, _ state: AgentState, since: Double, waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: "claude-code:\(id)", tool: "claude-code", project: "demo-site", title: "A private title", state: state,
                     waitingFor: waitingFor, since: agentNow.addingTimeInterval(since), source: "official")
    }
    func at(_ seconds: Double) -> Date { agentNow.addingTimeInterval(seconds) }
    var d = AgentEventDetector()
    check("the first scan announces nothing, not even a session already waiting",
          d.update([agent("a", .working, since: -300), agent("z", .waiting, since: -900)], now: at(0)).isEmpty)
    check("still nothing for the old wait", d.update([agent("a", .working, since: -300), agent("z", .waiting, since: -900)], now: at(6)).isEmpty)

    var e = d.update([agent("a", .waiting, since: 10, waitingFor: "permission prompt"), agent("z", .waiting, since: -900)], now: at(12))
    check("a wait of two seconds is not announced yet", e.isEmpty)
    e = d.update([agent("a", .waiting, since: 10, waitingFor: "permission prompt"), agent("z", .waiting, since: -900)], now: at(18))
    check("after eight seconds it is", e.map(\.type) == [.agentWaiting] && e.first?.jobId == "claude-code:a")
    check("the event names the tool and the project, and what it waits for",
          e.first?.jobTitle == "Claude Code" && e.first?.tool == "claude-code" && e.first?.project == "demo-site" && e.first?.waitingFor == "permission prompt")
    check("the session's own title is not in the event", !String(decoding: e.first?.json() ?? Data(), as: UTF8.self).contains("A private title"))
    e = d.update([agent("a", .waiting, since: 10, waitingFor: "permission prompt"), agent("z", .waiting, since: -900)], now: at(24))
    check("one wait, one announcement", e.isEmpty)

    e = d.update([agent("a", .working, since: 30), agent("z", .waiting, since: -900)], now: at(30))
    check("answering it announces nothing", e.isEmpty)
    e = d.update([agent("a", .done, since: 200), agent("z", .waiting, since: -900)], now: at(204))
    check("finishing the turn is announced with how long it ran", e.map(\.type) == [.agentDone] && e.first?.durationSec == 500)
    e = d.update([agent("a", .done, since: 200), agent("z", .waiting, since: -900)], now: at(210))
    check("…once", e.isEmpty)

    e = d.update([agent("a", .waiting, since: 300), agent("z", .waiting, since: -900)], now: at(309))
    check("a second wait of the same session is announced again", e.map(\.type) == [.agentWaiting])
    e = d.update([agent("a", .error, since: 320), agent("z", .idle, since: 320)], now: at(326))
    check("an error is announced, and with nothing working or waiting any more, so is that",
          e.map(\.type) == [.agentError, .agentsIdle])
    e = d.update([agent("a", .error, since: 320), agent("z", .idle, since: 320)], now: at(332))
    check("neither is repeated", e.isEmpty)
    check("a session that appears already finished is not announced", d.update([agent("n", .done, since: 330)], now: at(338)).isEmpty)

    var quick = AgentEventDetector()
    _ = quick.update([agent("a", .idle, since: -50)], now: at(0))
    _ = quick.update([agent("a", .working, since: 2)], now: at(6))
    let short = quick.update([agent("a", .done, since: 32)], now: at(36))
    check("a short turn still raises the event; it was the only busy session, so everything has stopped too",
          short.map(\.type) == [.agentDone, .agentsIdle] && short.first?.durationSec == 30)
    check("…but is not worth a notification", short.first.flatMap { Notify.message(for: $0) } == nil)
}

section("agent notifications")
do {
    func event(_ kind: RenderEvent.Kind, waitingFor: String? = nil, duration: Int? = nil) -> RenderEvent {
        RenderEvent(type: kind, jobId: "claude-code:a", jobTitle: "Claude Code", project: "demo-site", at: "2027-01-15T08:00:00Z",
                    tool: "claude-code", waitingFor: waitingFor, durationSec: duration)
    }
    let waiting = Notify.message(for: event(.agentWaiting, waitingFor: "permission prompt"))
    check("needs you: the tool in the title, the project and the reason in the body",
          waiting?.title.contains("Claude Code") == true && waiting?.body == "demo-site · permission prompt")
    check("without a reason, the project alone", Notify.message(for: event(.agentWaiting))?.body == "demo-site")
    check("a long turn that finished says how long it took",
          Notify.message(for: event(.agentDone, duration: 600))?.body.hasPrefix("demo-site") == true)
    check("a turn of unknown length is not announced", Notify.message(for: event(.agentDone)) == nil)
    check("an error is announced", Notify.message(for: event(.agentError))?.body == "demo-site")
    check("agent events are among the defaults, except 'all stopped'",
          ["agent.waiting", "agent.error", "agent.done"].allSatisfy { Notify.defaultEvents.contains($0) } && !Notify.defaultEvents.contains("agents.idle"))
    var hook = NotifyChannel(type: "webhook")
    hook.url = "http://127.0.0.1:9/hook"
    check("a channel with its own event list can leave agents out", { hook.events = ["job.ended"]; return !hook.wants("agent.waiting") }())
    check("agent events know what they are", RenderEvent.Kind.agentWaiting.isAgent && RenderEvent.Kind.agentsIdle.isAgent && !RenderEvent.Kind.jobEnded.isAgent)
}

// MARK: Answering agents

section("an agent's permission request")
func hookJSON(_ action: String, _ input: String, event: String = "PermissionRequest") -> Data {
    Data("{\"hook_event_name\":\"\(event)\",\"session_id\":\"s-1\",\"cwd\":\"/tmp/somewhere/demo-site\",\"permission_mode\":\"default\",\"tool_name\":\"\(action)\",\"tool_input\":\(input)}".utf8)
}
do {
    let bash = HookInput.parse(hookJSON("Bash", "{\"command\":\"npm test\",\"description\":\"Run the tests\"}"))
    check("a Bash request shows its command, and after it every other field by name",
          bash?.action == "Bash" && bash?.detail == "npm test  ·  description: Run the tests" && bash?.event == "PermissionRequest")
    check("the fingerprint is sixteen hex digits", bash?.fingerprint.count == 16 && bash?.fingerprint.allSatisfy(\.isHexDigit) == true)
    check("the same request has the same fingerprint, whatever the key order",
          bash?.fingerprint == HookInput.parse(hookJSON("Bash", "{\"description\":\"Run the tests\",\"command\":\"npm test\"}"))?.fingerprint)
    check("a different command has a different one", bash?.fingerprint != HookInput.parse(hookJSON("Bash", "{\"command\":\"npm test -- -u\",\"description\":\"Run the tests\"}"))?.fingerprint)
    check("a Read request shows its path", HookInput.parse(hookJSON("Read", "{\"file_path\":\"src/login.ts\"}"))?.detail == "src/login.ts")
    check("a search shows the pattern and where", HookInput.parse(hookJSON("Grep", "{\"pattern\":\"TODO\",\"path\":\"src\"}"))?.detail == "TODO  in  src")
    check("anything else shows every field by name", HookInput.parse(hookJSON("Mystery", "{\"b\":\"x\",\"a\":1}"))?.detail == "a: 1  ·  b: x")
    check("a search shows its other fields too", HookInput.parse(hookJSON("Grep", "{\"pattern\":\"TODO\",\"path\":\"src\",\"-i\":true,\"glob\":\"*.ts\"}"))?.detail
          == "TODO  in  src  ·  -i: true  ·  glob: *.ts")
    let edit = HookInput.parse(hookJSON("Edit", "{\"file_path\":\"a.txt\",\"old_string\":\"one\\ntwo\",\"new_string\":\"three\"}"))
    check("an edit shows what it would change, not only where", edit?.detail == "a.txt  ·  new_string: three  ·  old_string: one\ntwo")
    check("a flag that matters cannot hide behind the command",
          HookInput.parse(hookJSON("Bash", "{\"command\":\"ls\",\"dangerouslyDisableSandbox\":true}"))?.detail == "ls  ·  dangerouslyDisableSandbox: true")
    check("nested input is shown as it is", HookInput.parse(hookJSON("Mystery", "{\"list\":[1,2],\"path\":\"p\"}"))?.detail == "p  ·  list: [1,2]")
    check("without a tool name there is nothing to ask", HookInput.parse(Data("{\"hook_event_name\":\"PermissionRequest\"}".utf8)) == nil)

    let allow = HookOutput.permissionRequest(.allow) ?? ""
    check("allow is printed the way the agent expects it", allow.contains("\"hookEventName\":\"PermissionRequest\"") && allow.contains("\"behavior\":\"allow\""))
    check("deny too, with a reason", (HookOutput.permissionRequest(.deny) ?? "").contains("\"behavior\":\"deny\""))
    check("no answer prints nothing at all", HookOutput.permissionRequest(.none) == nil)

    let policy = ControlPolicy()
    check("reading may be allowed from here by default", policy.verdict(action: "Read", detail: "src/login.ts").approvable)
    check("running a command may not, and the reason is given", !policy.verdict(action: "Bash", detail: "ls").approvable && policy.verdict(action: "Bash", detail: "ls").reason != nil)
    check("nor editing", !policy.verdict(action: "Edit", detail: "a.txt").approvable && !policy.verdict(action: "Write", detail: "a.txt").approvable)
    check("what cannot be shown whole cannot be allowed", !policy.verdict(action: "Read", detail: String(repeating: "x", count: 200)).approvable)
    check("nor what runs over several lines", !policy.verdict(action: "Read", detail: "a\nb").approvable)
    let everything = ControlPolicy(approvable: ["Read", "Edit"], maxDetail: 400)
    check("even with editing allowed from here, an edit of several lines cannot be",
          !everything.verdict(action: "Edit", detail: edit?.detail ?? "").approvable && everything.verdict(action: "Edit", detail: "a.txt  ·  new_string: b  ·  old_string: a").approvable)
    check("text that reads backwards or hides characters cannot be allowed",
          !policy.verdict(action: "Read", detail: "src/\u{202E}txt.exe").approvable && !policy.verdict(action: "Read", detail: "src/a\u{200B}b").approvable
          && !policy.verdict(action: "Read", detail: "a\tb").approvable && policy.verdict(action: "Read", detail: "文档/说明 v2.md").approvable)
}

section("the hook in a settings file")
do {
    let command = "'/Applications/RenderDock.app/Contents/Helpers/renderdock' hook"
    func object(_ data: Data?) -> NSDictionary? { data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? NSDictionary } }
    let fresh = HookSettings.adding(command: command, to: nil)
    check("a file that does not exist yet gets just the hook", HookSettings.isInstalled(in: fresh) && object(fresh)?.count == 1)
    let existing = Data("{\"theme\":\"dark\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"say done\"}]}],\"PermissionRequest\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"mine.sh\"}]}]}}".utf8)
    let added = HookSettings.adding(command: command, to: existing)
    let hooks = object(added)?["hooks"] as? NSDictionary
    check("everything already there is kept", object(added)?["theme"] as? String == "dark" && (hooks?["Stop"] as? [Any])?.count == 1)
    check("the user's own permission hook stays, ours is added after it", (hooks?["PermissionRequest"] as? [Any])?.count == 2)
    check("adding it twice leaves one", ((object(HookSettings.adding(command: command, to: added))?["hooks"] as? NSDictionary)?["PermissionRequest"] as? [Any])?.count == 2)
    let removed = added.flatMap(HookSettings.removing(from:))
    check("taking it out leaves what was there, and nothing of ours", object(removed) == object(existing) && !HookSettings.isInstalled(in: removed))
    check("taking it out of a file that never had it changes nothing", HookSettings.removing(from: existing) == existing)
    check("our hook alone, taken out again, leaves an empty object", object(fresh.flatMap(HookSettings.removing(from:)))?.count == 0)
    check("a file that is not JSON is left alone", HookSettings.adding(command: command, to: Data("not json".utf8)) == nil && HookSettings.removing(from: Data("[1]".utf8)) == nil)
    let shared = Data("{\"hooks\":{\"PermissionRequest\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"mine.sh\"},{\"type\":\"command\",\"command\":\"'/x/renderdock' hook\"}]}]}}".utf8)
    let sharedOut = object(HookSettings.removing(from: shared))
    let leftGroup = (((sharedOut?["hooks"] as? NSDictionary)?["PermissionRequest"] as? [Any])?.first as? NSDictionary)
    check("a hook of the user's own in the same group as ours stays when ours is taken out",
          (leftGroup?["hooks"] as? [NSDictionary])?.map { $0["command"] as? String } == ["mine.sh"] && leftGroup?["matcher"] as? String == "*")
    let sharedAgain = object(HookSettings.adding(command: command, to: shared))
    let groupsAgain = (sharedAgain?["hooks"] as? NSDictionary)?["PermissionRequest"] as? [NSDictionary]
    check("…and when ours is put in again over itself",
          groupsAgain?.count == 2 && (groupsAgain?.first?["hooks"] as? [NSDictionary])?.map { $0["command"] as? String } == ["mine.sh"])
    let kept = HookSettings.keepsakes(for: URL(fileURLWithPath: "/tmp/project/.claude/settings.local.json"), paths: ControlPaths(directory: URL(fileURLWithPath: "/tmp/rd-control")))
    check("the copy of a settings file is kept in RenderDock's own directory, not beside the settings",
          kept.backup.path.hasPrefix("/tmp/rd-control/hook-backups/") && kept.created.path.hasPrefix("/tmp/rd-control/hook-backups/")
          && kept.backup != HookSettings.keepsakes(for: URL(fileURLWithPath: "/tmp/other/.claude/settings.local.json"), paths: ControlPaths(directory: URL(fileURLWithPath: "/tmp/rd-control"))).backup)
    check("someone else's hook that merely ends in 'hook' is not ours",
          !HookSettings.isInstalled(in: Data("{\"hooks\":{\"PermissionRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"my hook\"}]}]}}".utf8)))
}

section("asking and answering")
do {
    let fm = FileManager.default
    // A Unix socket path is limited to about a hundred bytes, so the directory name is kept short.
    let dir = fm.temporaryDirectory.appendingPathComponent("rdc-\(UUID().uuidString.prefix(8))")
    let paths = ControlPaths(directory: dir)
    let broker = ControlBroker(paths: paths)

    let started = Date()
    check("with nothing listening, the hook's question comes back at once and unanswered",
          ControlClient.ask(hookJSON: hookJSON("Read", "{\"file_path\":\"a.txt\"}"), paths: paths, timeout: 5) == .none && Date().timeIntervalSince(started) < 0.5)

    check("the broker starts", broker.start() && broker.isRunning)
    func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    check("its directory is the user's alone, and so are the socket and the token", mode(dir) == 0o700 && mode(paths.socket) == 0o600 && mode(paths.token) == 0o600)

    /// Asks in the background, the way the hook does, and hands back what it was told.
    func ask(_ json: Data, timeout: TimeInterval = 10) -> () -> ControlDecision {
        var result = ControlDecision.none
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = ControlClient.ask(hookJSON: json, paths: paths, timeout: timeout)
            done.signal()
        }
        return {
            _ = done.wait(timeout: .now() + timeout + 2)
            return result
        }
    }
    func waitFor(_ count: Int) -> [ControlRequest] {
        for _ in 0..<200 {
            let p = broker.pending
            if p.count == count { return p }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return broker.pending
    }

    var answer = ask(hookJSON("Read", "{\"file_path\":\"src/login.ts\"}"))
    var pending = waitFor(1)
    check("a request arrives with what it is about", pending.count == 1 && pending.first?.action == "Read" && pending.first?.detail == "src/login.ts" && pending.first?.project == "demo-site")
    check("it has a five-letter id and may be allowed here", pending.first?.id.count == 5 && pending.first?.approvable == true)
    check("an answer for a request that does not exist does nothing", !broker.decide(id: "zzzzz", .allow, source: "check"))
    check("allowing it", broker.decide(id: pending.first?.id ?? "", .allow, source: "check"))
    check("…reaches the one who asked", answer() == .allow)
    check("an answered request is gone, and cannot be answered twice", waitFor(0).isEmpty && !broker.decide(id: pending.first?.id ?? "", .deny, source: "check"))

    answer = ask(hookJSON("Bash", "{\"command\":\"rm -rf build\"}"))
    pending = waitFor(1)
    check("a command arrives marked as not allowable here", pending.first?.approvable == false && pending.first?.reason != nil)
    check("allowing it from here is refused", !broker.decide(id: pending.first?.id ?? "", .allow, source: "check") && broker.pending.count == 1)
    check("denying it works", broker.decide(id: pending.first?.id ?? "", .deny, source: "check") && answer() == .deny)

    answer = ask(hookJSON("Read", "{\"file_path\":\"b.txt\"}"), timeout: 0.4)
    _ = waitFor(1)
    check("when the asker gives up, it gets no answer", answer() == .none)
    check("…and its request is dropped here", waitFor(0).isEmpty)

    check("something that is not a permission request is not taken", { let a = ask(hookJSON("Read", "{\"file_path\":\"c.txt\"}", event: "PreToolUse"), timeout: 1); return a() == .none && broker.pending.isEmpty }())

    let token = try? String(contentsOf: paths.token, encoding: .utf8)
    try? "wrong".write(to: paths.token, atomically: true, encoding: .utf8)
    check("a caller with the wrong token is turned away", { let a = ask(hookJSON("Read", "{\"file_path\":\"d.txt\"}"), timeout: 1); return a() == .none && broker.pending.isEmpty }())
    try? (token ?? "").write(to: paths.token, atomically: true, encoding: .utf8)

    answer = ask(hookJSON("Read", "{\"file_path\":\"e.txt\"}"))
    _ = waitFor(1)
    broker.stop()
    check("stopping releases whoever is waiting, without an answer", answer() == .none && !broker.isRunning)
    check("…and takes the socket and the token away", !fm.fileExists(atPath: paths.socket.path) && !fm.fileExists(atPath: paths.token.path))

    let records = ControlBroker.auditRecords(paths: paths)
    check("every outcome is on record", records.compactMap { $0["decision"] as? String } == ["allow", "deny", "none", "none"])
    check("…with who decided and what it was about",
          records.first?["source"] as? String == "check" && records.first?["action"] as? String == "Read" && records.first?["detail"] as? String == "src/login.ts"
          && records.compactMap { $0["source"] as? String }.suffix(2) == ["gone", "stopped"])
    check("the record is the user's alone", mode(paths.audit) == 0o600)
    try? fm.removeItem(at: dir)
}

// MARK: The entry for other programs

section("notices, progress and questions from other programs")
do {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("rdi-\(UUID().uuidString.prefix(8))")
    let paths = InboxPaths(directory: dir)
    let server = InboxServer(paths: paths)

    let started = Date()
    check("with nothing listening, a notice is turned away at once",
          InboxClient.notify(title: "", body: "hello", from: "check", paths: paths) == .unavailable && Date().timeIntervalSince(started) < 0.5)
    check("…and so is a question", InboxClient.ask(text: "Go on?", choices: ["Yes", "No"], timeoutSec: 5, from: "check", paths: paths) == .unavailable)

    check("the entry starts", server.start() && server.isRunning)
    func mode(_ url: URL) -> Int { ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    check("its directory is the user's alone, and so are the socket and the token", mode(dir) == 0o700 && mode(paths.socket) == 0o600 && mode(paths.token) == 0o600)

    var arrivals: [String] = []
    server.onArrival = { notice, question in arrivals.append(notice?.title ?? question?.text ?? "?") }
    /// What the main queue was handed is only run when the main thread gives it the time.
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    // Notices
    check("a notice is taken", { if case .ok(let id) = InboxClient.notify(title: "Build", body: "All 42 tests passed", level: .done, from: "builder", paths: paths) { return id?.count == 5 }; return false }())
    var view = server.view
    check("…and kept with who sent it, what it says and how it went",
          view.notices.count == 1 && view.notices.first?.from == "builder" && view.notices.first?.title == "Build" && view.notices.first?.body == "All 42 tests passed"
          && view.notices.first?.level == .done)
    settle()
    check("…and announced once", arrivals == ["Build"])
    check("a notice with nothing in it is refused", InboxClient.notify(title: " ", body: "\n", from: "builder", paths: paths) == .refused("nothing to say"))
    _ = InboxClient.notify(title: String(repeating: "t", count: 90), body: "line one\nline two\u{07}" + String(repeating: "b", count: 300), from: String(repeating: "f", count: 60), paths: paths)
    view = server.view
    check("the newest notice comes first", view.notices.count == 2 && view.notices.last?.title == "Build")
    check("long text is cut, line breaks become spaces, and what cannot be seen is dropped",
          view.notices.first?.title.count == InboxLimits.title && view.notices.first?.body.count == InboxLimits.body
          && view.notices.first?.body.hasPrefix("line one line two" + "bbb") == true && view.notices.first?.from.count == InboxLimits.from)
    for i in 0..<12 { _ = InboxClient.notify(title: "n\(i)", body: "", from: "builder", paths: paths) }
    check("only the last few notices are kept", server.view.notices.count == InboxLimits.notices && server.view.notices.first?.title == "n11")
    server.dismissNotice(server.view.notices.first?.id ?? "")
    check("a notice can be dismissed", server.view.notices.count == InboxLimits.notices - 1 && server.view.notices.first?.title == "n10")
    var refusedAt: Int?
    for i in 0..<40 where refusedAt == nil {
        if InboxClient.notify(title: "flood \(i)", body: "", from: "builder", paths: paths) == .refused("too many notices") { refusedAt = i }
    }
    check("a flood of notices is stopped", refusedAt == InboxLimits.noticesPerMinute - 14)

    // Progress
    check("a task's progress is taken", InboxClient.progress(name: "import", title: "Import the catalogue", percent: 25, etaSec: 90, from: "importer", paths: paths) == .ok(id: nil))
    var task = server.view.tasks.first
    check("…with its title, how far along and how long is left", task?.title == "Import the catalogue" && task?.fraction == 0.25 && task?.etaSec == 90 && task?.state == "working" && task?.from == "importer")
    let began = task?.startedAt
    _ = InboxClient.progress(name: "import", title: nil, percent: 60, etaSec: nil, from: "importer", paths: paths)
    task = server.view.tasks.first
    check("a later report updates the same task: the title stays, the estimate goes when it is no longer given",
          server.view.tasks.count == 1 && task?.title == "Import the catalogue" && task?.fraction == 0.6 && task?.etaSec == nil && task?.startedAt == began)
    _ = InboxClient.progress(name: "import", title: nil, percent: nil, etaSec: nil, from: "someone else", paths: paths)
    check("the same name from another sender is another task", server.view.tasks.count == 2 && server.view.tasks.first?.fraction == nil)
    _ = InboxClient.progress(name: "import", title: nil, percent: 250, etaSec: nil, state: "done", from: "importer", paths: paths)
    check("done is done, whatever percentage came with it", server.view.tasks.first?.state == "done" && server.view.tasks.first?.fraction == 1)
    _ = InboxClient.progress(name: "import", title: nil, percent: 30, etaSec: 5, state: "failed", from: "someone else", paths: paths)
    check("failed is kept as an error, at the percentage it reached", server.view.tasks.first?.state == "error" && server.view.tasks.first?.fraction == 0.3 && server.view.tasks.first?.etaSec == nil)
    check("a task needs a name", InboxClient.progress(name: " ", title: "x", percent: 1, etaSec: nil, from: "importer", paths: paths) == .refused("a task needs a name"))
    for i in 0..<10 { _ = InboxClient.progress(name: "t\(i)", title: nil, percent: 1, etaSec: nil, from: "importer", paths: paths) }
    check("there is room for only so many tasks", server.view.tasks.count == InboxLimits.tasks
          && InboxClient.progress(name: "one more", title: nil, percent: 1, etaSec: nil, from: "importer", paths: paths) == .refused("too many tasks"))
    server.dismissTask("importer/t0")
    check("a task can be taken off the list", server.view.tasks.count == InboxLimits.tasks - 1)

    // Questions
    func ask(_ text: String, _ choices: [String], timeout: Int = 10) -> () -> InboxClient.Answer {
        var result = InboxClient.Answer.unavailable
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = InboxClient.ask(text: text, choices: choices, timeoutSec: timeout, from: "planner", paths: paths)
            done.signal()
        }
        return {
            _ = done.wait(timeout: .now() + .seconds(timeout + 7))
            return result
        }
    }
    func waitFor(_ count: Int) -> [InboxQuestion] {
        for _ in 0..<300 {
            let q = server.view.questions
            if q.count == count { return q }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return server.view.questions
    }
    settle()   // the notices above have all been announced by now
    arrivals = []
    var answer = ask("Which branch should the fix go on?", ["main", "release", "a new one"])
    var questions = waitFor(1)
    check("a question arrives whole, with its answers in order",
          questions.first?.text == "Which branch should the fix go on?" && questions.first?.choices == ["main", "release", "a new one"] && questions.first?.from == "planner"
          && questions.first?.id.count == 5)
    settle()
    check("…and is announced", arrivals == ["Which branch should the fix go on?"])
    check("an answer that is not one of them does nothing", !server.answer(id: questions.first?.id ?? "", index: 3) && !server.answer(id: "zzzzz", index: 0) && server.view.questions.count == 1)
    check("picking one", server.answer(id: questions.first?.id ?? "", index: 1))
    check("…reaches the one who asked, as its number and its words", answer() == .chosen(index: 1, label: "release"))
    check("an answered question is gone, and cannot be answered twice", waitFor(0).isEmpty && !server.answer(id: questions.first?.id ?? "", index: 0))

    answer = ask("Keep going?", ["Yes", "No"])
    questions = waitFor(1)
    server.dismissQuestion(questions.first?.id ?? "")
    check("a dismissed question comes back as no answer", answer() == .none("dismissed") && waitFor(0).isEmpty)

    let quick = Date()
    answer = ask("Still there?", ["Yes", "No"], timeout: 5)
    _ = waitFor(1)
    check("with nobody answering, the question runs out", answer() == .none("timeout") && abs(Date().timeIntervalSince(quick) - 5) < 1.5 && waitFor(0).isEmpty)

    check("a question with one answer, or five, or two the same, is refused",
          ask("Go?", ["Yes"])() == .refused("a question needs two to four answers") && ask("Go?", ["a", "b", "c", "d", "e"])() == .refused("a question needs two to four answers")
          && ask("Go?", ["Yes", "Yes"])() == .refused("two answers are the same"))
    check("a question too long to show is refused, not cut short",
          ask(String(repeating: "q", count: InboxLimits.question + 1), ["Yes", "No"])() == .refused("the question is too long (\(InboxLimits.question) characters at most)")
          && { if case .refused = ask("Go?", ["Yes", String(repeating: "n", count: InboxLimits.choice + 1)])() { return true }; return false }())
    check("…while one exactly at the limit is taken", { let a = ask(String(repeating: "q", count: InboxLimits.question), [String(repeating: "y", count: InboxLimits.choice), "No"])
        let q = waitFor(1); server.answer(id: q.first?.id ?? "", index: 0); return a() == .chosen(index: 0, label: String(repeating: "y", count: InboxLimits.choice)) }())

    let pending = (0..<InboxLimits.questions).map { ask("Question \($0)?", ["Yes", "No"]) }
    questions = waitFor(InboxLimits.questions)
    check("only so many questions wait at once", questions.count == InboxLimits.questions && ask("One more?", ["Yes", "No"])() == .refused("too many questions waiting"))
    check("the oldest is first", questions.map(\.text).sorted() == questions.map(\.text) || questions.first?.askedAt ?? .distantFuture <= questions.last?.askedAt ?? .distantPast)

    let token = try? String(contentsOf: paths.token, encoding: .utf8)
    try? "wrong".write(to: paths.token, atomically: true, encoding: .utf8)
    check("a caller with the wrong token is turned away", InboxClient.notify(title: "x", body: "y", from: "check", paths: paths) == .unavailable)
    try? (token ?? "").write(to: paths.token, atomically: true, encoding: .utf8)

    server.stop()
    check("stopping tells everyone who is waiting that there will be no answer", pending.allSatisfy { $0() == .none("stopped") } && !server.isRunning)
    check("…forgets everything", server.view.isEmpty)
    check("…and takes the socket and the token away", !fm.fileExists(atPath: paths.socket.path) && !fm.fileExists(atPath: paths.token.path))
    check("nothing else was left in its directory", ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["?"]).isEmpty)
    try? fm.removeItem(at: dir)

    do {
        // A caller that connects and then says nothing must not hold everything else up.
        let dir2 = fm.temporaryDirectory.appendingPathComponent("rdj-\(UUID().uuidString.prefix(8))")
        let paths2 = InboxPaths(directory: dir2)
        let server2 = InboxServer(paths: paths2)
        server2.start()
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: paths2.socket.path.utf8) }
        let silent = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(silent, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        _ = "{\"op\":".withCString { write(silent, $0, 6) }
        let began = Date()
        let sent = InboxClient.notify(title: "after the silent one", body: "", from: "check", paths: paths2)
        check("a caller that connects and says nothing holds the entry up for about a second, no longer",
              sent != .unavailable && Date().timeIntervalSince(began) < 2.5 && server2.view.notices.first?.title == "after the silent one")
        close(silent)

        var refused: InboxClient.Answer?
        for i in 0...InboxLimits.questionsPerMinute {
            var result = InboxClient.Answer.unavailable
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                result = InboxClient.ask(text: "Question \(i)?", choices: ["Yes", "No"], timeoutSec: 5, from: "check", paths: paths2)
                done.signal()
            }
            for _ in 0..<200 where server2.view.questions.isEmpty && done.wait(timeout: .now() + 0.01) == .timedOut {}
            if let q = server2.view.questions.first { server2.dismissQuestion(q.id) }
            _ = done.wait(timeout: .now() + 3)
            if i == InboxLimits.questionsPerMinute { refused = result }
        }
        check("more questions in a minute than a person could answer are refused", refused == .refused("too many questions"))
        server2.stop()
        try? fm.removeItem(at: dir2)
    }

    check("text is made one line", InboxLimits.oneLine("  a\n\n b\tc \u{1B}[31m ") == "a b c [31m")
    check("the rules for a question", InboxLimits.problem(question: "Go?", choices: ["Yes", "No"]) == nil && InboxLimits.problem(question: "", choices: ["Yes", "No"]) == "nothing asked"
          && InboxLimits.problem(question: "Go?", choices: ["Yes", ""]) == "an answer is empty")
}

section("the commands other programs run")
do {
    // The command-line tool itself, run as another program would run it, against an entry started here.
    let fm = FileManager.default
    let tool = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent().appendingPathComponent("renderdock-cli")
    if fm.isExecutableFile(atPath: tool.path) {
        let dir = fm.temporaryDirectory.appendingPathComponent("rdx-\(UUID().uuidString.prefix(8))")
        let server = InboxServer(paths: InboxPaths(directory: dir))
        struct Ran { var code: Int32; var out: String; var err: String }
        func start(_ arguments: [String], environment extra: [String: String] = [:]) -> () -> Ran {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["RENDERDOCK_INBOX"] = dir.path
            environment["RENDERDOCK_FROM"] = nil
            extra.forEach { environment[$0.key] = $0.value }
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try? process.run()
            return {
                let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return Ran(code: process.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
            }
        }
        func run(_ arguments: String..., environment: [String: String] = [:]) -> Ran { start(arguments, environment: environment)() }
        func waitFor(_ count: Int) -> [InboxQuestion] {
            for _ in 0..<300 {
                let q = server.view.questions
                if q.count == count { return q }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return server.view.questions
        }

        var ran = run("notify", "hello")
        check("with the entry off, notify says so and exits 3", ran.code == 3 && ran.out.isEmpty && ran.err.contains("not taking this"))
        ran = run("ask", "Go on?", "--choice", "Yes", "--choice", "No")
        check("…and so does ask, without waiting", ran.code == 3 && ran.out.isEmpty)

        server.start()
        ran = run("notify", "All 42 tests passed", "--title", "Build", "--level", "done", "--from", "builder")
        check("notify: quiet, exit 0, and the notice is there", ran.code == 0 && ran.out.isEmpty && ran.err.isEmpty
              && server.view.notices.first?.title == "Build" && server.view.notices.first?.body == "All 42 tests passed" && server.view.notices.first?.level == .done
              && server.view.notices.first?.from == "builder")
        ran = run("notify", "several", "words", "--", "--and dashes", environment: ["RENDERDOCK_FROM": "from the environment"])
        check("notify: words are joined, text after -- may start with dashes, the sender may come from the environment",
              ran.code == 0 && server.view.notices.first?.body == "several words --and dashes" && server.view.notices.first?.from == "from the environment")
        check("notify: nothing to say, an unknown level and an unknown option are usage errors",
              run("notify").code == 64 && run("notify", "x", "--level", "loud").code == 64 && run("notify", "x", "--colour", "red").code == 64 && run("notify", "x", "--title").code == 64)

        ran = run("progress", "import", "--title", "Import the catalogue", "--percent", "40", "--eta", "30", "--from", "importer")
        check("progress: quiet, exit 0, and the task is there", ran.code == 0 && ran.out.isEmpty && server.view.tasks.first?.title == "Import the catalogue"
              && server.view.tasks.first?.fraction == 0.4 && server.view.tasks.first?.etaSec == 30)
        check("progress --done finishes it", run("progress", "import", "--done", "--from", "importer").code == 0 && server.view.tasks.count == 1 && server.view.tasks.first?.state == "done")
        check("progress --failed marks another as failed", run("progress", "export", "--failed", "--from", "importer").code == 0 && server.view.tasks.first?.state == "error")
        check("progress: no name, two names, a percentage out of range, done and failed together are usage errors",
              run("progress").code == 64 && run("progress", "a", "b").code == 64 && run("progress", "a", "--percent", "140").code == 64
              && run("progress", "a", "--eta", "soon").code == 64 && run("progress", "a", "--done", "--failed").code == 64)

        var asked = start(["ask", "Which branch should the fix go on?", "--choice", "main", "--choice", "release", "--from", "planner"])
        var questions = waitFor(1)
        check("ask: the question arrives", questions.first?.text == "Which branch should the fix go on?" && questions.first?.choices == ["main", "release"] && questions.first?.from == "planner")
        server.answer(id: questions.first?.id ?? "", index: 1)
        ran = asked()
        check("ask: prints the answer that was picked, and nothing else", ran.code == 0 && ran.out == "release\n" && ran.err.isEmpty)

        asked = start(["ask", "Keep going?", "--choice", "Yes", "--choice", "No", "--json"])
        questions = waitFor(1)
        server.answer(id: questions.first?.id ?? "", index: 0)
        ran = asked()
        check("ask --json: the answer's number and its words", ran.code == 0 && ran.out == "{\"choice\":\"Yes\",\"index\":0}\n")

        asked = start(["ask", "Keep going?", "--choice", "Yes", "--choice", "No"])
        questions = waitFor(1)
        server.dismissQuestion(questions.first?.id ?? "")
        ran = asked()
        check("ask: no answer is exit 2, with nothing printed", ran.code == 2 && ran.out.isEmpty && ran.err.contains("no answer"))

        let began = Date()
        ran = run("ask", "Still there?", "--choice", "Yes", "--choice", "No", "--timeout", "5")
        check("ask --timeout: gives up after that long", ran.code == 2 && abs(Date().timeIntervalSince(began) - 5) < 1.5)

        check("ask: one answer, a fifth answer, no question, a timeout out of range are usage errors, and nothing is asked",
              run("ask", "Go?", "--choice", "Yes").code == 64 && run("ask", "Go?", "--choice", "a", "--choice", "b", "--choice", "c", "--choice", "d", "--choice", "e").code == 64
              && run("ask", "--choice", "Yes", "--choice", "No").code == 64 && run("ask", "Go?", "--choice", "Yes", "--choice", "No", "--timeout", "1").code == 64
              && server.view.questions.isEmpty)
        ran = run("ask", String(repeating: "q", count: InboxLimits.question + 1), "--choice", "Yes", "--choice", "No")
        check("ask: a question too long is refused before it is sent, with the reason", ran.code == 64 && ran.err.contains("too long"))

        asked = start(["ask", "Keep going?", "--choice", "Yes", "--choice", "No"])
        _ = waitFor(1)
        server.stop()
        check("ask: the app going away is no answer", asked().code == 2)
        try? fm.removeItem(at: dir)
    } else {
        print("  (renderdock-cli is not built next to the checks: skipped)")
    }
}

// MARK: A device on the desk

section("what a device is sent")
do {
    func agent(_ id: String, _ state: AgentState, project: String = "demo-site", waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: "claude-code:\(id)", tool: "claude-code", project: project, title: "A private title", state: state,
                     waitingFor: waitingFor, since: agentNow.addingTimeInterval(-20), source: "official")
    }
    func request(_ id: String, _ action: String, _ detail: String, approvable: Bool = true) -> ControlRequest {
        ControlRequest(id: id, tool: "claude-code", sessionId: "s", project: "demo-site", action: action, detail: detail, fingerprint: "f",
                       receivedAt: agentNow, expiresAt: agentNow.addingTimeInterval(100), approvable: approvable)
    }
    let state = StateSnapshot.make(groups: [groupA], metrics: Metrics(),
                                   agents: [agent("a", .working), agent("b", .waiting, project: "docs", waitingFor: "permission prompt"), agent("c", .idle)],
                                   now: agentNow, host: "Test Mac")
    let secure = BuddyProtocol.Options(secure: true)
    let plain = BuddyProtocol.heartbeat(state: state, requests: [], options: secure)
    check("counts: every session and job, what is running, what is waiting", plain.total == 4 && plain.running == 2 && plain.waiting == 1)
    check("the message is the one-line summary", plain.msg == "1 waiting | render 50%" && plain.msg.count <= BuddyProtocol.Limit.msg)
    check("no request, no prompt", plain.prompt == nil)
    check("the lines name what is going on, never an idle session",
          plain.entries.contains("Claude Code docs: waiting (permission prompt)") && plain.entries.contains("s2: rendering 50% ~37m left")
          && !plain.entries.contains { $0.contains("idle") })
    check("no session title is sent", !String(decoding: plain.line(), as: UTF8.self).contains("A private title"))
    check("a snapshot is one line of JSON", plain.line().last == 0x0A && plain.line().dropLast().firstIndex(of: 0x0A) == nil)
    let decoded = (try? JSONSerialization.jsonObject(with: plain.line())) as? [String: Any]
    check("…with the fields a device expects", decoded?["total"] as? Int == 4 && decoded?["tokens"] as? Int == 0 && decoded?["prompt"] == nil
          && (decoded?["entries"] as? [String])?.count == plain.entries.count)

    let read = request("kqmtv", "Read", "src/login.ts")
    let asked = BuddyProtocol.heartbeat(state: state, requests: [read], options: secure)
    check("a request that may be allowed is offered on the device", asked.prompt == BuddyProtocol.Prompt(id: "kqmtv", tool: "Read", hint: "src/login.ts"))
    check("…and the message says what to approve", asked.msg == "approve: Read")
    let promptJSON = ((try? JSONSerialization.jsonObject(with: asked.line())) as? [String: Any])?["prompt"] as? [String: String]
    check("…in the protocol's own shape", promptJSON == ["id": "kqmtv", "tool": "Read", "hint": "src/login.ts"])

    let bash = request("hbxwe", "Bash", "rm -rf build", approvable: false)
    let refused = BuddyProtocol.heartbeat(state: state, requests: [bash], options: secure)
    check("a request that may not be allowed from a display is never offered on the device", refused.prompt == nil)
    check("…but the device still says something is waiting on the Mac", refused.entries.first == "Bash demo-site: answer on the Mac")
    let long = request("abcde", "Read", String(repeating: "x", count: 44))
    check("what the device cannot show whole is not offered", BuddyProtocol.heartbeat(state: state, requests: [long], options: secure).prompt == nil)
    let chinese = request("abcde", "Read", "文档/说明.md")
    check("nor text the device cannot draw", BuddyProtocol.prompt(for: chinese, options: secure) == nil)
    check("…unless the device can draw it", BuddyProtocol.prompt(for: chinese, options: BuddyProtocol.Options(secure: true, unicode: true))?.hint == "文档/说明.md")
    check("the first request that can be offered is the one offered", BuddyProtocol.heartbeat(state: state, requests: [bash, read], options: secure).prompt?.id == "kqmtv")
    let wide = request("abcde", "Read", "文档/这个文件夹的名字比较长/说明.md")   // 19 characters, 47 bytes
    check("a plain device's limit is a size in bytes: text that is short in characters may still not fit",
          BuddyProtocol.prompt(for: wide, options: BuddyProtocol.Options(secure: true, unicode: true)) == nil
          && BuddyProtocol.prompt(for: wide, options: BuddyProtocol.Options(secure: true, unicode: true, extended: true)) != nil)
    check("…and its lines are cut by bytes too, between characters",
          BuddyProtocol.fit(String(repeating: "渲", count: 40), 91, unicode: true, bytes: true).utf8.count <= 91
          && BuddyProtocol.fit(String(repeating: "渲", count: 40), 91, unicode: true, bytes: true).hasSuffix("…")
          && BuddyProtocol.fit("short", 91, unicode: true, bytes: true) == "short")
    let lookOnly = BuddyProtocol.heartbeat(state: state, requests: [read], options: BuddyProtocol.Options(secure: true, offerRequests: false))
    check("with answering on the device switched off, a request is never offered there: the device only hears that it waits on the Mac",
          lookOnly.prompt == nil && lookOnly.entries.first == "Read demo-site: answer on the Mac" && !String(decoding: lookOnly.line(), as: UTF8.self).contains("login.ts"))

    let open = BuddyProtocol.heartbeat(state: state, requests: [read], options: BuddyProtocol.Options(secure: false))
    check("on a link that is not encrypted, only counts go out: no names, no request", open.entries.isEmpty && open.prompt == nil && open.total == 4 && open.msg == "1 waiting | render 50%")

    check("text is cut to the limit", BuddyProtocol.fit(String(repeating: "a", count: 30), 23, unicode: false).count == 23)
    check("what a plain device cannot draw becomes one question mark", BuddyProtocol.fit("渲染 final", 40, unicode: false) == "? final")
    check("a device that can draw it gets it as it is", BuddyProtocol.fit("渲染 final", 40, unicode: true) == "渲染 final")
    let crowded = StateSnapshot.make(groups: [], metrics: Metrics(), agents: (0..<20).map { agent("w\($0)", .working, project: String(repeating: "p", count: 120)) }, now: agentNow, host: "Test Mac")
    let many = BuddyProtocol.heartbeat(state: crowded, requests: [], options: secure)
    check("at most eight lines, none longer than the device has room for", many.entries.count == 8 && many.entries.allSatisfy { $0.count <= BuddyProtocol.Limit.entry })

    let sync = String(decoding: BuddyProtocol.timeSync(now: Date(timeIntervalSince1970: 1_800_000_000), zone: TimeZone(secondsFromGMT: 28_800)!), as: UTF8.self)
    check("the time is sent with the zone's offset", sync == "{\"time\":[1800000000,28800]}\n")
    check("a long line is cut into writes of the size the link allows",
          BuddyProtocol.chunks(Data(repeating: 1, count: 50), size: 20).map(\.count) == [20, 20, 10] && BuddyProtocol.chunks(Data(), size: 20).isEmpty)

    // A device with a page for the renders and one for the agents is told about each side by itself.
    check("the summary says how each side is doing: a render going, a session waiting",
          state.summary.renderSide?.state == "working" && state.summary.renderSide?.top?.name == "s2" && state.summary.renderSide?.top?.kind == "render"
          && state.summary.agentSide?.state == "waiting" && state.summary.agentSide?.top?.name == "docs" && state.summary.state == "waiting")
    let paged = BuddyProtocol.heartbeat(state: state, requests: [], options: BuddyProtocol.Options(secure: true, unicode: true, extended: true, pages: true))
    let renders = paged.extended?.renders, sessions = paged.extended?.sessions
    check("the renders' side: its state, the shot furthest along with its percentage, how many are going",
          renders?.state == "working" && renders?.topName == "s2" && renders?.topPercent == 50 && renders?.topKind == nil && renders?.rendering == 1)
    check("…its job, and no session among its rows",
          renders?.jobTitle != nil && renders?.jobDone == 1 && renders?.jobTotal == 3 && renders?.rows.map(\.name) == ["s2"] && renders?.rows.allSatisfy { $0.tool.isEmpty } == true)
    check("the agents' side: its state, who waits and for what, how long, and no render among its rows",
          sessions?.state == "waiting" && sessions?.topKind == "agent" && sessions?.topName == "docs" && sessions?.topTool == "Claude Code"
          && sessions?.topWait == "permission prompt" && sessions?.topAgeSec == 20 && sessions?.rows.isEmpty == false
          && sessions?.rows.allSatisfy { !$0.tool.isEmpty } == true)
    check("the one list is left out then (each side has its own); the two together are still said",
          paged.extended?.rows.isEmpty == true && paged.extended?.state == "waiting" && paged.extended?.topName == "docs")
    let pagedLine = String(decoding: paged.line(), as: UTF8.self)
    check("on the wire: \"r\" and \"a\" under \"rd\"", pagedLine.contains("\"r\":{") && pagedLine.contains("\"a\":{") && pagedLine.contains("\"n\":{\"queue\":"))
    let unpaged = BuddyProtocol.heartbeat(state: state, requests: [], options: BuddyProtocol.Options(secure: true, unicode: true, extended: true))
    check("a device without pages gets neither side, and the one list as before",
          unpaged.extended?.renders == nil && unpaged.extended?.sessions == nil && unpaged.extended?.rows.isEmpty == false
          && !String(decoding: unpaged.line(), as: UTF8.self).contains("\"r\":{"))
    let quiet = StateSnapshot.make(groups: [], metrics: Metrics(), agents: [agent("c", .idle)], now: agentNow, host: "Test Mac")
    let quietPaged = BuddyProtocol.heartbeat(state: quiet, requests: [], options: BuddyProtocol.Options(secure: true, extended: true, pages: true))
    check("nothing going on: both sides idle, with no top and no rows",
          quietPaged.extended?.renders?.state == "idle" && quietPaged.extended?.renders?.topName == nil && quietPaged.extended?.renders?.rows.isEmpty == true
          && quietPaged.extended?.sessions?.state == "idle" && quietPaged.extended?.sessions?.rows.isEmpty == true)
    check("a link that is not encrypted gets neither side", BuddyProtocol.heartbeat(state: state, requests: [], options: BuddyProtocol.Options(secure: false, extended: true, pages: true)).extended == nil)

    // The computer about itself.
    var machine = Metrics()
    machine.cpu = 0.368
    machine.gpu = 0.92
    machine.gpuMemBytes = 8_804_682_957        // 8.2 GB
    machine.memUsed = 22_978_150_810           // 21.4 GB
    machine.memTotal = 34_359_738_368          // 32 GB
    machine.memPressure = 2
    machine.swapUsed = 1_288_490_189           // 1.2 GB
    machine.tempC = 70.6
    machine.tempMaxC = 78.2
    machine.thermal = .serious
    machine.diskFree = 228_170_137_600         // 212.5 GB
    machine.onAC = true
    machine.awakeHeld = true
    let macLine = String(decoding: BuddyProtocol.mac(machine, cores: 10), as: UTF8.self)
    check("this Mac in one line: whole percentages and degrees, sizes in tenths of a gigabyte",
          macLine == "{\"mac\":{\"ac\":true,\"awake\":true,\"cores\":10,\"cpu\":37,\"disk\":212,\"gpu\":92,\"mem\":[21.4,32],\"mp\":2,\"swap\":1.2,\"t\":71,\"th\":2,\"tmax\":78,\"vram\":8.2}}\n")
    var bare = Metrics()
    bare.cpu = 0.04
    bare.memUsed = 10_200_547_328
    bare.memTotal = 17_179_869_184
    let bareLine = String(decoding: BuddyProtocol.mac(bare, cores: 8), as: UTF8.self)
    check("what could not be read is left out, not sent as nought", !bareLine.contains("gpu") && !bareLine.contains("\"t\"") && !bareLine.contains("disk") && !bareLine.contains("bat") && !bareLine.contains("\"ac\""))
    var jitter = machine
    jitter.cpu = 0.3712
    jitter.memUsed += 20_000_000
    check("numbers that would show the same make the same line (so it is not sent again)", BuddyProtocol.mac(jitter, cores: 10) == BuddyProtocol.mac(machine, cores: 10))
    let handed = (try? JSONSerialization.jsonObject(with: BuddyProtocol.wifi(ssid: "Studio 5G", password: "p\"w \\d", host: "studio-mac.local", ip: "192.168.1.20", port: 47600, token: "tok"))) as? [String: Any]
    check("the Wi-Fi settings go as one command, with every piece as it was given (quotes and all)",
          handed?["cmd"] as? String == "wifi" && handed?["ssid"] as? String == "Studio 5G" && handed?["pass"] as? String == "p\"w \\d"
          && handed?["host"] as? String == "studio-mac.local" && handed?["ip"] as? String == "192.168.1.20" && handed?["port"] as? Int == 47600 && handed?["token"] as? String == "tok"
          && BuddyProtocol.wifi(ssid: "a", password: "b", host: "c", ip: "d", port: 1, token: "e").last == 0x0A)
    let placed = (try? JSONSerialization.jsonObject(with: BuddyProtocol.wifiPlace(host: "studio-mac.local", ip: "192.168.1.21", port: 47601, token: "new"))) as? [String: Any]
    check("telling a device where the Mac is now carries no network name and no password",
          placed?["cmd"] as? String == "wifi" && placed?["ssid"] == nil && placed?["pass"] == nil && placed?["off"] == nil
          && placed?["host"] as? String == "studio-mac.local" && placed?["ip"] as? String == "192.168.1.21" && placed?["port"] as? Int == 47601 && placed?["token"] as? String == "new")
    check("asking a device which networks it sees is one short line", String(decoding: BuddyProtocol.wifiScan, as: UTF8.self) == "{\"cmd\":\"wifi\",\"scan\":true}\n")
    check("what it sees comes back as names in its order, each once, with strength and whether a password is asked", {
        let line = "{\"ack\":\"wifi\",\"ok\":true,\"nets\":[{\"n\":\"Studio-2.4G\",\"r\":-48,\"o\":false},{\"n\":\"隔壁\",\"r\":-80,\"o\":true},{\"n\":\"Studio-2.4G\",\"r\":-70},{\"n\":\"\"},{\"r\":-50},{\"n\":7},{\"n\":\"\(String(repeating: "x", count: 33))\"},{\"n\":\"bare\"}]}"
        guard case .networks(let list) = BuddyProtocol.parse(Data(line.utf8)) else { return false }
        return list == [.init(name: "Studio-2.4G", signal: -48, open: false), .init(name: "隔壁", signal: -80, open: true), .init(name: "bare", signal: nil, open: false)]
    }())
    check("a device that found nothing says so with an empty list, and one that could not look is not a list", {
        guard case .networks(let none) = BuddyProtocol.parse(Data("{\"ack\":\"wifi\",\"ok\":true,\"nets\":[]}".utf8)) else { return false }
        return none.isEmpty && BuddyProtocol.parse(Data("{\"ack\":\"wifi\",\"ok\":false,\"nets\":[]}".utf8)) == .ack("wifi", ok: false)
            && BuddyProtocol.parse(Data("{\"ack\":\"wifi\",\"ok\":true}".utf8)) == .ack("wifi", ok: true)
    }())
    check("forgetting them is one short line", String(decoding: BuddyProtocol.wifiOff, as: UTF8.self) == "{\"cmd\":\"wifi\",\"off\":true}\n")
    check("a device says how its Wi-Fi is doing, or nothing if it has none", {
        guard case .status(let withWiFi) = BuddyProtocol.parse(Data("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":3,\"wifi\":3}}".utf8)),
              case .status(let without) = BuddyProtocol.parse(Data("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":3}}".utf8)) else { return false }
        return withWiFi.wifi == 3 && without.wifi == nil
    }())
    check("a device says it has pages with \"rd\" 3, and not with 2",
          BuddyProtocol.parse(Data("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":3,\"utf8\":true}}".utf8))
          == .status(BuddyProtocol.DeviceStatus(name: nil, secure: true, batteryPercent: nil, onUSB: nil, extended: true, unicode: true, inbox: true, pages: true))
          && BuddyProtocol.parse(Data("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":2,\"utf8\":true}}".utf8))
          == .status(BuddyProtocol.DeviceStatus(name: nil, secure: true, batteryPercent: nil, onUSB: nil, extended: true, unicode: true, inbox: true)))
}

section("a connection the device refuses")
do {
    check("the peer removed its pairing: CBErrorDomain 14", BuddyProtocol.pairingGone(domain: "CBErrorDomain", code: 14))
    check("no other Bluetooth error is taken for it",
          !BuddyProtocol.pairingGone(domain: "CBErrorDomain", code: 6) && !BuddyProtocol.pairingGone(domain: "CBErrorDomain", code: 7)
          && !BuddyProtocol.pairingGone(domain: "CBErrorDomain", code: 15))
    check("nor the same number from somewhere else, nor no error at all",
          !BuddyProtocol.pairingGone(domain: "CBATTErrorDomain", code: 14) && !BuddyProtocol.pairingGone(domain: nil, code: nil)
          && !BuddyProtocol.pairingGone(domain: "CBErrorDomain", code: nil))
    check("while it lasts the tries are far apart, yet come round within the half minute macOS needs",
          BuddyProtocol.retryWhilePairingGone >= 10 && BuddyProtocol.retryWhilePairingGone <= 30)
}

section("what a device sends back")
do {
    func parse(_ text: String) -> BuddyProtocol.Incoming { BuddyProtocol.parse(Data(text.utf8)) }
    check("'once' allows", parse("{\"cmd\":\"permission\",\"id\":\"kqmtv\",\"decision\":\"once\"}") == .permission(id: "kqmtv", decision: .allow))
    check("'deny' denies", parse("{\"cmd\":\"permission\",\"id\":\"kqmtv\",\"decision\":\"deny\"}") == .permission(id: "kqmtv", decision: .deny))
    check("anything else is not an answer", parse("{\"cmd\":\"permission\",\"id\":\"kqmtv\",\"decision\":\"always\"}") == .unknown
          && parse("{\"cmd\":\"permission\",\"decision\":\"once\"}") == .unknown && parse("not json") == .unknown)
    check("the device's status: name, encrypted or not, battery",
          parse("{\"ack\":\"status\",\"ok\":true,\"data\":{\"name\":\"Clawd\",\"sec\":true,\"bat\":{\"pct\":87,\"usb\":true}}}")
          == .status(BuddyProtocol.DeviceStatus(name: "Clawd", secure: true, batteryPercent: 87, onUSB: true)))
    check("a status without the encryption flag is not encrypted", parse("{\"ack\":\"status\",\"ok\":true,\"data\":{}}") == .status(BuddyProtocol.DeviceStatus(name: nil, secure: false, batteryPercent: nil, onUSB: nil)))
    check("other acknowledgements pass through", parse("{\"ack\":\"owner\",\"ok\":true}") == .ack("owner", ok: true))

    var assembler = BuddyProtocol.LineAssembler(limit: 64)
    check("half a line is not a line", assembler.feed(Data("{\"cmd\":\"permi".utf8)).isEmpty)
    let rest = assembler.feed(Data("ssion\",\"id\":\"a\",\"decision\":\"once\"}\n{\"ack\":\"name\",\"ok\":true}\n{\"a".utf8))
    check("pieces are put back together, and two lines in one piece come out as two", rest.count == 2 && BuddyProtocol.parse(rest[0]) == .permission(id: "a", decision: .allow))
    check("a line that never ends is thrown away", assembler.feed(Data(repeating: 0x41, count: 200)).isEmpty && assembler.feed(Data("\n".utf8)).isEmpty)
}

section("the extra fields for RenderDock's own firmware")
do {
    func agent(_ id: String, _ state: AgentState, project: String, waitingFor: String? = nil) -> AgentSession {
        AgentSession(id: "claude-code:\(id)", tool: "claude-code", project: project, title: "A private title", state: state,
                     waitingFor: waitingFor, since: agentNow.addingTimeInterval(-20), source: "official")
    }
    let state = StateSnapshot.make(groups: [groupA], metrics: Metrics(),
                                   agents: [agent("a", .working, project: "billing-api"), agent("b", .done, project: "docs"), agent("c", .idle, project: "notes")],
                                   now: agentNow, host: "Test Mac")
    let plainDevice = BuddyProtocol.heartbeat(state: state, requests: [], options: BuddyProtocol.Options(secure: true), now: agentNow)
    check("a device that did not ask gets none of them", plainDevice.extended == nil && !String(decoding: plainDevice.line(), as: UTF8.self).contains("\"rd\""))
    let ours = BuddyProtocol.Options(secure: true, unicode: true, extended: true)
    let hb = BuddyProtocol.heartbeat(state: state, requests: [], options: ours, now: agentNow)
    let e = hb.extended
    check("a device that asked gets the overall state and the top item with its percentage",
          e?.state == "working" && e?.topKind == "render" && e?.topName == "s2" && e?.topPercent == 50 && e?.topExact == true && e?.topEtaSec == 2250)
    check("…the job the shot belongs to", e?.jobTitle == "Job a" && e?.jobDone == 1 && e?.jobTotal == 3)
    check("…and a list: renders, then sessions working, then what just finished, never the idle",
          e?.rows.map(\.name) == ["s2", "billing-api", "docs"] && e?.rows.map(\.state) == ["working", "working", "done"] && e?.rows.first?.percent == 50)
    check("a session's row has the tool's name and its age", e?.rows[1].tool == "Claude Code" && e?.rows[1].ageSec == 20)
    let rd = ((try? JSONSerialization.jsonObject(with: hb.line())) as? [String: Any])?["rd"] as? [String: Any]
    check("on the wire they sit under one extra key", rd?["state"] as? String == "working" && (rd?["top"] as? [String: Any])?["pct"] as? Int == 50
          && (rd?["rows"] as? [[String: Any]])?.count == 3 && ((rd?["agents"] as? [String: Any])?["working"] as? Int) == 1)
    check("still no session title anywhere", !String(decoding: hb.line(), as: UTF8.self).contains("A private title"))
    check("not on an unencrypted link, whatever the device says",
          BuddyProtocol.heartbeat(state: state, requests: [], options: BuddyProtocol.Options(secure: false, unicode: true, extended: true), now: agentNow).extended == nil)

    let request = ControlRequest(id: "kqmtv", tool: "claude-code", sessionId: "s", project: "docs", action: "Read",
                                 detail: "src/features/authentication/redirect-after-login.ts", fingerprint: "f",
                                 receivedAt: agentNow, expiresAt: agentNow.addingTimeInterval(96), approvable: true)
    check("its own firmware has room for a longer request than the reference one",
          BuddyProtocol.prompt(for: request, options: ours) != nil && BuddyProtocol.prompt(for: request, options: BuddyProtocol.Options(secure: true)) == nil)
    check("…and is told how long is left to answer", BuddyProtocol.heartbeat(state: state, requests: [request], options: ours, now: agentNow).extended?.promptLeftSec == 96)
    let asked = BuddyProtocol.heartbeat(state: state, requests: [request], options: ours, now: agentNow)
    let by = (((try? JSONSerialization.jsonObject(with: asked.line())) as? [String: Any])?["rd"] as? [String: Any])?["by"] as? [String: String]
    check("…and whose request it is, which is not the same as the most urgent thing going on",
          asked.extended?.promptProject == "docs" && asked.extended?.promptAgent == "Claude Code" && asked.extended?.topName == "s2" && by == ["n": "docs", "t": "Claude Code"])
    check("no request offered, no asker named", hb.extended?.promptProject == nil && rd?["by"] == nil)

    let waiting = StateSnapshot.make(groups: [], metrics: Metrics(), agents: [agent("w", .waiting, project: "文档站", waitingFor: "permission prompt")], now: agentNow, host: "Test Mac")
    let w = BuddyProtocol.heartbeat(state: waiting, requests: [], options: ours, now: agentNow).extended
    check("a waiting session is the top item, by its project name, in the script it is written in",
          w?.state == "waiting" && w?.topKind == "agent" && w?.topName == "文档站" && w?.topTool == "Claude Code" && w?.topWait == "permission prompt")
    check("a device that cannot draw that script gets a question mark instead",
          BuddyProtocol.heartbeat(state: waiting, requests: [], options: BuddyProtocol.Options(secure: true, extended: true), now: agentNow).extended?.topName == "?")
    check("the device says what it understands in its status",
          BuddyProtocol.parse(Data("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":1,\"utf8\":true}}".utf8))
          == .status(BuddyProtocol.DeviceStatus(name: nil, secure: true, batteryPercent: nil, onUSB: nil, extended: true, unicode: true)))
}

section("other programs' things on a device")
do {
    func agent(_ id: String, _ state: AgentState, project: String) -> AgentSession {
        AgentSession(id: "claude-code:\(id)", tool: "claude-code", project: project, title: "A private title", state: state,
                     waitingFor: nil, since: agentNow.addingTimeInterval(-20), source: "official")
    }
    func task(_ name: String, _ state: String, fraction: Double?, eta: Int? = nil, ago: TimeInterval = 5) -> InboxTask {
        InboxTask(id: "importer/\(name)", from: "importer", title: name, fraction: fraction, etaSec: eta, state: state,
                  startedAt: agentNow.addingTimeInterval(-300), updatedAt: agentNow.addingTimeInterval(-ago))
    }
    let question = InboxQuestion(id: "qwert", from: "planner", text: "Which branch should the fix go on?", choices: ["main", "release"],
                                 askedAt: agentNow.addingTimeInterval(-20), expiresAt: agentNow.addingTimeInterval(100))
    let notice = InboxNotice(id: "nnnnn", from: "builder", title: "Build", body: "All 42 tests passed", level: .done, at: agentNow.addingTimeInterval(-10))
    let idle = StateSnapshot.make(groups: [], metrics: Metrics(), agents: [], now: agentNow, host: "Test Mac")
    let rendering = StateSnapshot.make(groups: [groupA], metrics: Metrics(), agents: [], now: agentNow, host: "Test Mac")
    let inbox = InboxView(notices: [notice], tasks: [task("Import", "working", fraction: 0.4, eta: 120)], questions: [question])
    let ours = BuddyProtocol.Options(secure: true, unicode: true, extended: true, inbox: true)
    func rd(_ state: StateSnapshot, _ inbox: InboxView, _ options: BuddyProtocol.Options = ours) -> BuddyProtocol.Extended? {
        BuddyProtocol.heartbeat(state: state, requests: [], inbox: inbox, options: options, now: agentNow).extended
    }

    let hb = BuddyProtocol.heartbeat(state: idle, requests: [], inbox: inbox, options: ours, now: agentNow)
    check("the counts include a task at work and a question waiting", hb.total == 1 && hb.running == 1 && hb.waiting == 1)
    check("every device is told that a question is waiting, in one line that says nothing of what was asked",
          hb.msg == "a question is waiting" && hb.entries.isEmpty)
    let unaware = BuddyProtocol.heartbeat(state: idle, requests: [], inbox: inbox, options: BuddyProtocol.Options(secure: true, unicode: true), now: agentNow)
    check("a device that never said it understands them gets no word of what other programs sent",
          unaware.extended == nil && unaware.entries.isEmpty && !String(decoding: unaware.line(), as: UTF8.self).contains("branch")
          && !String(decoding: unaware.line(), as: UTF8.self).contains("Import") && !String(decoding: unaware.line(), as: UTF8.self).contains("tests passed"))
    let e = hb.extended
    check("with nothing else going on, the task is the top item", e?.state == "working" && e?.topKind == "task" && e?.topName == "Import" && e?.topTool == "importer"
          && e?.topPercent == 40 && e?.topEtaSec == 120 && e?.jobTitle == nil)
    check("…and a row in the list", e?.rows.map(\.name) == ["Import"] && e?.rows.first?.tool == "importer" && e?.rows.first?.percent == 40 && e?.rows.first?.ageSec == 300)
    check("the question is offered, with how long is left", e?.ask == BuddyProtocol.Ask(id: "qwert", from: "planner", text: "Which branch should the fix go on?", choices: ["main", "release"], leftSec: 100))
    check("a new notice goes along", e?.note == BuddyProtocol.Note(id: "nnnnn", from: "builder", title: "Build", body: "All 42 tests passed", level: "done"))
    let wire = ((try? JSONSerialization.jsonObject(with: hb.line())) as? [String: Any])?["rd"] as? [String: Any]
    check("on the wire: ask and note under the extra key",
          (wire?["ask"] as? [String: Any])?["choices"] as? [String] == ["main", "release"] && (wire?["ask"] as? [String: Any])?["left"] as? Int == 100
          && (wire?["note"] as? [String: Any])?["level"] as? String == "done" && (wire?["top"] as? [String: Any])?["kind"] as? String == "task")

    check("a render keeps the top place over a task at work; the task is still in the list",
          rd(rendering, inbox)?.topKind == "render" && rd(rendering, inbox)?.rows.map(\.name) == ["s2", "Import"])
    let failed = InboxView(tasks: [task("Import", "error", fraction: 0.3)])
    check("a task that just failed outranks a render at work", rd(rendering, failed)?.state == "error" && rd(rendering, failed)?.topKind == "task" && rd(rendering, failed)?.rows.first?.state == "error")
    check("…for a minute, and then only stays in the list",
          rd(rendering, InboxView(tasks: [task("Import", "error", fraction: 0.3, ago: 90)]))?.topKind == "render"
          && rd(rendering, InboxView(tasks: [task("Import", "error", fraction: 0.3, ago: 90)]))?.rows.count == 2)
    check("a task that just finished shows as done when nothing else is going on",
          rd(idle, InboxView(tasks: [task("Import", "done", fraction: 1)]))?.state == "done" && rd(idle, InboxView(tasks: [task("Import", "done", fraction: 1)]))?.topEtaSec == nil)
    check("a task with no percentage has none", rd(idle, InboxView(tasks: [task("Import", "working", fraction: nil)]))?.topPercent == nil
          && rd(idle, InboxView(tasks: [task("Import", "working", fraction: nil)]))?.topExact == nil)
    check("a notice older than a minute stays on the Mac",
          rd(idle, InboxView(notices: [InboxNotice(id: "nnnnn", from: "b", title: "t", body: "", level: .info, at: agentNow.addingTimeInterval(-61))]))?.note == nil)

    let old = BuddyProtocol.Options(secure: true, unicode: true, extended: true)
    check("firmware that does not know these fields gets none of them, and its top item is left alone",
          rd(idle, inbox, old)?.ask == nil && rd(idle, inbox, old)?.note == nil && rd(idle, inbox, old)?.topKind == nil && rd(idle, inbox, old)?.rows.isEmpty == true)
    check("nothing of it on an unencrypted link", BuddyProtocol.heartbeat(state: idle, requests: [], inbox: inbox,
          options: BuddyProtocol.Options(secure: false, unicode: true, extended: true, inbox: true), now: agentNow).extended == nil
          && BuddyProtocol.heartbeat(state: idle, requests: [], inbox: inbox, options: BuddyProtocol.Options(secure: false), now: agentNow).entries.isEmpty)
    let chinese = InboxQuestion(id: "abcde", from: "规划", text: "修复放到哪个分支？", choices: ["主干", "发布"], askedAt: agentNow, expiresAt: agentNow.addingTimeInterval(60))
    let ascii = BuddyProtocol.Options(secure: true, unicode: false, extended: true, inbox: true)
    check("a question the device cannot draw is not offered there", BuddyProtocol.ask(for: chinese, options: ascii, now: agentNow) == nil
          && BuddyProtocol.ask(for: chinese, options: ours, now: agentNow)?.choices == ["主干", "发布"])
    check("the first question that can be offered is the one offered", rd(idle, InboxView(questions: [chinese, question]), ascii)?.ask?.id == "qwert")
    check("nor a notice it cannot draw", rd(idle, InboxView(notices: [InboxNotice(id: "n", from: "b", title: "完成", body: "", level: .done, at: agentNow)]), ascii)?.note == nil)

    func parse(_ text: String) -> BuddyProtocol.Incoming { BuddyProtocol.parse(Data(text.utf8)) }
    check("a pick comes back as the question's id and the answer's number", parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":1}") == .choice(id: "qwert", index: 1))
    check("anything that is not a whole number in range is not a pick",
          parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":4}") == .unknown && parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":-1}") == .unknown
          && parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":\"1\"}") == .unknown && parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":1.5}") == .unknown
          && parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":true}") == .unknown && parse("{\"cmd\":\"choice\",\"index\":1}") == .unknown)
    check("a pick is never an approval", parse("{\"cmd\":\"choice\",\"id\":\"qwert\",\"index\":0,\"decision\":\"once\"}") == .choice(id: "qwert", index: 0))
    check("the device says it understands them with a 2",
          parse("{\"ack\":\"status\",\"ok\":true,\"data\":{\"sec\":true,\"rd\":2,\"utf8\":true}}")
          == .status(BuddyProtocol.DeviceStatus(name: nil, secure: true, batteryPercent: nil, onUSB: nil, extended: true, unicode: true, inbox: true)))
}

// MARK: ComfyUI

section("a ComfyUI server's queue")
do {
    check("a Python running ComfyUI's main.py is a ComfyUI server, on the usual port",
          ComfyUI.port(processName: "Python", arguments: ["python3", "main.py"], cwd: "/Users/me/ComfyUI") == 8188
          && ComfyUI.port(processName: "python3.12", arguments: ["python3.12", "/opt/ComfyUI/main.py", "--listen"], cwd: "/") == 8188)
    check("…or on the port its command line gives", ComfyUI.port(processName: "python", arguments: ["python", "main.py", "--port", "9000"], cwd: "/srv/comfyui") == 9000)
    check("another Python, another main.py, or another program is not",
          ComfyUI.port(processName: "Python", arguments: ["python3", "train.py"], cwd: "/Users/me/ComfyUI") == nil
          && ComfyUI.port(processName: "Python", arguments: ["python3", "main.py"], cwd: "/Users/me/website") == nil
          && ComfyUI.port(processName: "node", arguments: ["node", "main.py"], cwd: "/Users/me/ComfyUI") == nil)

    let body = Data("{\"queue_running\":[[5,\"aaaa\",{\"1\":{\"class_type\":\"KSampler\"}},{},[\"9\"]]],\"queue_pending\":[[7,\"cccc\",{},{},[]],[6,\"bbbb\",{},{},[]]]}".utf8)
    let queue = ComfyUI.parseQueue(body)
    check("its queue: what is running and what waits, in the order they were queued",
          queue?.running == [ComfyUI.Prompt(number: 5, id: "aaaa")] && queue?.pending.map(\.id) == ["bbbb", "cccc"])
    check("an empty queue is a queue; something else is not", ComfyUI.parseQueue(Data("{\"queue_running\":[],\"queue_pending\":[]}".utf8))?.isEmpty == true
          && ComfyUI.parseQueue(Data("{\"error\":\"no\"}".utf8)) == nil && ComfyUI.parseQueue(Data("not json".utf8)) == nil)
    check("with nothing listening the question comes back unanswered, and soon", { let began = Date(); return ComfyUI.fetchQueue(port: 1, timeout: 0.5) == nil && Date().timeIntervalSince(began) < 1.5 }())

    let tracker = ComfyTracker()
    func q(_ running: [Int], _ pending: [Int]) -> ComfyUI.Queue {
        ComfyUI.Queue(running: running.map { ComfyUI.Prompt(number: $0, id: "p\($0)") }, pending: pending.map { ComfyUI.Prompt(number: $0, id: "p\($0)") })
    }
    check("an idle server is not a job", tracker.update(pid: 1, queue: q([], [])) == nil && tracker.update(pid: 1, queue: nil) == nil)
    let first = tracker.update(pid: 1, queue: q([5], [6, 7]))
    check("a queue with work in it is", first?.running.map(\.number) == [5] && first?.pending.map(\.number) == [6, 7] && first?.done.isEmpty == true)
    let second = tracker.update(pid: 1, queue: q([6], [7, 8]))
    check("a prompt that has left the queue is done; one that joined is up next", second?.done.map(\.number) == [5] && second?.running.map(\.number) == [6] && second?.pending.map(\.number) == [7, 8])
    check("when the queue empties, the count starts over", tracker.update(pid: 1, queue: q([], [])) == nil && tracker.update(pid: 1, queue: q([9], []))?.done.isEmpty == true)
    check("two servers are counted apart", tracker.update(pid: 2, queue: q([1], []))?.running.map(\.number) == [1] && tracker.update(pid: 1, queue: q([10], []))?.done.map(\.number) == [9])
    check("it can be switched off in the rules file", (try? JSONDecoder().decode(AdapterRules.self, from: Data("{\"comfyui\":false}".utf8)))?.comfyui == false && AdapterRules().comfyui == nil)
}

// MARK: MQTT

/// Stands in for a broker: takes one connection after another on this Mac, answers a CONNECT, and keeps every packet it is sent.
final class StandInBroker {
    struct Packet { var type: UInt8; var flags: UInt8; var body: Data }
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var kept: [Packet] = []
    private let connack: UInt8

    init(connack: UInt8 = 0) {
        self.connack = connack
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        fd = listener
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(listener, 4)
        var bound = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }
        port = UInt16(bigEndian: bound.sin_port)
        let code = connack
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(client, &chunk, chunk.count)
                    if n <= 0 { break }
                    buffer.append(contentsOf: chunk[..<n])
                    while buffer.count >= 2 {
                        let first = buffer[buffer.startIndex]
                        var length = 0, shift = 0, used = 1, complete = false
                        while used < buffer.count {
                            let byte = buffer[buffer.startIndex + used]
                            length |= Int(byte & 0x7F) << shift
                            used += 1
                            if byte & 0x80 == 0 { complete = true; break }
                            shift += 7
                        }
                        guard complete, buffer.count >= used + length else { break }
                        let body = buffer.subdata(in: (buffer.startIndex + used)..<(buffer.startIndex + used + length))
                        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + used + length))
                        self?.lock.lock()
                        self?.kept.append(Packet(type: first >> 4, flags: first & 0x0F, body: body))
                        self?.lock.unlock()
                        if first >> 4 == 1 { _ = [UInt8]([0x20, 0x02, 0x00, code]).withUnsafeBufferPointer { write(client, $0.baseAddress, 4) } }
                        if first >> 4 == 12 { _ = [UInt8]([0xD0, 0x00]).withUnsafeBufferPointer { write(client, $0.baseAddress, 2) } }
                    }
                }
                close(client)
            }
        }
    }

    func stop() { close(fd) }

    var packets: [Packet] {
        lock.lock()
        defer { lock.unlock() }
        return kept
    }

    /// The PUBLISH packets so far, as topic, payload and whether they are to be retained.
    var published: [(topic: String, payload: String, retain: Bool)] {
        packets.filter { $0.type == 3 }.compactMap { p in
            guard p.body.count >= 2 else { return nil }
            let n = Int(p.body[p.body.startIndex]) << 8 | Int(p.body[p.body.startIndex + 1])
            guard p.body.count >= 2 + n else { return nil }
            let topic = String(decoding: p.body[(p.body.startIndex + 2)..<(p.body.startIndex + 2 + n)], as: UTF8.self)
            return (topic, String(decoding: p.body[(p.body.startIndex + 2 + n)...], as: UTF8.self), p.flags & 1 == 1)
        }
    }

    func wait(_ what: () -> Bool, seconds: Double = 3) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if what() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return what()
    }
}

section("MQTT: packets and topics")
do {
    check("the length every packet carries, seven bits at a time",
          MQTTPacket.length(0) == [0] && MQTTPacket.length(127) == [0x7F] && MQTTPacket.length(128) == [0x80, 0x01] && MQTTPacket.length(16_383) == [0xFF, 0x7F]
          && MQTTPacket.length(16_384) == [0x80, 0x80, 0x01])
    check("a message, byte for byte", MQTTPacket.publish(topic: "a/b", payload: "hi", retain: true) == Data([0x31, 0x07, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x68, 0x69])
          && MQTTPacket.publish(topic: "a/b", payload: "hi", retain: false).first == 0x30)
    let plain = MQTTPacket.connect(clientID: "rd", username: nil, password: nil, keepAlive: 60, willTopic: "t/availability", willMessage: "offline")
    check("the opening packet names the protocol, its level, a clean start and a last will that is kept",
          plain.first == 0x10 && Array(plain[2..<8]) == [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54] && plain[8] == 0x04 && plain[9] == 0x26 && plain[10] == 0 && plain[11] == 60)
    let named = MQTTPacket.connect(clientID: "rd", username: "me", password: "secret", keepAlive: 60, willTopic: "t", willMessage: "offline")
    check("…and a user name and password when there are any", named[9] == 0xE6 && String(decoding: named, as: UTF8.self).contains("secret")
          && MQTTPacket.connect(clientID: "rd", username: "me", password: nil, keepAlive: 60, willTopic: "t", willMessage: "x")[9] == 0xA6)
    var incoming = Data([0x20, 0x02, 0x00])
    check("half an answer from the broker is not an answer", MQTTPacket.next(in: &incoming) == nil)
    incoming.append(contentsOf: [0x00, 0xD0, 0x00])
    let first = MQTTPacket.next(in: &incoming), second = MQTTPacket.next(in: &incoming)
    check("…and two that arrive together come out as two", first?.type == 2 && first?.body == Data([0, 0]) && second?.type == 13 && incoming.isEmpty)

    let settings = MQTTSettings(host: "broker.local")
    check("the defaults: the usual port, the topic renderdock", settings.resolvedPort == 1883 && MQTTSettings(host: "b", tls: true).resolvedPort == 8883 && settings.base == "renderdock")
    check("a topic is kept free of what MQTT gives a meaning to", MQTTTopics.clean("/studio/#/mac +1/") == "studio//mac1" && MQTTTopics.clean("#") == "renderdock")
    let state = StateSnapshot.make(groups: [groupA], metrics: Metrics(), agents: [], now: agentNow, host: "Test Mac")
    let payload = (try? JSONSerialization.jsonObject(with: Data(MQTTTopics.statePayload(state, settings: settings).utf8))) as? [String: Any]
    check("the state document: the word, the counts, the shot in front with its percentage and its job",
          payload?["state"] as? String == "working" && payload?["rendering"] as? Int == 1 && payload?["progress"] as? Int == 50 && payload?["exact"] as? Bool == true
          && payload?["eta"] as? Int == 2250 && payload?["shot"] as? String == "s2" && payload?["job"] as? String == "Job a" && payload?["agents_waiting"] as? Int == 0)
    check("…with no host name, no path and no project in it",
          !MQTTTopics.statePayload(state, settings: settings).contains("Test Mac") && !MQTTTopics.statePayload(state, settings: settings).contains("/"))
    let unnamed = (try? JSONSerialization.jsonObject(with: Data(MQTTTopics.statePayload(state, settings: MQTTSettings(host: "b", names: false)).utf8))) as? [String: Any]
    check("names can be left out; the numbers still go", unnamed?["shot"] as? String == "" && unnamed?["job"] as? String == "" && unnamed?["progress"] as? Int == 50)
    let idle = (try? JSONSerialization.jsonObject(with: Data(MQTTTopics.statePayload(StateSnapshot.make(groups: [], metrics: Metrics(), now: agentNow, host: "x"), settings: settings).utf8))) as? [String: Any]
    check("with nothing rendering the percentage is 0, so a gauge always has a number", idle?["state"] as? String == "idle" && idle?["progress"] as? Int == 0 && idle?["eta"] as? Int == 0)

    let found = MQTTTopics.discovery(settings, version: "0.3.0")
    let progress = found.first { $0.topic == "homeassistant/sensor/renderdock_renderdock/progress/config" }
    let config = progress.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.payload.utf8))) as? [String: Any] }
    check("Home Assistant is told of each sensor, where to read it and how", found.count == 11 && found.allSatisfy(\.retain)
          && config?["state_topic"] as? String == "renderdock/state" && config?["value_template"] as? String == "{{ value_json.progress }}"
          && config?["availability_topic"] as? String == "renderdock/availability" && config?["unique_id"] as? String == "renderdock_renderdock_progress"
          && (config?["device"] as? [String: Any])?["sw_version"] as? String == "0.3.0")
    check("…two fewer when names are left out, and under another topic for a second Mac",
          MQTTTopics.discovery(MQTTSettings(host: "b", names: false), version: "1").count == 9
          && MQTTTopics.discovery(MQTTSettings(host: "b", topic: "studio/mac-2"), version: "1").first?.topic.hasPrefix("homeassistant/sensor/renderdock_studio_mac_2/") == true)
    check("the settings file the menu creates is complete and switched off",
          (try? JSONDecoder().decode(MQTTSettings.self, from: Data(MQTTSettings.template.utf8)))?.enabled == false)
    check("no file, or one with no broker in it, means no settings",
          MQTTSettings.load(from: URL(fileURLWithPath: "/nonexistent/mqtt.json")) == nil
          && { let u = FileManager.default.temporaryDirectory.appendingPathComponent("rd-mqtt-\(UUID().uuidString.prefix(6)).json"); try? Data("{\"enabled\":true,\"host\":\"\"}".utf8).write(to: u)
               defer { try? FileManager.default.removeItem(at: u) }; return MQTTSettings.load(from: u) == nil }())
}

section("MQTT: against a stand-in broker")
do {
    let broker = StandInBroker()
    let settings = MQTTSettings(host: "127.0.0.1", port: Int(broker.port), username: "me", password: "secret", topic: "studio")
    let client = MQTTClient(settings: settings, version: "0.3.0")
    var statuses: [MQTTClient.Status] = []
    client.onStatus = { statuses.append($0) }
    let working = StateSnapshot.make(groups: [groupA], metrics: Metrics(), agents: [], now: agentNow, host: "Test Mac")
    client.publish(state: working)   // before it is even started: nothing may be lost or sent early
    client.start()
    client.publish(state: working)
    check("it connects, and the state published while connecting arrives once it is in",
          broker.wait { broker.published.contains { $0.topic == "studio/state" } } && client.status == .connected)
    let hello = broker.packets.first
    check("it opens with a CONNECT carrying the user name, the password and the last will", hello?.type == 1
          && String(decoding: hello?.body ?? Data(), as: UTF8.self).contains("studio/availability") && String(decoding: hello?.body ?? Data(), as: UTF8.self).contains("offline")
          && String(decoding: hello?.body ?? Data(), as: UTF8.self).contains("secret"))
    let sent = broker.published
    check("first \"online\", then the sensors, then the state: all to be kept by the broker",
          sent.first?.topic == "studio/availability" && sent.first?.payload == "online" && sent.allSatisfy(\.retain)
          && sent.filter { $0.topic.hasPrefix("homeassistant/") }.count == 11 && sent.last?.topic == "studio/state")
    let before = broker.published.count
    client.publish(state: working)
    Thread.sleep(forTimeInterval: 0.3)
    check("the same state again is not sent again", broker.published.count == before)
    client.publish(state: StateSnapshot.make(groups: [], metrics: Metrics(), now: agentNow, host: "x"))
    check("a changed state is", broker.wait { broker.published.count == before + 1 } && broker.published.last?.payload.contains("\"state\":\"idle\"") == true)
    client.stop()
    check("stopping says \"offline\" and then goodbye",
          broker.wait { broker.packets.last?.type == 14 } && broker.published.last?.topic == "studio/availability" && broker.published.last?.payload == "offline")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check("the status went: connecting, connected, stopped", statuses == [.connecting, .connected, .stopped])
    broker.stop()

    let refusing = StandInBroker(connack: 4)
    let turnedAway = MQTTClient(settings: MQTTSettings(host: "127.0.0.1", port: Int(refusing.port), homeAssistant: false), version: "1")
    turnedAway.start()
    check("a broker that refuses the password is reported in plain words, and nothing is published to it",
          refusing.wait { turnedAway.status == .failed("wrong user name or password") } && refusing.published.isEmpty)
    turnedAway.stop()
    refusing.stop()

    let nobody = MQTTClient(settings: MQTTSettings(host: "127.0.0.1", port: 1), version: "1")
    nobody.start()
    check("no broker there at all: a failure, not a hang", refusing.wait({ if case .failed = nobody.status { return true }; return false }, seconds: 5))
    nobody.stop()
}

// MARK: HTTP parsing and the Host check

section("HTTP request parsing")
let raw = Data("GET /v1/state?x=1 HTTP/1.1\r\nHost: 127.0.0.1:47600\r\nUser-Agent: curl\r\n\r\n".utf8)
check("complete request", LocalAPIServer.parseRequest(raw) == .init(method: "GET", path: "/v1/state", host: "127.0.0.1:47600"))
check("incomplete request waits", LocalAPIServer.parseRequest(Data("GET /v1/state HTTP/1.1\r\nHost: 127.0".utf8)) == nil)
check("header names are case-insensitive", LocalAPIServer.parseRequest(Data("GET / HTTP/1.1\r\nhOsT:  localhost:47600 \r\n\r\n".utf8))?.host == "localhost:47600")
check("loopback address allowed", LocalAPIServer.hostAllowed("127.0.0.1:47600", port: 47600))
check("localhost allowed", LocalAPIServer.hostAllowed("LOCALHOST:47600", port: 47600))
check("another name is refused (DNS rebinding)", !LocalAPIServer.hostAllowed("evil.example:47600", port: 47600))
check("wrong port refused", !LocalAPIServer.hostAllowed("127.0.0.1:8080", port: 47600))
check("missing Host refused", !LocalAPIServer.hostAllowed("", port: 47600))
check("event framing", String(decoding: LocalAPIServer.sse(event: "state", data: Data("{}".utf8)), as: UTF8.self) == "event: state\ndata: {}\n\n")

section("the API from the local network: who is let in")
do {
    typealias API = LocalAPIServer
    func request(_ headers: String) -> API.Request? { API.parseRequest(Data("GET /v1/state HTTP/1.1\r\nHost: 192.168.1.20:47600\r\n\(headers)\r\n".utf8)) }
    check("the token is read from \"Authorization: Bearer\"", request("Authorization: Bearer abc-DEF_123\r\n")?.token == "abc-DEF_123")
    check("…whatever the case of the words, whatever the spaces", request("authorization:   bEaReR    abc\r\n")?.token == "abc")
    check("another scheme is not a token, nor is a bare word, nor three words",
          request("Authorization: Basic abc\r\n")?.token == nil && request("Authorization: abc\r\n")?.token == nil && request("Authorization: Bearer a b\r\n")?.token == nil)
    check("a token in the address is not read",
          API.parseRequest(Data("GET /v1/state?token=abc HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == .init(method: "GET", path: "/v1/state", host: "x"))
    let secret = "0123456789abcdefghijklmnopqrstuv"
    func access(here: Bool, host: String = "192.168.1.20:47600", lan: Bool, token: String? = secret, shown: String?) -> API.Access {
        API.access(fromThisMac: here, host: host, port: 47600, lan: lan, token: token, presented: shown)
    }
    check("from this Mac: as before, no token asked", access(here: true, host: "127.0.0.1:47600", lan: false, token: nil, shown: nil) == .allowed
          && access(here: true, host: "localhost:47600", lan: true, shown: nil) == .allowed)
    check("from this Mac under another name: still refused", access(here: true, host: "evil.example:47600", lan: true, shown: secret) == .forbiddenHost)
    check("from the network with the token: let in", access(here: false, lan: true, shown: secret) == .allowed)
    check("from the network without it, or with another: 401",
          access(here: false, lan: true, shown: nil) == .unauthorized && access(here: false, lan: true, shown: "") == .unauthorized
          && access(here: false, lan: true, shown: secret + "x") == .unauthorized && access(here: false, lan: true, shown: String(secret.dropLast())) == .unauthorized
          && access(here: false, lan: true, shown: secret.uppercased()) == .unauthorized)
    check("from the network while that is off: nothing, token or no token",
          access(here: false, lan: false, shown: secret) == .closed && access(here: false, lan: false, shown: nil) == .closed)
    check("switched on without a token is not switched on", access(here: false, lan: true, token: nil, shown: nil) == .closed
          && access(here: false, lan: true, token: "", shown: "") == .closed)
    check("tokens are compared whole", API.same("abc", "abc") && !API.same("abc", "abd") && !API.same("abc", "abcd") && !API.same("", "a") && API.same("", ""))

    let one = API.newToken(), two = API.newToken()
    check("a new token is 32 characters that are safe in a header", one.count == 32 && one.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    check("and not the same twice", one != two && !two.isEmpty)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-token-\(ProcessInfo.processInfo.processIdentifier)")
    let file = folder.appendingPathComponent("api-token")
    let made = API.token(at: file)
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? Int
    check("the token is made on first use, in a file only its owner can read", made.count == 32 && mode == 0o600)
    check("and is the same the next time", API.token(at: file) == made)
    let renewed = API.token(at: file, renew: true)
    check("a new one replaces it", renewed.count == 32 && renewed != made && API.token(at: file) == renewed)
    try? Data("short\n".utf8).write(to: file)
    check("a file that holds no token is replaced, not used", API.token(at: file).count == 32)
    try? FileManager.default.removeItem(at: folder)

    func endpoint(_ text: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(text), port: 5000) }
    check("the other end is this Mac only at a loopback address",
          API.isLoopback(endpoint("127.0.0.1")) && API.isLoopback(endpoint("127.8.9.10")) && API.isLoopback(endpoint("::1")) && API.isLoopback(endpoint("::ffff:127.0.0.1"))
          && !API.isLoopback(endpoint("192.168.1.20")) && !API.isLoopback(endpoint("10.0.0.1")) && !API.isLoopback(endpoint("fe80::1")) && !API.isLoopback(endpoint("localhost")))
}

section("the entry for other programs, as an MCP server")
do {
    var notices: [(String, String, InboxLevel, String)] = []
    var reports: [(String, String?, Double?, Int?, String, String)] = []
    var questions: [(String, [String], Int, String)] = []
    var answer = InboxClient.Answer.chosen(index: 1, label: "Keep")
    var sent = InboxClient.Sent.ok(id: "n1")
    var server = MCPServer(backend: MCPServer.Backend(
        notify: { notices.append(($0, $1, $2, $3)); return sent },
        progress: { reports.append(($0, $1, $2, $3, $4, $5)); return sent },
        ask: { questions.append(($0, $1, $2, $3)); return answer },
        status: { "2 rendering · 0 paused" }))
    func send(_ text: String) -> [String: Any]? {
        server.handle(Data(text.utf8)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    func result(_ text: String) -> [String: Any]? { send(text)?["result"] as? [String: Any] }
    func errorCode(_ text: String) -> Int? { (send(text)?["error"] as? [String: Any])?["code"] as? Int }
    func toolText(_ reply: [String: Any]?) -> String? { ((reply?["content"] as? [[String: Any]])?.first)?["text"] as? String }

    let hello = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"9"}}}"#)
    check("initialize: the version asked for when it is one this speaks, the tools capability, who this is",
          hello?["protocolVersion"] as? String == "2025-03-26" && (hello?["capabilities"] as? [String: Any])?["tools"] != nil
          && (hello?["serverInfo"] as? [String: Any])?["name"] as? String == "renderdock")
    var other = MCPServer(backend: MCPServer.Backend(notify: { _, _, _, _ in .unavailable }, progress: { _, _, _, _, _, _ in .unavailable }, ask: { _, _, _, _ in .unavailable }, status: { "" }))
    let newest = other.handle(Data(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#.utf8))
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    check("a version this does not speak is answered with the newest it does, and the id comes back as it was sent",
          (newest?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.versions[0] && newest?["id"] as? String == "a")
    check("a notification is never answered", server.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil
          && server.handle(Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"notify","arguments":{"body":"x"}}}"#.utf8)) == nil && notices.isEmpty)
    check("ping is answered with nothing in it", result(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)?.isEmpty == true)
    let listed = result(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)?["tools"] as? [[String: Any]]
    check("four tools, each with a name, a description and the shape of what it takes",
          listed?.compactMap { $0["name"] as? String } == ["notify", "progress", "ask", "status"]
          && listed?.allSatisfy { ($0["description"] as? String)?.isEmpty == false && ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" } == true)

    let shown = result(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"notify","arguments":{"title":"Build","body":"Finished in 48 s","level":"done"}}}"#)
    check("notify reaches the entry as it was given, from the client that said hello",
          notices.count == 1 && notices.first?.0 == "Build" && notices.first?.1 == "Finished in 48 s" && notices.first?.2 == .done && notices.first?.3 == "claude-code"
          && shown?["isError"] as? Bool == false && toolText(shown) == "shown")
    let badLevel = result(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"notify","arguments":{"body":"x","level":"urgent"}}}"#)
    check("a level it does not know is a tool error that says which are known, and nothing is sent",
          badLevel?["isError"] as? Bool == true && toolText(badLevel)?.contains("info") == true && notices.count == 1)
    check("nothing to say is a tool error", result(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"notify","arguments":{}}}"#)?["isError"] as? Bool == true)

    _ = result(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"progress","arguments":{"name":"import","title":"Importing the catalogue","percent":48.5,"eta_seconds":140}}}"#)
    let ended = result(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"progress","arguments":{"name":"import","state":"done"}}}"#)
    check("progress: the name, the percentage, the time left; then how it ended",
          reports.count == 2 && reports[0].0 == "import" && reports[0].1 == "Importing the catalogue" && reports[0].2 == 48.5 && reports[0].3 == 140 && reports[0].4 == "working"
          && reports[1].4 == "done" && reports[1].2 == nil && toolText(ended) == "shown as done")
    check("a percentage out of range, one given as text, a state it does not know: tool errors, nothing sent",
          result(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"progress","arguments":{"name":"x","percent":140}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"progress","arguments":{"name":"x","percent":"50"}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"progress","arguments":{"name":"x","state":"paused"}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"progress","arguments":{}}}"#)?["isError"] as? Bool == true && reports.count == 2)

    let picked = result(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Delete the old export too?","choices":["Delete","Keep","Let me look"],"timeout_seconds":60}}}"#)
    check("ask: the question and its answers go through whole, and the answer picked comes back as its text",
          questions.count == 1 && questions.first?.0 == "Delete the old export too?" && questions.first?.1 == ["Delete", "Keep", "Let me look"] && questions.first?.2 == 60
          && toolText(picked) == "Keep" && picked?["isError"] as? Bool == false)
    answer = .none("timeout")
    let unanswered = result(#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["Yes","No"]}}}"#)
    check("nobody answering is said in so many words, is not an error, and is none of the answers",
          unanswered?["isError"] as? Bool == false && toolText(unanswered)?.hasPrefix("no answer (timeout)") == true && toolText(unanswered) != "Yes" && questions.last?.2 == InboxLimits.askTimeoutDefault)
    let before = questions.count
    check("a question that cannot be asked as it stands is refused here: one answer, five, a long one, two the same, not text",
          result(#"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["Yes"]}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["1","2","3","4","5"]}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["Yes","An answer far too long to fit"]}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["Yes","Yes"]}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"ask","arguments":{"question":"Go on?","choices":["Yes",2]}}}"#)?["isError"] as? Bool == true
          && result(#"{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"ask","arguments":{"question":"","choices":["Yes","No"]}}}"#)?["isError"] as? Bool == true
          && questions.count == before)
    sent = .unavailable
    let nobody = result(#"{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"notify","arguments":{"body":"x"}}}"#)
    check("the app not listening is a tool error that says how to switch it on", nobody?["isError"] as? Bool == true && toolText(nobody) == MCPServer.notTaking)
    sent = .refused("too many notices")
    check("a refusal comes back with its reason", toolText(result(#"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"notify","arguments":{"body":"x"}}}"#)) == "refused: too many notices")
    check("status answers with the text it was given", toolText(result(#"{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"status","arguments":{}}}"#)) == "2 rendering · 0 paused")

    check("what is not JSON: a parse error with no id", errorCode("not json") == -32700)
    check("a list of messages is refused", errorCode(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#) == -32600)
    check("a method it does not have, a tool it does not have", errorCode(#"{"jsonrpc":"2.0","id":24,"method":"resources/list"}"#) == -32601
          && errorCode(#"{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"shell","arguments":{}}}"#) == -32602)
    check("somebody's answer to a request this never made is let pass", server.handle(Data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#.utf8)) == nil)
    var named = MCPServer(backend: MCPServer.Backend(notify: { notices.append(($0, $1, $2, $3)); return .ok(id: nil) }, progress: { _, _, _, _, _, _ in .unavailable },
                                                     ask: { _, _, _, _ in .unavailable }, status: { "" }), from: "nightly build")
    _ = named.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code"}}}"#.utf8))
    _ = named.handle(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notify","arguments":{"body":"x"}}}"#.utf8))
    check("a name given when it was started wins over the client's own", notices.last?.3 == "nightly build")
}

// MARK: The server itself, on a spare port with its own discovery file

section("local API server")
let discovery = FileManager.default.temporaryDirectory.appendingPathComponent("rd-checks-\(ProcessInfo.processInfo.processIdentifier)/api.json")
let server = LocalAPIServer()
server.start(preferredPort: 47680, discovery: discovery)
var port: UInt16?
for _ in 0..<100 where port == nil {
    Thread.sleep(forTimeInterval: 0.03)
    port = server.port
}
check("comes up", port != nil)
if let port {
    server.publish(state: snapshot.json())
    Thread.sleep(forTimeInterval: 0.1)
    func get(_ path: String) -> (Int, Data) {
        var result = (0, Data())
        let done = DispatchSemaphore(value: 0)
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return result
    }
    let state = get("/v1/state")
    check("GET /v1/state is 200 and returns what was published", state.0 == 200 && state.1 == snapshot.json())
    check("GET / lists the endpoints", get("/").0 == 200)
    check("unknown path is 404", get("/v1/nope").0 == 404)
    let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: discovery))) as? [String: Any]
    check("discovery file names the port and this process",
          info?["port"] as? Int == Int(port) && info?["pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier))
    // From the network. This Mac's own network address stands in for another device: a connection to it does
    // not come from the loopback, so it is asked for the token like any other.
    func fetch(_ address: String, _ path: String, token: String?) -> Int {
        var status = 0
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: URL(string: "http://\(address):\(port)\(path)")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return status
    }
    check("the discovery file says access from the network is off, and holds no token",
          info?["lan"] as? Bool == false && info?.keys.contains { $0.lowercased().contains("token") } == false)
    if let address = LocalAPIServer.networkAddresses().first {
        check("off by default: nothing answers at the Mac's network address", fetch(address, "/v1/state", token: nil) == 0)
        let secret = LocalAPIServer.newToken()
        server.setLAN(true, token: secret)
        var open = false
        for _ in 0..<100 where !open {
            Thread.sleep(forTimeInterval: 0.03)
            open = server.lanOpen && fetch(address, "/v1/state", token: secret) == 200
        }
        check("switched on: the token gets the state", open)
        check("without the token, or with another: 401", fetch(address, "/v1/state", token: nil) == 401 && fetch(address, "/v1/state", token: secret + "x") == 401
              && fetch(address, "/", token: nil) == 401 && fetch(address, "/v1/history", token: "nope") == 401)
        check("from this Mac's loopback it is as before, with no token", get("/v1/state").0 == 200)
        let other = LocalAPIServer.newToken()
        server.setLAN(true, token: other)
        Thread.sleep(forTimeInterval: 0.1)
        check("a new token shuts the old one out at once", fetch(address, "/v1/state", token: secret) == 401 && fetch(address, "/v1/state", token: other) == 200)
        server.setLAN(false, token: nil)
        var closed = false
        for _ in 0..<100 where !closed {
            Thread.sleep(forTimeInterval: 0.03)
            closed = !server.lanOpen && fetch(address, "/v1/state", token: other) == 0
        }
        check("switched off again: nothing answers there, and the loopback still does", closed && get("/v1/state").0 == 200)
        server.setLAN(true, token: nil)
        Thread.sleep(forTimeInterval: 0.2)
        check("asked to switch on without a token: it stays off", !server.lanOpen && fetch(address, "/v1/state", token: nil) == 0)
    } else {
        print("  (this Mac is on no network: the checks that reach the API through a network address were skipped)")
    }
    // The stream a display reads over Wi-Fi: read here with a plain socket, the way a small device would.
    func readStream(host: String, token: String?, for seconds: Double, then act: (() -> Void)? = nil) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return "" }
        var request = "GET /v1/device HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if let token { request += "Authorization: Bearer \(token)\r\n" }
        request += "\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var out = Data()
        let end = Date().addingTimeInterval(seconds)
        var acted = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 { out.append(contentsOf: buffer.prefix(n)) }
            if n == 0 { break }
            if !acted, out.count > 20 { acted = true; act?() }
        }
        return String(decoding: out, as: UTF8.self)
    }
    let beat = BuddyProtocol.heartbeat(state: snapshot, requests: [], options: .overWiFi).line()
    var machine = Metrics()
    machine.cpu = 0.5
    let stream = readStream(host: "127.0.0.1", token: nil, for: 1.2) {
        server.publish(deviceSnapshot: beat, deviceMac: BuddyProtocol.mac(machine, cores: 8))
    }
    let lines = stream.components(separatedBy: "\n").filter { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }
    check("the stream for a display opens as a stream", stream.hasPrefix("HTTP/1.1 200 OK") && stream.contains("text/event-stream"))
    check("it is greeted with the time, then gets the snapshot and the Mac's line as they are published",
          lines.first?.hasPrefix("{\"time\":[") == true && lines.contains(String(decoding: beat.dropLast(), as: UTF8.self)) && lines.contains { $0.hasPrefix("{\"mac\":{") })
    check("each is one line of JSON after \"data: \", as the device's reader takes it",
          lines.allSatisfy { !$0.contains("\n") && (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil } && lines.count >= 3)
    let wifiLine = String(decoding: beat, as: UTF8.self)
    check("what goes to a display over Wi-Fi offers nothing to answer: no request, no question",
          !wifiLine.contains("\"prompt\"") && !wifiLine.contains("\"ask\"") && BuddyProtocol.Options.overWiFi.offerRequests == false && BuddyProtocol.Options.overWiFi.readOnly)
    check("a line that has not changed is not sent a second time at once", {
        let again = readStream(host: "127.0.0.1", token: nil, for: 0.8) { server.publish(deviceSnapshot: beat); server.publish(deviceSnapshot: beat) }
        return again.components(separatedBy: "\n").filter { $0 == "data: " + String(decoding: beat.dropLast(), as: UTF8.self) }.count <= 1
    }())
    // A connection that asks for nothing is dropped after a while; a stream that was opened is not. (A display
    // reading over Wi-Fi was: the first real one was cut off every ten seconds.)
    server.requestDeadline = 0.4
    var later = Metrics()
    later.cpu = 0.25
    let laterLine = BuddyProtocol.mac(later, cores: 8)
    let kept = readStream(host: "127.0.0.1", token: nil, for: 1.6) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) { server.publish(deviceMac: laterLine) }
    }
    check("a display's stream stays open past the time an idle connection is given",
          kept.contains("data: " + String(decoding: laterLine.dropLast(), as: UTF8.self)))
    check("a connection that asks for nothing is still dropped", {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return false }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte = [UInt8](repeating: 0, count: 1)
        let started = Date()
        let n = read(fd, &byte, 1)   // 0: the other end closed
        return n <= 0 && Date().timeIntervalSince(started) < 1.5
    }())
    server.requestDeadline = 10
    if let address = LocalAPIServer.networkAddresses().first {
        let secret = LocalAPIServer.newToken()
        server.setLAN(true, token: secret)
        var up = false
        for _ in 0..<100 where !up {
            Thread.sleep(forTimeInterval: 0.03)
            up = server.lanOpen
        }
        Thread.sleep(forTimeInterval: 0.2)
        check("from the network the stream needs the token like everything else",
              readStream(host: address, token: nil, for: 0.6).hasPrefix("HTTP/1.1 401") && readStream(host: address, token: "wrong", for: 0.6).hasPrefix("HTTP/1.1 401")
              && readStream(host: address, token: secret, for: 0.8).hasPrefix("HTTP/1.1 200 OK"))
        server.setLAN(false, token: nil)
        Thread.sleep(forTimeInterval: 0.3)
    }
    server.stop()
    check("stop removes the discovery file", !FileManager.default.fileExists(atPath: discovery.path))
    check("stop releases the port", get("/v1/state").0 == 0)
}
try? FileManager.default.removeItem(at: discovery.deletingLastPathComponent())

print(failures == 0 ? "\(total)/\(total) checks passed" : "\(total - failures)/\(total) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

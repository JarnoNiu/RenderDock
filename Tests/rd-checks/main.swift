// Checks for RenderDockCore. Run with `swift run rd-checks`; exits non-zero if anything fails.
// A plain executable rather than an XCTest bundle so it works with the Command Line Tools alone.
import Foundation
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
    server.stop()
    check("stop removes the discovery file", !FileManager.default.fileExists(atPath: discovery.path))
    check("stop releases the port", get("/v1/state").0 == 0)
}
try? FileManager.default.removeItem(at: discovery.deletingLastPathComponent())

print(failures == 0 ? "\(total)/\(total) checks passed" : "\(total - failures)/\(total) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

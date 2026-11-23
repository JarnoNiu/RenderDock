# Local API

> Part of 0.2, which is still in development. Off by default.

RenderDock can publish what it knows — every job, every shot, the machine's metrics — as JSON on `127.0.0.1`. The capsule is one reader of that state. A script, a status light, a Stream Deck key or a small display on your desk can be another.

The API is **read-only**. It cannot pause, stop or change anything.

## Turning it on

Any one of these:

- Menu-bar icon → **Local API**
- `defaults write io.github.jarnoniu.renderdock localAPI -bool true`, then relaunch
- Launch with `--api`

It listens on `http://127.0.0.1:47600`. If that port is taken it tries the next ones, up to 47610. The menu item shows the port in use, and a running instance writes it to:

```
~/Library/Application Support/RenderDock/api.json
{"pid": 4242, "port": 47600, "url": "http://127.0.0.1:47600"}
```

The file is removed when the app quits or the API is switched off. If the app crashed, the file can be stale: check that `pid` is alive.

No render running? A demo instance serves made-up jobs that keep moving, which is handy when you are building something against the API:

```bash
open -n /Applications/RenderDock.app --args --demo --api
```

A demo instance does not write the discovery file.

## What keeps it safe

- It binds to the loopback interface only. Nothing else on your network can connect.
- It answers `GET` and nothing else.
- It checks the `Host` header and answers only `127.0.0.1:<port>` and `localhost:<port>`, so a web page cannot reach it through DNS rebinding.
- It sends no CORS headers, so a web page cannot read its responses.
- The state carries no file-system paths.

Access from other devices on the network is not available yet. When it comes it will be a separate switch, off by default, with a token.

## `GET /v1/state`

The whole state in one document.

```bash
curl -s http://127.0.0.1:47600/v1/state
```

```json
{
  "version": 1,
  "app": "RenderDock 0.2.0-dev",
  "host": "studio-mac",
  "updatedAt": "2026-11-24T04:12:07Z",
  "summary": {
    "rendering": 2, "paused": 1, "stalled": 0, "queued": 1,
    "focus": {
      "name": "s040_explode", "state": "rendering",
      "framesDone": 452, "framesTotal": 720, "fraction": 0.628, "exact": true, "etaSec": 1662
    }
  },
  "jobs": [
    {
      "id": "g41872-1795400000", "title": "Product film · hero shots", "project": "studio-reel",
      "script": "render_hero.sh", "state": "running", "startedAt": "2026-11-24T02:58:41Z",
      "keepAwake": true, "shotsDone": 3, "shotsTotal": 8,
      "shots": [
        {"id": "…/s030_macro", "name": "s030_macro", "state": "done", "exact": false},
        {"id": "…/s040_explode", "name": "s040_explode", "state": "rendering",
         "framesDone": 452, "framesTotal": 720, "fraction": 0.628, "exact": true,
         "secPerFrame": 6.2, "etaSec": 1662, "pid": 41872},
        {"id": "…/s050_assemble", "name": "s050_assemble", "state": "pending", "exact": false}
      ]
    }
  ],
  "metrics": {
    "cpu": 0.62, "gpu": 0.86, "gpuMemBytes": 11811160064,
    "memUsed": 46170898432, "memTotal": 68719476736, "memPressure": 1,
    "swapUsed": 1932735283, "swapTotal": 4294967296,
    "tempC": 68.4, "diskFree": 442381631488, "onAC": true, "awake": true
  }
}
```

| Field | Meaning |
|---|---|
| `summary.focus` | The one shot a small display should show: the furthest-along running shot, otherwise a stalled or paused one. Absent when nothing is going on |
| `fraction` | 0–1. Present only when a total is known |
| `exact` | `true` when `framesTotal` is exact (from `render-progress.json` or the command line). `false` when it is an estimate or unknown. **Show `≈` or no percentage when this is false** |
| `etaSec` | Seconds left for this shot. Present only while it is running with a known total and a measured frame time |
| job `state` | `running`, `stalled`, `paused`, `queued` |
| shot `state` | `rendering`, `compositing`, `finishing`, `encoding`, `starting`, `paused`, `stalled`, `pending`, `done` |
| `metrics.cpu`, `metrics.gpu` | 0–1 |
| `metrics.memPressure` | 1 normal, 2 warning, 4 critical |
| `metrics.awake` | Something is holding a sleep assertion: the Mac will not idle-sleep |

Missing values are omitted, not sent as `null`. State names are always English, whatever the UI language.

## `GET /v1/events`

A [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html) stream. It sends the current state at once, then:

| Event | When | Data |
|---|---|---|
| `state` | After each scan, at most once a second | The same document as `/v1/state` |
| `job.started` | A job appears | `{type, jobId, jobTitle, project, at}` |
| `shot.done` | A shot in a queue finishes | The same, plus `shot` |
| `job.stalled` | No new frame for much longer than usual | |
| `job.paused`, `job.resumed` | The job's processes were stopped or continued | |
| `job.ended` | The job's processes are gone | |

`job.ended` is deliberately not called "done": from the outside, RenderDock cannot tell a finished render from a crashed one. Jobs that were already running when RenderDock started are not announced as `job.started`.

```bash
curl -N http://127.0.0.1:47600/v1/events
```

```
retry: 3000

event: state
data: {"app":"RenderDock 0.2.0-dev", …}

event: shot.done
data: {"at":"2026-11-24T04:31:47Z","jobId":"g41872-1795400000","jobTitle":"Product film · hero shots","project":"studio-reel","shot":"s040_explode","type":"shot.done"}
```

Up to 16 streams can be open at once. While at least one is, RenderDock scans every 3 seconds instead of every 6.

## Without the app

The same state document, from a one-off scan, with nothing listening:

```bash
/Applications/RenderDock.app/Contents/MacOS/RenderDock --status --json
```

`--status` alone prints it as text.

## Small examples

Say something when a job ends:

```bash
curl -sN http://127.0.0.1:47600/v1/events | while read -r line; do
  [[ $line == "event: job.ended" ]] && say "A render job has ended"
done
```

Overall progress of the focused shot, for a status bar:

```bash
curl -s http://127.0.0.1:47600/v1/state | python3 -c '
import json, sys
f = json.load(sys.stdin)["summary"].get("focus")
if not f: print("idle")
elif "fraction" in f: print(("" if f["exact"] else "≈") + f"{f[\"fraction\"]:.0%} {f[\"name\"]}")
else: print(f"{f.get(\"framesDone\", 0)} frames {f[\"name\"]}")'
```

Follow the stream from Python, with nothing to install:

```python
import json, urllib.request

with urllib.request.urlopen("http://127.0.0.1:47600/v1/events") as stream:
    event = None
    for raw in stream:
        line = raw.decode().rstrip("\n")
        if line.startswith("event: "):
            event = line[7:]
        elif line.startswith("data: ") and event != "state":
            print(event, json.loads(line[6:]))
```

## Stability

`version` is 1. Within version 1, fields are added and never renamed or removed. Ignore fields you do not know.

Not in the API yet: access from other devices, thumbnails of the latest frame, and anything that changes a job.

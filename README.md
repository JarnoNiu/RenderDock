<div align="center">

<img src="assets/icon.png" width="120" alt="RenderDock icon">

# RenderDock

**Every render on your Mac, in one floating capsule.**

**English** · [简体中文](docs/i18n/README.zh-CN.md) · [繁體中文](docs/i18n/README.zh-TW.md) · [日本語](docs/i18n/README.ja.md) · [한국어](docs/i18n/README.ko.md) · [Español](docs/i18n/README.es.md) · [Français](docs/i18n/README.fr.md) · [Deutsch](docs/i18n/README.de.md) · [Português](docs/i18n/README.pt-BR.md) · [Русский](docs/i18n/README.ru.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Dependencies: none](https://img.shields.io/badge/dependencies-none-4FEDB0)
![License: MIT](https://img.shields.io/badge/license-MIT-42C2FF)

<img src="assets/demo.gif" width="820" alt="RenderDock demo: the capsule expands into a panel, is dragged across the screen and snaps into a corner">

<sub>The UI above is rendered by the app itself in demo mode. The jobs, numbers and pointer are scripted; the backdrop is a mock desktop.</sub>

</div>

---

RenderDock is a small native macOS app for people who start renders from scripts and terminals. It finds every headless Blender job running on the machine, shows how far each one is, and keeps an eye on the hardware doing the work. It needs no setup and it never touches your jobs.

## Why

A render launched from a shell script has no window. You end up running `ps`, counting files in an output folder, and wondering whether the Mac went to sleep an hour ago. RenderDock puts all of that in one place that is always on screen and never in the way.

## What you get

<table>
<tr>
<td width="50%" valign="top">

**A capsule that lives anywhere**

Drag it to any display. It snaps to edges, corners and the top or bottom centre, and remembers where you left it. It floats above full-screen apps and follows you across Spaces.

<img src="assets/capsule-en.png" width="380" alt="The collapsed capsule">

**One click for the whole picture**

- Every job chain as a card: title, project, script, elapsed time
- A segment bar for multi-shot queues: done, rendering, paused, up next
- For the shot in progress: a thumbnail of the latest frame, frame count, seconds per frame, time left, CPU cores and memory
- States it can tell apart: running, paused (`SIGSTOP`), stalled, queued

**The machine, at a glance**

CPU, GPU utilisation and GPU memory, memory and memory pressure, SoC temperature, swap, free disk, power source, and whether anything is keeping the Mac awake.

</td>
<td width="50%" valign="top">

<img src="assets/panel-en.png" width="400" alt="The expanded panel with job cards and system metrics">

</td>
</tr>
</table>

Also included: a menu-bar item with a progress ring, an optional **Keep Awake While Rendering** switch, and **Launch at Login**.

New in 0.2: exact progress for any render through [`renderdock run`](docs/EXACT-PROGRESS.md), [notifications](docs/NOTIFICATIONS.md) on the Mac and on your phone when a job finishes, fails or stalls, and a [local API](docs/API.md) so other displays can show the same progress.

New in 0.3: [history](docs/HISTORY.md) with time-left estimates for a whole queue; [coding agents' sessions](docs/AGENT-TASKS.md) next to your renders; real progress for [ffmpeg encodes](docs/EXACT-PROGRESS.md#ffmpeg-from-03), and a [ComfyUI](docs/COMFYUI.md) queue shown as it drains. More things are there and stay off until you switch them on: [answering an agent's permission request](docs/ANSWERING-AGENTS.md) from the panel, a [small Bluetooth display for the desk](docs/DEVICES.md) with [open firmware](firmware/desk-display/README.md) for one board, an [entry for other programs](docs/AGENT-ENTRY.md), so that any script or agent can post a notice, report progress, or ask you a question, and [MQTT](docs/MQTT.md) for Home Assistant. Two [examples](examples) build on the local API: an LED strip as a progress bar, and a Stream Deck key.

## Quick start

Requirements: macOS 14 or later, and the Swift 6 toolchain (Xcode 16+ or just the Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/JarnoNiu/RenderDock.git
cd RenderDock
zsh scripts/install.sh
```

That builds the app, copies it to `/Applications/RenderDock.app` and launches it. No admin password, no dependencies to download. Add `--login` to turn on Launch at Login as well.

No render running? Look at it with made-up jobs:

```bash
open -n /Applications/RenderDock.app --args --demo
```

Or watch it pick up a real process, with no Blender and no GPU involved:

```bash
zsh scripts/fake-render.sh 60 1
```

> There is no prebuilt download yet. The app is not notarised, and an unsigned download is more trouble than a 30-second build. Signed releases and a Homebrew cask are on the roadmap.

## How it finds your renders

RenderDock reads the process table and the output folders. It does not hook into Blender, and you do not have to change your scripts.

| It sees | It shows |
|---|---|
| A Blender process started with `-b` / `--background` | A **shot** |
| The outermost script above it in the process tree (`zsh render_all.sh`, `python queue.py`, …) | A **job chain**: one card. The title is the first comment line of that script |
| `scene:shot` arguments on a queue script's command line | The **queue**: which shots are done, rendering and up next |
| A script wrapped in `caffeinate` with no render process yet | **Queued** |
| A process stopped with `kill -STOP` | **Paused** |
| No new frame for 10× the usual frame time (5 minutes at least) | **Stalled** |
| Image files in the output folder, de-duplicated by frame number | **Frames done**, seconds per frame, latest-frame thumbnail |

The output folder comes from Blender's own `-o` / `--render-output` (including `//` paths relative to the `.blend`), or from a script argument `--out DIR` after `--`. Steps of your own pipeline that are not a plain Blender render can be described in a small [rules file](docs/ADAPTERS.md).

### Where the percentage comes from

RenderDock only shows a percentage when it knows the total. It does not guess.

| Source | Shown as |
|---|---|
| `render-progress.json` in the output folder (see below) | exact: `412/720 frames · 57%` and time left |
| A frame range on the command line: `-s 1 -e 250 -a`, or `-f 1..250` | exact |
| Started with `renderdock run --`, or with the Blender hook loaded | exact, even when nothing is on the command line. It also tells a finished job from a failed one |
| An older clip with the same name next to the output folder | estimate, marked `≈`. Dropped as soon as the frame count passes it |
| None of these | frame count and seconds per frame only, with an indeterminate bar |

```bash
# exact progress, no setup
blender -b shot_010.blend -o //render/frame_#### -s 1 -e 250 -a
```

### `render-progress.json`: exact progress for any pipeline

If your range lives inside the `.blend` or your script renders frames itself, write one small file to the output folder after each frame:

```json
{"done": 12, "total": 720}
```

```python
# in a Blender Python script
(out_dir / "render-progress.json").write_text(json.dumps({"done": i + 1, "total": len(frames)}))
```

Anything that can write a file can report progress this way, not just Blender.

## What it will not do

- It **never touches your renders**: it sends them no signals and never writes into your render folders. Whatever goes beyond watching is off until you switch it on: notification channels, the local API (`127.0.0.1` only), Bluetooth for a desk display, answering agents' requests, the entry for other programs, and MQTT. It makes no network connections unless you add a notification channel or an MQTT broker.
- There are no pause, resume or stop buttons yet. Queue scripts often manage `STOP`/`CONT` themselves, and two hands on the same switch is a bad idea.
- If neither the output folder nor the frame range is on the command line, a job still appears, with CPU, memory and elapsed time, but without frames.
- SoC temperature is read from IOHID sensors, a private interface available on Apple Silicon. On Intel Macs, or after a system update that moves the sensors, the tile shows `–`. Fan speed and wattage are not read.
- Built and tested on macOS 26 with an M5 Max. It compiles for macOS 14, but 14 and 15 and Intel Macs are untested. Reports are welcome.
- UI languages: English and Simplified Chinese (it follows the system language; force one with `--lang en` or `--lang zh`).

## Roadmap

The full TODO list, with a timeline, is in **[ROADMAP.md](ROADMAP.md)**.

In short (plans, not promises):

- Reaching it from the network: the API behind a token, the desk display over Wi-Fi
- More renderers with their own progress
- Optional controls: pause, resume, lower priority
- Signed and notarised releases, Homebrew, more UI languages

## Development

| Command | What it does |
|---|---|
| `zsh scripts/build-app.sh` | Builds `build/RenderDock.app` (ad-hoc signed; the icon is drawn by the app itself) |
| `zsh scripts/install.sh [--login]` | Builds, installs to `/Applications`, relaunches |
| `swift run rd-checks` | Checks for the core: parsing, events, the API, notifications, agents, the device protocol (534 checks) |
| `.build/release/RenderDock --dump` | Prints detected jobs and metrics as text, no UI |
| `.build/release/RenderDock --snapshot DIR [--demo]` | Renders the capsule and the panel to PNG |
| `zsh scripts/make-demo.sh` | Regenerates the screenshots and the GIF in `assets/` |
| `zsh scripts/fake-render.sh [frames] [sec/frame]` | A stand-in render for testing detection |
| `python3 scripts/verify-interactions.py <binary>` | Injects clicks and drags into an instance started with `--debug` and checks expanding, collapsing and snapping (12 checks) |

The code is plain Swift and SwiftUI with AppKit for the window: about 9,000 lines, no packages. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

RenderDock shares no code with these projects, but they showed what is possible without `sudo`: [Stats](https://github.com/exelban/stats) and [macmon](https://github.com/vladkens/macmon) for reading GPU and sensor data, and [boring.notch](https://github.com/TheBoredTeam/boring.notch) for making small always-there UI feel at home on a Mac.

A project with a similar goal: [Blender Render Monitor](https://github.com/DUBSON0/blender-render-monitor) also lists Blender renders on a Mac, and already has pause, resume and a queue. It gets progress from a Blender hook script or a log file. RenderDock 0.1 was written without knowing about it; the two share no code.

## License

[MIT](LICENSE)

# Roadmap and TODO

**English** · [简体中文](docs/i18n/ROADMAP.zh-CN.md)

Where RenderDock stands, what is missing, and what comes next. Last updated: 2026-11-24.

## Timeline

| When | Version | Theme | Status |
|---|---|---|---|
| 2026-11-23 | **0.1.0** | First release: detection, the capsule, system metrics | Released |
| Target: December 2026 | **0.2** | Exact progress, notifications, a local API | Planned |
| Target: January 2027 | **0.3** | History, more renderers, the first hardware displays | Planned |
| Target: February–March 2027 | **0.4** | Optional controls, preview, a desk display prototype | Planned |
| Later in 2027 | **1.0 and beyond** | Other machines, new UI forms, custom hardware | Ideas |

The dates are targets, not commitments. This is a one-person project; when priorities move, this file is updated rather than quietly ignored.

## Where 0.1 stands

### Done

- [x] Finds headless Blender jobs from the process tree, with no setup and no changes to scripts
- [x] Groups shots into job chains under the outermost script; card titles come from the script's first comment line
- [x] Reads queues from `scene:shot` arguments: done, rendering, paused, up next
- [x] Tells apart running, paused (`SIGSTOP`), stalled and queued
- [x] Frames done, seconds per frame, time left, and a thumbnail of the latest frame
- [x] Exact totals from `render-progress.json` and from Blender's command-line frame range (`-s -e -a`, `-f`)
- [x] Estimated totals from an older clip, always marked `≈`
- [x] System metrics without `sudo`: CPU, GPU utilisation, GPU memory, memory and pressure, swap, SoC temperature, free disk, power source, sleep assertions
- [x] Floating capsule: drag anywhere, snap to edges, corners and centres, remembered position, every Space, above full-screen apps
- [x] Panel that grows from whichever corner the capsule sits in; pin; collapse when you click elsewhere
- [x] Menu-bar item with a progress ring
- [x] Keep Awake While Rendering (opt-in) and Launch at Login
- [x] English and Simplified Chinese UI; README in ten languages
- [x] Demo mode, a fake-render script, a snapshot renderer and 12 automated interaction checks
- [x] Read-only, no network, no dependencies

### Checked and not checked

Checked on macOS 26.6 with an M5 Max and three displays: detection against real render queues, all 12 interaction checks, dragging and snapping with a real mouse, installing and registering the login item.

Not checked yet:

- [ ] macOS 14 and 15 (it compiles for 14; nobody has run it there)
- [ ] Intel Macs (the temperature tile is expected to show `–`)
- [ ] A real log-out and log-in with Launch at Login on
- [ ] Unplugging and re-plugging displays while it runs

### Missing in 0.1

Every gap below has a home in the plan that follows.

| Gap | Planned for |
|---|---|
| No percentage when the frame range lives inside the `.blend` | 0.2 |
| No progress inside a long frame (samples) | 0.2 |
| No notifications: a finished or stalled job goes unnoticed | 0.2 |
| Detection rules are hard-coded, including one adapter for the author's own pipeline | 0.2 |
| No way for anything else to read the state (no API, no CLI output for scripts) | 0.2 |
| No unit tests for the scanner | 0.2 |
| Not notarised, so no download and no Homebrew | 0.2, needs an Apple developer account |
| Blender only (plus bare `ffmpeg` processes without progress) | 0.3 |
| No history: time-left uses the last 30 frames and nothing is kept | 0.3 |
| Only this Mac | 1.0 and beyond |
| Read-only: no pause, resume or stop | 0.4, opt-in |
| Thumbnail only: no large preview, no scrubbing through frames | 0.4 |
| No fan speed, no power draw | 0.4 |
| Two UI languages | ongoing, contributions welcome |
| Dark capsule only: no light theme, no notch mode, no desktop widget | 1.0 and beyond |

## Plan by version

### 0.2 — know the real number, and say when it is done · target December 2026

- [ ] `renderdock run -- <command>`: a wrapper that runs your command unchanged, reads the renderer's own frame output and writes `render-progress.json`
- [ ] A small Blender add-on that writes progress after every frame, for people who render from the UI or from their own scripts
- [ ] Follow the log file when a render's output is redirected to one, reading Blender's own frame lines (the 4.x and the 5.x formats differ)
- [ ] Read the frame range stored in the `.blend` when it is not on the command line
- [ ] Progress inside a frame, so a ten-minute frame still moves
- [ ] macOS notifications: shot done, queue done, stalled, failed
- [ ] Phone notifications through services people already use (a webhook with ready-made templates)
- [ ] Adapter rules in a file instead of in code: what a process looks like, where its output is, where the total comes from
- [x] A local, read-only API on `127.0.0.1`: `GET /v1/state`, an event stream, and `--status --json` — see [docs/API.md](docs/API.md) *(done 2026-11-24, unreleased)*
- [x] Split the scanner from the UI (`RenderDockCore`) and give it checks: `swift run rd-checks`, 74 checks *(done 2026-11-24, unreleased)*
- [ ] Signed and notarised builds, a download and a Homebrew cask (depends on a developer account)
- [ ] First reports from macOS 14/15 and Intel
- [ ] Bring the README in all ten languages up to date for 0.2

Done when: a plain `blender -b file.blend -a` run through the wrapper shows an exact percentage; a finished queue reaches both the Mac and a phone; `curl` returns the same state the panel shows; the 12 interaction checks still pass.

### 0.3 — remember, and reach beyond Blender · target January 2027

- [ ] History in a local database: per-shot frame times, queue totals
- [ ] Time-left estimates for a whole queue, based on history
- [ ] Flag odd frames: a sudden jump in frame time, an unusually small file
- [ ] ffmpeg encodes with real progress
- [ ] ComfyUI queues
- [ ] MQTT publishing with Home Assistant discovery
- [ ] First off-the-shelf hardware: an LED strip as a progress bar, and a Stream Deck key (see below)

Done when: estimated and actual finish times are both on record for a week of real queues; one piece of hardware shows overall progress and changes when the queue finishes.

### 0.4 — hands on, carefully · target February–March 2027

- [ ] Optional controls, off by default: pause, resume, lower priority, start the next job when one ends
- [ ] Rules: pause on battery, pause when the Mac is throttling
- [ ] Large preview and scrubbing through rendered frames
- [ ] Fan speed and power draw; energy per job
- [ ] A desk display prototype on an off-the-shelf development board with a screen and a knob

Done when: controls can be enabled one by one and never act without being enabled; the prototype shows the current shot and overall progress over the local network or USB, and the knob switches jobs.

### 1.0 and beyond — ideas, in no fixed order

- [ ] Other machines: a small agent on a second computer or a cloud render node, reporting into the same capsule
- [ ] After Effects and other command-line renderers
- [ ] Notch mode, a desktop widget, a light theme
- [ ] A reference design for a dedicated desk device, if the prototype shows people want one

## Hardware

The idea is simple: once the app has a local API, a screen is only one of the places progress can appear.

| Tier | What | Needs |
|---|---|---|
| 1. Things you already own | Phone notifications; an LED strip that fills up like a progress bar; a Stream Deck key; smart-home lights that change when the queue is done | The 0.2 API and webhooks; 0.3 for MQTT |
| 2. A development board | A small round display with a knob on the desk: turn to switch jobs, glance for progress | The API over Wi-Fi or a USB serial bridge; open firmware in this repo |
| 3. A dedicated device | A reference design: display, knob, light ring, one cable | Only if tier 2 proves there is a point |

Nothing in tiers 2 and 3 exists yet. It will be designed in the open, and the protocol will stay documented so anyone can build their own display.

## Changing this plan

Open an issue if something here would change how you use RenderDock, or if a gap that matters to you is missing from the list. Bug reports from untested systems (macOS 14/15, Intel) are the most useful thing anyone can send right now.

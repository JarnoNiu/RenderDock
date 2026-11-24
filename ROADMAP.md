# Roadmap and TODO

**English** · [简体中文](docs/i18n/ROADMAP.zh-CN.md)

Where RenderDock stands, what is missing, and what comes next. Last updated: 2026-11-24.

## Timeline

| When | Version | Theme | Status |
|---|---|---|---|
| 2026-11-23 | **0.1.0** | First release: detection, the capsule, system metrics | Released |
| 2026-11-24 | **0.2.0** | Exact progress, notifications, a local API | Released |
| Target: January 2027 | **0.3** | History, more renderers, the first hardware displays | Planned |
| Target: February–March 2027 | **0.4** | Optional controls, preview, a desk display prototype | Planned |
| Later in 2027 | **1.0 and beyond** | Other machines, new UI forms, custom hardware | Ideas |

The dates are targets, not commitments. 0.2 arrived ahead of its December target; that is no promise about the ones below. This is a one-person project, and when priorities move, this file is updated rather than quietly ignored.

## Where 0.2 stands

### Done in 0.1

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

### Done in 0.2

- [x] `renderdock run -- <command>`: runs a command unchanged and reads the renderer's own output for exact progress, even when neither the range nor the output folder is on the command line — [docs/EXACT-PROGRESS.md](docs/EXACT-PROGRESS.md)
- [x] A Blender hook (a `--python` script that is also an add-on), for renders that cannot be wrapped
- [x] Progress inside a frame: a half-sampled frame counts as half a frame
- [x] Finished or failed: a wrapped job's exit status travels with the `job.ended` event
- [x] Notifications on the Mac, opt-in — [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md)
- [x] Notifications on a phone through Bark, ntfy, Feishu, WeCom, DingTalk, Telegram or a generic webhook, configured in your own file
- [x] A local, read-only API on `127.0.0.1`: `GET /v1/state`, an event stream, `renderdock status --json` — [docs/API.md](docs/API.md)
- [x] Adapter rules in a file: pipeline steps that are not a plain Blender render — [docs/ADAPTERS.md](docs/ADAPTERS.md)
- [x] The scanner split from the UI (`RenderDockCore`), with 132 checks: `swift run rd-checks`
- [x] README updated in all ten languages

### Checked and not checked

Checked on macOS 26.6 with an M5 Max and three displays: detection against real render queues; all 12 interaction checks; dragging and snapping with a real mouse; installing and registering the login item; real Blender 5.2 renders through the wrapper and through the hook on the command line; every push channel against a local stand-in server; the API with `curl`, including the requests it must refuse.

Not checked yet:

- [ ] macOS 14 and 15 (it compiles for 14; nobody has run it there)
- [ ] Intel Macs (the temperature tile is expected to show `–`)
- [ ] A real log-out and log-in with Launch at Login on
- [ ] Unplugging and re-plugging displays while it runs
- [ ] A macOS notification banner actually appearing (it needs a person to allow notifications first)
- [ ] The push channels against the real services (the project has no account with any of them)
- [ ] Blender 4.x: its output format is taken from Blender's source, and the hook has not been run there
- [ ] The hook as an add-on inside the Blender window

### Still missing

| Gap | Planned for |
|---|---|
| Detects only Blender on its own; other tools show up when wrapped, without their native progress | 0.3 |
| No following of a log file a render is redirected to; no reading of the frame range inside a `.blend` | 0.3 |
| The `scene:shot` queue convention is still built in rather than a rule | 0.3 |
| No history: time-left uses the last 30 frames and nothing is kept | 0.3 |
| Not notarised, so no download and no Homebrew | when there is an Apple developer account |
| The API is local only; nothing on the network can read it | 0.3, opt-in, with a token |
| Read-only: no pause, resume or stop | 0.4, opt-in |
| Thumbnail only: no large preview, no scrubbing through frames | 0.4 |
| No fan speed, no power draw | 0.4 |
| Only this Mac | 1.0 and beyond |
| Two UI languages | ongoing, contributions welcome |
| Dark capsule only: no light theme, no notch mode, no desktop widget | 1.0 and beyond |

## Plan by version

### 0.3 — remember, and reach beyond Blender · target January 2027

- [x] History in a local database: every shot with its duration, frames and outcome — [docs/HISTORY.md](docs/HISTORY.md) *(done 2026-11-24, unreleased)*
- [x] Time-left estimates for a whole queue, based on history *(done 2026-11-24, unreleased)*
- [x] Flag odd frames: a sudden jump in frame time, an unusually small file *(done 2026-11-24, unreleased)*
- [x] Coding agents' sessions, read-only: which are working, which just finished, which need you (Claude Code, Codex, Hermes) — [docs/AGENT-TASKS.md](docs/AGENT-TASKS.md) *(done 2026-11-24, unreleased)*
- [x] Events and notifications when a session starts to need you, fails or finishes a long turn; a summary for small displays — [docs/SMALL-DISPLAYS.md](docs/SMALL-DISPLAYS.md) *(done 2026-11-24, unreleased)*
- [ ] ffmpeg encodes with real progress
- [ ] ComfyUI queues
- [x] Follow the log file when a render's output is redirected to one *(done 2026-11-24, unreleased)*
- [ ] Read the frame range stored in the `.blend` when it is not on the command line
- [ ] Queue conventions as rules instead of code
- [ ] MQTT publishing with Home Assistant discovery
- [ ] Access to the API from the local network: a separate switch, off by default, with a token
- [ ] First off-the-shelf hardware: an LED strip as a progress bar, and a Stream Deck key (see below)
- [ ] First reports from macOS 14/15 and Intel

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

### Whenever there is an Apple developer account

- [ ] Signed and notarised builds, a download, a Homebrew cask

## Hardware

The idea is simple: now that the app has a local API, a screen is only one of the places progress can appear.

| Tier | What | Needs |
|---|---|---|
| 1. Things you already own | Phone notifications (in 0.2); an LED strip that fills up like a progress bar; a Stream Deck key; smart-home lights that change when the queue is done | The 0.2 API; 0.3 for MQTT and network access |
| 2. A development board | A small round display with a knob on the desk: turn to switch jobs, glance for progress | The API over a USB serial bridge or Wi-Fi; open firmware in this repo |
| 3. A dedicated device | A reference design: display, knob, light ring, one cable | Only if tier 2 proves there is a point |

Nothing in tiers 2 and 3 exists yet. It will be designed in the open, and the protocol will stay documented so anyone can build their own display.

## Changing this plan

Open an issue if something here would change how you use RenderDock, or if a gap that matters to you is missing from the list. Bug reports from untested systems (macOS 14/15, Intel) and from the real push services are the most useful thing anyone can send right now.

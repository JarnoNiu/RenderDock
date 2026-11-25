# Roadmap and TODO

**English** · [简体中文](docs/i18n/ROADMAP.zh-CN.md)

Where RenderDock stands, what is missing, and what comes next. Last updated: 2026-11-25.

## Timeline

| When | Version | Theme | Status |
|---|---|---|---|
| 2026-11-23 | **0.1.0** | First release: detection, the capsule, system metrics | Released |
| 2026-11-24 | **0.2.0** | Exact progress, notifications, a local API | Released |
| 2026-11-25 | **0.3.0** | History, coding agents, a display on the desk, more than Blender | Released |
| Target: February–March 2027 | **0.4** | The desk display in pages, reaching it from the network, optional controls, preview | Under way |
| Later in 2027 | **1.0 and beyond** | Other machines, new UI forms, custom hardware | Ideas |

The dates are targets, not commitments. 0.2 and 0.3 arrived ahead of their targets (December and January); that is no promise about the ones below. This is a one-person project, and when priorities move, this file is updated rather than quietly ignored.

0.3 grew on the way: coding agents and a display on the desk, which were further out, came in. One thing planned for it moved out: access to the API from the local network is now in 0.4.

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
| Detects only Blender on its own; other tools show up when wrapped, without their native progress | 0.3, done for ffmpeg; a ComfyUI queue is shown without a percentage |
| No following of a log file a render is redirected to | 0.3, done |
| No reading of the frame range inside a `.blend` | 0.3, done |
| The `scene:shot` queue convention is still built in rather than a rule | 0.3, done |
| No history: time-left uses the last 30 frames and nothing is kept | 0.3, done |
| Not notarised, so no download and no Homebrew | when there is an Apple developer account |
| The API is local only; nothing on the network can read it | 0.4, opt-in, with a token: built |
| Read-only: no pause, resume or stop | 0.4, opt-in: pause and resume built; RenderDock still ends nothing |
| Thumbnail only: no large preview, no scrubbing through frames | 0.4: built |
| No fan speed, no power draw | 0.4: built |
| Only this Mac | 1.0 and beyond |
| Two UI languages | ongoing, contributions welcome |
| Dark capsule only: no light theme, no notch mode, no desktop widget | 1.0 and beyond |

## Plan by version

### 0.3 — remember, watch the agents, and a display on the desk · released 2026-11-25

- [x] History in a local database: every shot with its duration, frames and outcome — [docs/HISTORY.md](docs/HISTORY.md) *(done 2026-11-24)*
- [x] Time-left estimates for a whole queue, based on history *(done 2026-11-24)*
- [x] Flag odd frames: a sudden jump in frame time, an unusually small file *(done 2026-11-24)*
- [x] Coding agents' sessions, read-only: which are working, which just finished, which need you (Claude Code, Codex, Hermes) — [docs/AGENT-TASKS.md](docs/AGENT-TASKS.md) *(done 2026-11-24)*
- [x] Events and notifications when a session starts to need you, fails or finishes a long turn; a summary for small displays — [docs/SMALL-DISPLAYS.md](docs/SMALL-DISPLAYS.md) *(done 2026-11-24)*
- [x] Follow the log file when a render's output is redirected to one *(done 2026-11-24)*
- [x] Answering an agent's permission request from the panel, off by default: only kinds you have said may be answered from a display, shown whole, once, and written to a record — [docs/ANSWERING-AGENTS.md](docs/ANSWERING-AGENTS.md) *(done 2026-11-25)*
- [x] A Bluetooth display on the desk, off by default: the Hardware Buddy protocol, so a device built for the Claude desktop apps shows RenderDock's renders and agents — [docs/DEVICES.md](docs/DEVICES.md) *(done 2026-11-25)*
- [x] Open firmware for one board, a 2.16-inch touch display: the render's ring, the agents, a list, sounds, and requests and questions answered by holding a button — [firmware/desk-display](firmware/desk-display/README.md) *(done 2026-11-25)*
- [x] An entry for other programs, off by default: `renderdock notify`, `progress` and `ask`, so any script or agent can post a notice, report progress, or ask a question and get the answer — [docs/AGENT-ENTRY.md](docs/AGENT-ENTRY.md) *(done 2026-11-25)*
- [x] ffmpeg encodes with real progress, when wrapped or when their output goes to a log file — [docs/EXACT-PROGRESS.md](docs/EXACT-PROGRESS.md#ffmpeg-from-03) *(done 2026-11-25)*
- [x] ComfyUI queues: which prompt is running, how many are done and waiting. No percentage: ComfyUI gives that only to the tab that queued the prompt — [docs/COMFYUI.md](docs/COMFYUI.md) *(done 2026-11-25; checked against a stand-in, not a real ComfyUI)*
- [x] Read the frame range stored in the `.blend` when it is not on the command line *(done 2026-11-25)*
- [x] Queue conventions as rules instead of code — [docs/ADAPTERS.md](docs/ADAPTERS.md) *(done 2026-11-25)*
- [x] MQTT publishing with Home Assistant discovery, off unless set up — [docs/MQTT.md](docs/MQTT.md) *(done 2026-11-25; checked against a stand-in broker, not a real one)*
- [x] First off-the-shelf hardware, as examples on top of the local API: an LED strip as a progress bar, and a Stream Deck key — [examples](examples) *(done 2026-11-25; neither has been run on the real hardware yet)*
- [ ] First reports from macOS 14/15 and Intel

Done when: estimated and actual finish times are both on record for a week of real queues; one piece of hardware shows overall progress and changes when the queue finishes.

Where that stands: the desk display is that piece of hardware. History has been recording since 2026-11-24, so the week was not up when 0.3 was released. It also turned out that 0.3 kept what happened and not what had been estimated: the estimates are written down from 0.3.1 on (`renderdock estimates`), and the comparison is owed until a week of them is on record.

### 0.4 — beyond this Mac, and hands on, carefully · target February–March 2027

- [x] The desk display in three pages instead of one screen: the renders, the agents, and this Mac itself (processor, graphics, memory, heat, disk, power, sleep), with the two kinds of task no longer mixed in one list. Built on the branch `feat/device-pages` and running on one board; turning the pages with a real finger and the real key has not been tried yet
- [x] Access to the API from the local network: a separate switch, off by default, with a token. Plain HTTP, so for a network you trust; see [docs/API.md](docs/API.md). Read by a second real device (the desk display, over Wi-Fi) with the token, and refused with a wrong one
- [x] The desk display over Wi-Fi as well as Bluetooth: where Bluetooth does not reach, it reads the same lines from the API on the local network. Set up from the menu (the display lists the networks it sees; the password is typed, and RenderDock does not keep it); it only shows that way, and Bluetooth comes first. See [docs/DEVICES.md](docs/DEVICES.md). Run on one board on a real network, with "no Bluetooth" put on from its console; **not yet with the board really out of Bluetooth's reach**
- [x] The entry for other programs as an MCP server (`renderdock mcp`), for agents that would rather call a tool than run a command. Run against a stand-in client; not yet with a real agent's client
- [x] Optional controls, off by default, each its own switch: pause and resume from the dock, move a render out of the way and back, and one job at a time (the next goes on when one ends). See [docs/CONTROLS.md](docs/CONTROLS.md). Checked on a stand-in process and against made-up jobs; **not yet with a switch on over a real render**
- [x] Rules: pause on battery, pause when the Mac is slowed down for heat; each lets go again by itself, and only of what it stopped
- [x] Large preview and scrubbing through rendered frames: click a shot's thumbnail. Run on made-up frames; not yet on a real render's folder
- [x] Fan speed and power draw, in the dock, the API and on the desk display's page for the Mac; what each shot drew, kept with the history (the whole Mac's draw, shared among shots rendering together: see [docs/HISTORY.md](docs/HISTORY.md))

Done when: another device on the network can read the state with the token and cannot without it; controls can be enabled one by one and never act without being enabled.

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
| 1. Things you already own | Phone notifications (in 0.2); an LED strip that fills up like a progress bar and a Stream Deck key (examples in 0.3); smart-home lights that change when the queue is done (MQTT in 0.3) | The 0.2 API, or MQTT; 0.4 for reaching the API from another device |
| 2. A development board | A small touch display on the desk: glance for progress, hold a button to answer an agent | Bluetooth LE; open firmware in this repo, for one board so far |
| 3. A dedicated device | A reference design: display, knob, light ring, one cable | Only if tier 2 proves there is a point |

Tier 2 exists for one board, in [firmware/desk-display](firmware/desk-display/README.md) (released with 0.3). Tier 3 does not exist. Whatever comes is designed in the open, and the protocol stays documented so anyone can build their own display.

## Changing this plan

Open an issue if something here would change how you use RenderDock, or if a gap that matters to you is missing from the list. Bug reports from untested systems (macOS 14/15, Intel) and from the real push services are the most useful thing anyone can send right now.

# Contributing

Thanks for taking a look. RenderDock is small on purpose: plain Swift and SwiftUI, no packages. `RenderDockCore` finds jobs and reads the machine and has no UI; `RenderDock` is the app on top of it.

## Build and check

```bash
zsh scripts/build-app.sh                      # build/RenderDock.app
swift run rd-checks                           # checks for the core (parsing, events, the API); exits non-zero on failure
.build/release/RenderDock --dump              # what the scanner sees, as text
.build/release/RenderDock --snapshot /tmp/rd --demo   # the UI as PNG, with demo data
```

To test the window behaviour, start an instance with the debug channel and run the interaction checks:

```bash
open build/RenderDock.app --args --debug
python3 scripts/verify-interactions.py build/RenderDock.app/Contents/MacOS/RenderDock
```

The checks inject synthetic clicks and drags and read the window state back. They move the widget around the main display for about fifteen seconds. Real-mouse click-through and collapse-on-outside-click cannot be simulated this way, so try those by hand.

`zsh scripts/fake-render.sh 60 1` gives the scanner something to find without Blender.

## Where things are

| File | What lives there |
|---|---|
| `RenderDockCore/Scanner.swift` | Process tree → job chains → shots; frame counting; where totals come from |
| `RenderDockCore/Proc.swift` | Thin wrappers over `libproc` and `sysctl` |
| `RenderDockCore/Metrics.swift` | CPU, GPU, memory, temperature, power, sleep assertions |
| `RenderDockCore/Snapshot.swift` | The state document every display reads (the wire format of the API), with the summary for small displays ([docs/SMALL-DISPLAYS.md](docs/SMALL-DISPLAYS.md)) |
| `RenderDockCore/Events.swift` | What changed between two scans: `job.started`, `shot.done`, `agent.waiting`, … |
| `RenderDockCore/APIServer.swift` | The local read-only API on `127.0.0.1` ([docs/API.md](docs/API.md)) |
| `RenderDockCore/Progress.swift` | Reading a renderer's output for progress; the report a wrapped job keeps ([docs/EXACT-PROGRESS.md](docs/EXACT-PROGRESS.md)) |
| `RenderDockCore/History.swift` | What is remembered (SQLite), queue estimates from it ([docs/HISTORY.md](docs/HISTORY.md)) |
| `RenderDockCore/LogFollower.swift` | Reads the log a render's output is redirected to |
| `RenderDockCore/Agents.swift` | Coding agents' sessions, read-only: Claude Code, Codex, Hermes ([docs/AGENT-TASKS.md](docs/AGENT-TASKS.md)) |
| `RenderDockCore/Adapters.swift` | Detection rules read from `adapters.json` ([docs/ADAPTERS.md](docs/ADAPTERS.md)) |
| `RenderDockCore/Notify.swift` | Notification wording and the request each push channel needs ([docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md)) |
| `renderdock-cli/` | The `renderdock` command: `run`, `status`, `history` and `agents`. Built as `renderdock-cli`, shipped as `Contents/Helpers/renderdock` |
| `RenderDockCore/L10n.swift` | `L(zh, en)`: UI strings live at the call site in both languages |
| `RenderDock/Store.swift` | Observable app state and timers |
| `RenderDock/Views.swift`, `Theme.swift` | The capsule, the panel and their parts |
| `RenderDock/Window.swift` | The floating panel: dragging, snapping, expanding, click-through |
| `RenderDock/App.swift` | Menu-bar item, app delegate, debug channel |
| `RenderDock/Notifier.swift` | Delivers notifications: macOS and the channels in `notify.json` |
| `RenderDock/Demo.swift` | Demo data and the reel used for the README GIF |
| `blender/renderdock_hook.py` | The Blender hook: reports from inside Blender, as a `--python` script or an add-on |
| `Tests/rd-checks/` | The core's checks. A plain executable, so it runs with the Command Line Tools alone |

## Ground rules

- **Read-only stays read-only.** The scanner must never signal a process or write into someone's render folder. Controls, if they come, will be opt-in and separate.
- **No invented numbers.** A percentage needs a known total. An estimate must be marked `≈`. When in doubt, show less.
- **No dependencies** without a very good reason.
- **The API only grows.** Fields in `docs/API.md` are added, never renamed or removed, and nothing in it may carry a file-system path.
- Screenshots and GIFs in the repo come from `scripts/make-demo.sh` (demo data only). Please do not commit captures of real projects.

## Good first contributions

- Reports from macOS 14/15 and Intel Macs: does it build, what does `--dump` print, which tiles show `–`?
- Detection for another renderer or tool, ideally with a `fake-render`-style script that proves it.
- UI translations: add a language to `L10n.swift` and the call sites, and check the layout with `--snapshot`.
- README translations and corrections in `docs/i18n/`.

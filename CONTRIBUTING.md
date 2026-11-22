# Contributing

Thanks for taking a look. RenderDock is small on purpose: plain Swift and SwiftUI, no packages, one target.

## Build and check

```bash
zsh scripts/build-app.sh                      # build/RenderDock.app
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
| `Scanner.swift` | Process tree → job chains → shots; frame counting; where totals come from |
| `Proc.swift` | Thin wrappers over `libproc` and `sysctl` |
| `Metrics.swift` | CPU, GPU, memory, temperature, power, sleep assertions |
| `Store.swift` | Observable app state and timers |
| `Views.swift`, `Theme.swift` | The capsule, the panel and their parts |
| `Window.swift` | The floating panel: dragging, snapping, expanding, click-through |
| `App.swift` | Menu-bar item, app delegate, debug channel |
| `Demo.swift` | Demo data and the reel used for the README GIF |
| `L10n.swift` | `L(zh, en)`: UI strings live at the call site in both languages |

## Ground rules

- **Read-only stays read-only.** The scanner must never signal a process or write into someone's render folder. Controls, if they come, will be opt-in and separate.
- **No invented numbers.** A percentage needs a known total. An estimate must be marked `≈`. When in doubt, show less.
- **No dependencies** without a very good reason.
- Screenshots and GIFs in the repo come from `scripts/make-demo.sh` (demo data only). Please do not commit captures of real projects.

## Good first contributions

- Reports from macOS 14/15 and Intel Macs: does it build, what does `--dump` print, which tiles show `–`?
- Detection for another renderer or tool, ideally with a `fake-render`-style script that proves it.
- UI translations: add a language to `L10n.swift` and the call sites, and check the layout with `--snapshot`.
- README translations and corrections in `docs/i18n/`.

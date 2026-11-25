# Looks and places: the light theme, the notch, a desktop widget

From 0.4. Three ways for the dock to look different or to be somewhere else. None changes what it shows or how it finds it.

## Dark, light, or the system's

Menu-bar icon → **Appearance** → **Dark**, **Light** or **Follow the System**. (Or `defaults write io.github.jarnoniu.renderdock appearance light`, then relaunch.)

- **Dark** is what the dock always was, and stays the default.
- **Light** is the same build on a pale ground: the same layout, the same hairlines and shadow. The accents are deeper (a mint that is bright on dark cannot be read as text on white), and weak text is a little stronger than its dark counterpart.
- **Follow the System** switches with macOS, at once.

The larger look at a shot's frames stays dark in every case: a frame is judged best against black.

## Part of the notch

Menu-bar icon → **Form** → **Notch (at the top centre of the screen)**. **Floating Capsule** takes it back to where the capsule was left.

- On a screen with a notch, the dock becomes the notch grown wider: an ear on each side, the ring on the left and the one number that matters on the right (how far the render in front is; with no render, how many sessions want you or are at work). **With nothing going on the ears close up** and only the notch is left, which can still be clicked.
- A click opens the panel downwards from the top edge. The strip the notch takes is left to it, and the panel's content starts below. A click elsewhere closes it, as with the capsule.
- On a screen without a notch it is a small black island at the top edge, with the ring and one line.
- It goes to the screen that has a notch if one does, otherwise to the main screen, and follows when the lid is closed or opened. It does not drag: the notch is where it is.
- **It is black whatever the appearance**: it has to match the hardware.

What it costs: it lies over the middle of the menu bar. An app whose menus run that far, or a status item right beside the notch, is covered while the ears are out (and by the open panel, as wide as it is). That is the trade every notch tool makes; the capsule makes none of it.

## A widget on the desktop

RenderDock carries a widget: **Render Progress**, in the small square and two squares wide. Add it the way any widget is added: right-click the desktop → **Edit Widgets**, find RenderDock, drag it out.

| | Small | Medium |
|---|---|---|
| The render in front | The ring with its percentage, the shot, how long it has left | The same, with the job's name |
| The queue | | How many of the job's shots are through, and when the whole queue is expected to be |
| Agents | | Who wants you, or how many are at work |
| Nothing rendering | A line saying so | The same, with the agents' line |

**How fresh it is.** A widget is not a window: the system decides when it is drawn, and does not let an app redraw it every second. So:

- RenderDock asks for a new drawing when something changes that the widget could not foresee: another shot, a pause, a session starting to wait, the render drifting from its pace. Otherwise every ten minutes.
- In between, a render that says how far along it is and how long it has left is **carried forward a minute at a time** at that pace, so the ring moves. It is never carried past 99 percent (only RenderDock can say a shot is through) nor for more than a quarter of an hour.
- When RenderDock quits, the widget says it is not running. If RenderDock was killed, the widget stops believing a "rendering" that has not been confirmed for a while.

For anything exact, there is the dock.

**What the widget can reach.** It is an app extension and runs in a sandbox of its own. It may read one folder of yours, RenderDock's own (`~/Library/Application Support/RenderDock/`), where the app leaves it a small file, `widget.json`: the shot's and the job's names, the fraction, the times, a few counts. It has no network access, reads nothing else, and writes nothing there. It needs no switch: the Local API can stay off.

**Built without Xcode.** `scripts/build-app.sh` compiles the extension like the rest (`Sources/RenderDockWidget`), puts it in `Contents/PlugIns`, and signs it with its own entitlements (`scripts/widget.entitlements`) before the app is signed.

## What has and has not been checked

- **Checked**: the widget's data (what the app writes is what the widget reads; carrying a render forward; when it is believed; when the widget is asked to read again) has checks of its own. The light theme, the notch form closed and open, the island for a screen without a notch, and the widget's faces in both sizes and both looks were drawn into pictures from made-up data and looked at. On one Mac (macOS 26, built-in screen with a notch, two more without): the notch form sits flush with the top edge on the notch's centre line; macOS registered the widget extension from the installed app and started it once; a stand-in program signed with the widget's entitlements could read the app's folder, could not read another file of the user's nor list Documents, and could not write.
- **Not checked**: the widget actually placed on a desktop and watched over a render (how often the system really redraws it, whether the faded look of an unfocused desktop suits it); the notch form used for a day on the real notch (what it covers in the menu bar, how it sits beside the hardware's own corners); a MacBook without a notch, and a lid closed and opened while in the notch form; the light theme on every card (a request for permission, a question from another program were not in the pictures); macOS 14 and 15.

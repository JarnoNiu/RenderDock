# A device on the desk

> New in 0.3. Off by default. Run against one device so far: the [desk display](../firmware/desk-display/README.md) this project has firmware for. What that covered is at the end of this page.

RenderDock can feed a small Bluetooth device: a screen on your desk that shows how the renders and the agents are doing, and, if you allow it, lets you answer an agent's request with a tap.

It does this by speaking a protocol that already exists: the Hardware Buddy protocol of the Claude desktop apps, which Anthropic documents in [anthropics/claude-desktop-buddy](https://github.com/anthropics/claude-desktop-buddy/blob/main/REFERENCE.md) and says anyone may implement. RenderDock takes the desktop app's place on the link. A device built for that protocol, running the reference firmware or one of its ports, then shows RenderDock's state instead, with no change to its firmware.

## What the device is sent

One snapshot whenever something changes, and every ten seconds:

| Field | From RenderDock |
|---|---|
| `total` | Every agent session and every render job |
| `running` | Sessions working, plus shots rendering |
| `waiting` | Sessions that need you or failed, plus renders that look stalled |
| `msg` | The one-line summary, at most 23 characters of ASCII (see [SMALL-DISPLAYS.md](SMALL-DISPLAYS.md)); or `approve: Read` while a request is on the device |
| `entries` | Up to eight lines: requests that wait on the Mac, sessions that are doing something, shots in progress with their percentage |
| `prompt` | A request that may be answered on the device (see below) |

It is also sent the time, once, on connecting. It is **not** sent an owner name, which the protocol has a message for, and it is never sent a session's title.

### Extra fields for a device that asks for them

The protocol's own fields leave out what a screen would most like to draw: a render's percentage, and which session is which. A device can ask for more by adding `"rd": 1` to the data of its status answer, and `"utf8": true` if it can draw text beyond ASCII. On an encrypted link RenderDock then adds one key, `rd`, to each snapshot:

```json
"rd": {
  "state": "working",
  "top":   { "kind": "render", "name": "s040_explode", "pct": 62, "exact": true, "eta": 1500 },
  "job":   { "title": "Product film", "done": 3, "total": 8 },
  "agents": { "error": 0, "waiting": 0, "working": 2, "done": 1, "idle": 3 },
  "rows":  [ { "n": "s040_explode", "t": "", "s": "working", "p": 62 },
             { "n": "billing-api", "t": "Codex", "s": "working", "a": 913 } ],
  "left":  96
}
```

`state` and `top` are the summary from [SMALL-DISPLAYS.md](SMALL-DISPLAYS.md). `rows` has up to six lines, most urgent first: `n` a project or a shot, `t` the agent's name (empty for a render), `s` its state, `a` seconds in that state, `p` a render's percentage. `left` is how many seconds remain to answer the request on the device.

A device that does not ask never sees this key, so the reference firmware and its ports are unaffected. For a device that does ask, a request may be up to 120 characters long rather than 43; the device is then the one that decides whether it can show all of it.

A device that answers `"rd": 2` also says it can show what other programs send through RenderDock's [entry](AGENT-ENTRY.md). It is then sent, inside `rd`:

```json
"ask":  { "id": "kqmtv", "from": "planner", "text": "Which branch should the fix go on?", "choices": ["main", "release"], "left": 100 },
"note": { "id": "hbxwe", "from": "builder", "title": "Build", "body": "All 42 tests passed", "level": "done" }
```

`ask` is the oldest waiting question the device can draw, with the seconds left to answer it. `note` is the newest notice, for the first minute after it arrived; `level` is `info`, `done` or `error`. A task a program reports on appears in `rows` (`t` is whoever reports) and may be `top`, with `"kind": "task"`. The device answers a question with

```json
{"cmd":"choice","id":"kqmtv","index":1}
```

where `index` counts the answers from 0. This is a different message from the answer to a request, on purpose: a pick is never an approval. RenderDock takes it only for a question it offered on this connection, and only once.

RenderDock's own firmware for one board is in [firmware/desk-display](../firmware/desk-display).

## Answering on the device

This needs [answering agents](ANSWERING-AGENTS.md) switched on as well; without it there are no requests to send. It also needs a switch of its own, off to begin with: Desk Device → **Agents' Requests May Be Answered on the Device**. A device can show what is going on without being a place where things are approved, and that is how it starts.

A request goes to the device only when all of this holds:

- it is of a kind you have said may be allowed from a display (reading and searching, by default);
- the device can show **all** of it: the text fits the firmware's 43 bytes (which is fewer than 43 characters in most scripts other than Latin), and is plain ASCII unless the device can draw more (it can say so itself, or you can tell RenderDock);
- the link is encrypted.

Any other request shows on the device as a line saying it waits on the Mac, with nothing to tap.

An answer from the device is handled exactly like a click in the panel: it must be for a request RenderDock actually put on the device on this connection, it counts once, and it is written to the record with `device` as its source. The device can say `once` or `deny`. There is no "always".

For a device that takes the extra fields, the snapshot also says whose request it is, as `"by": {"n": "docs", "t": "Claude Code"}` inside `rd`. The top item is the most urgent thing going on, which may be another session altogether, so a device should not take the asker's name from there.

### What RenderDock cannot check

macOS does not tell an app whether a Bluetooth link is encrypted. RenderDock goes by what the device says about itself, after macOS has paired with it (the six digits you typed). So a device that lied would be sent names, and could answer whatever a device may answer. Two things keep that small:

- RenderDock goes back to the one device it first connected to and passes over every other, whatever it calls itself, until you choose **Forget This Device**.
- Answering requests on a device is a separate switch, and off unless you turn it on.

Pair only a device whose firmware you know.

## What is held back on an unencrypted link

The protocol lets a device skip pairing. Anything sent to such a device can be read by anyone nearby with a cheap radio. So until the device reports an encrypted link, RenderDock sends it **counts and the one-line summary only**: no project names, no lines, no requests.

The device reports this itself, in its answer to a status request. RenderDock cannot check it independently.

## Turning it on

Menu-bar icon → **Desk Device** → **Connect a Bluetooth Device**.

- The first time, macOS asks whether RenderDock may use Bluetooth. Until that switch is on, RenderDock does not touch Bluetooth at all.
- RenderDock connects to the first device it finds that advertises the protocol's service under a name starting with `Claude`, and remembers it. After that it only goes back to that one. **Forget This Device** makes it look again.
- If the device asks for pairing, macOS shows its own pairing prompt for the six-digit code on the device's screen.
- **The Device Can Show Chinese**: leave it off for the reference firmware, which has no font for it. Some ports do.

A device talks to one computer program at a time. While RenderDock is connected to it, the Claude desktop app's own Hardware Buddy cannot be, and the other way round.

If the link will not come up, `~/Library/Application Support/RenderDock/device-link.log` says how far it got: the last hundred or so events (scanning, connecting, a write refused, what the device said about itself), with times. It holds no content: not what was sent, not a session's name, not the pairing code.

## What has and has not been checked

- **Checked**: the protocol half. What goes into a snapshot, the limits, what is held back, which requests are offered, how the device's lines are put back together and read. These are covered by checks that need no device.
- **Checked with one device** (the desk display in [`firmware/desk-display`](../firmware/desk-display/README.md), on a Waveshare ESP32-S3-Touch-AMOLED-2.16): finding it, connecting, pairing by typing the six digits from its screen, the encrypted link, the snapshot with RenderDock's own fields and Chinese text arriving and being drawn, and going back to it without pairing again after the device restarts.
- **Checked once with the same device**: a notice, a task and a question from another program ([AGENT-ENTRY.md](AGENT-ENTRY.md)) arriving over Bluetooth, and a pick made on the device coming back and reaching the program that asked.
- **Not checked**: an answer to a *request for permission* coming back from the device over Bluetooth; the reference firmware and other ports; a device that does not ask for pairing.

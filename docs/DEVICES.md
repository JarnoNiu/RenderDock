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

It is also sent the time, once, on connecting. It is **not** sent an owner name, which the protocol has a message for, and it is not sent a session's title unless you switch that on (below).

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

### A page for each side, and one for the Mac (`"rd": 3`, from 0.4)

`state` and `top` above are renders and agents taken together: the most urgent thing, and nothing about the side that is less urgent. A device that keeps the two on pages of their own answers `"rd": 3`, and is then told about each side by itself, inside `rd`:

```json
"r": { "state": "working",
       "top":  { "name": "s040_explode", "pct": 62, "exact": true, "eta": 1500 },
       "job":  { "title": "Product film", "done": 3, "total": 8 },
       "n":    { "run": 2, "queue": 4 }, "qeta": 21900,
       "rows": [ { "n": "s040_explode", "s": "working", "p": 62 }, { "n": "s045_explode_alt", "s": "working", "p": 18 } ] },
"a": { "state": "waiting",
       "top":  { "kind": "agent", "name": "docs", "tool": "Claude Code", "wait": "permission", "age": 42 },
       "rows": [ { "n": "docs", "t": "Claude Code", "s": "waiting", "a": 42 }, { "n": "billing-api", "t": "Codex", "s": "working", "a": 913 } ] }
```

- `r` is the renders: its own `state` (a failed render is `error`, one that stopped moving `waiting`), the shot furthest along, the job that shot belongs to, how many shots are being rendered (`run`) and how many wait their turn (`queue`), and the seconds until that job's whole queue is through (`qeta`, when RenderDock can say).
- `a` is the agents' sessions, with the tasks other programs report on: `top.kind` is `agent` or `task`, `age` the seconds it has been in its state.
- Each side has its own `rows`, up to six. The one list `rd.rows` is then left out.

Such a device is also sent, **on lines of their own**, how the Mac itself is doing:

```json
{"mac":{"ac":true,"awake":true,"cores":10,"cpu":37,"disk":212,"fan":35,"gpu":92,"mem":[21.4,32],"mp":1,"swap":1.2,"t":71,"th":0,"tmax":78,"vram":8.2,"w":86}}
```

`cpu` and `gpu` are percentages; `mem` is used and total in GB, `mp` the system's memory-pressure level (1, 2 or 4), `swap` and `vram` GB; `t` and `tmax` the chip's temperature in °C, average and hottest sensor, `th` the system's own word for the heat (0 fine, 1 warm, 2 slowed down, 3 critical); `disk` the free space in GB; `ac` whether it is on the adapter, `bat` the battery's percentage when there is one; `awake` whether something keeps it from idle sleep; `w` what the whole machine is drawing in watts, and `fan` how hard its fans work, as a percentage between their slowest and fastest. What the Mac could not read is left out, not sent as nought. A line goes out every four seconds at most, only when it differs from the last one, only on an encrypted link, and once more with each keepalive so the device can tell "unchanged" from "gone quiet".

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

The Wi-Fi settings below (a network's password, the API's token) are handed over on the same word: an "encrypted link" is what the device says it has.

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

### When the device has lost the pairing and the Mac has not

A device whose whole flash was written again, or whose memory was cleared, no longer has its half of the pairing. The Mac still has the other half, and macOS will not pair a second time on its own: every connection is refused before it starts (`CBErrorDomain 14` in the log), and no six digits appear. Up to 0.3.0 RenderDock tried again every three seconds and said nothing but "Connecting". From 0.3.1:

- the menu says ***name* no longer has its pairing with this Mac**, and under it what to do: forget the device in System Settings → Bluetooth (the ⓘ beside it → **Forget This Device**) and wait half a minute;
- it tries again every fifteen seconds instead of every three. Each try is refused within a second anyway, and macOS takes about half a minute to let go of a pairing once the device is forgotten, which goes better when nothing is asking it to connect all the while.

The first connection after that pairs afresh. **Forget This Device** in RenderDock's own menu is another matter (which device RenderDock goes back to); it should not be needed here, since the device keeps the identifier macOS knows it by, though that has not been run both ways. If a minute after forgetting the device is still listed under My Devices, forget it again. A connection that hangs although the device is plainly there is cleared by turning the Mac's Bluetooth off and on.

## Sessions' titles on the device (0.4, off by default)

A session is shown on the device by its project. Two sessions in one project read the same, and a chat that has no project reads only "chat". What tells them apart is the title, and a title says what you are working on: so it is not sent unless you say so.

Menu-bar icon → **Desk Device** → **Show Sessions' Titles on the Device**. It asks first, and says what follows:

- Each session with a title is then shown by it, in the list and on the line on top. One without a title keeps its project. Nothing else changes: the same field of the same lines carries the title where it carried the project.
- **Over the encrypted Bluetooth link only.** A link that is not encrypted gets no title, and neither does a display reading over Wi-Fi, whose stream is plain HTTP: there it goes on showing projects. This is seen to where the lines are built, whatever the switch says.
- Titles do not appear in the API, in events or in notifications because of it.
- The device has room for about a dozen Chinese characters on the top line and about seven in a list row; a longer title is cut in the middle, so its beginning and its end stay.

Switched off, the device is back to projects with the next line it is sent.

## Over Wi-Fi, where Bluetooth does not reach (0.4)

Bluetooth gets a display across a desk, not across a studio. A display that has Wi-Fi (the [desk display](../firmware/desk-display/README.md) does) can read the same lines from RenderDock's API on the local network instead, whenever no paired computer is on Bluetooth.

**Setting it up**, with the display on the encrypted Bluetooth link: menu-bar icon → **Desk Device** → **Let It Use Wi-Fi Where Bluetooth Does Not Reach…**. The sheet lists the networks **the display itself can see** from where it stands, strongest first: pick the one this Mac is on, type its password, and confirm. (A network that hides its name can be typed instead.) RenderDock does not read this Mac's own Wi-Fi name, nor any password the Mac has stored: the names come from the display, the password from you.

The list is the display's answer to `{"cmd":"wifi","scan":true}`, a few seconds later: `{"ack":"wifi","ok":true,"nets":[{"n":"name","r":-48,"o":false},…]}`, each name once, twelve at most, with the signal in dBm and whether the network asks for no password.

On confirming, RenderDock hands the display four things over the encrypted link:

| | |
|---|---|
| The network's name and password | As picked and typed. RenderDock keeps neither |
| This Mac's name on the network and its address | The name (`….local`) is looked up first; the address is the fallback |
| The API's port | |
| The API's token | The one **The API from the Local Network** uses ([API.md](API.md#from-the-local-network-04-off-by-default)) |

As a line: `{"cmd":"wifi","ssid":…,"pass":…,"host":…,"ip":…,"port":…,"token":…}`. `{"cmd":"wifi","off":true}` (**Have It Forget Wi-Fi** in the menu) makes the display stop using all of it and mark it erased, its radio's own copy of the network included. Erased is not overwritten: flash keeps old bytes until that part of it is reused, so somebody with the board and the tools could still find them for a while. To be sure, erase the board's flash (`esptool erase-flash`), which also empties its pairing. The same command with no `ssid` only says where the Mac is now; see below.

What that means, and the sheet says so before anything is sent:

- **It switches on the Local API and access to it from the local network**, if they were off: that is what the display reads. Access from the network has a token and no encryption, so it is for a network you trust. Switching either off again later is up to you; the display then says the computer is not answering.
- **The display keeps the password and the token on itself, unencrypted.** Whoever has the board and connects it to a computer can read them out of its flash. Renew the token (**New Token**) if the board leaves your hands, and think of the network's password as known to whoever has it.
- **It is for a network you trust.** The display finds this Mac by its name on the network and sends the token there in the clear. On a network where somebody else can answer to that name, the token goes to them, and with it everything the API shows.
- **Over Wi-Fi the display only shows.** RenderDock builds what it sends that way without anything that could be answered (no request for permission, no question from another program), and the display obeys no command and sends no answer over Wi-Fi. Answering stays on the encrypted Bluetooth link. It makes no sound for what arrives that way, and takes the time from there only if it has none yet.
- **Bluetooth comes first.** The display turns Wi-Fi on only when no paired computer has been on Bluetooth for a quarter of a minute, and off again once one is back. Wi-Fi draws several times what Bluetooth does, which matters on a battery.

The menu then says how the display's Wi-Fi is doing, as the display reports it over Bluetooth (`"wifi"` in its answer to a status request). Asked over Bluetooth, a display is by then not using Wi-Fi, so what the menu mostly has to go on is `"wifiWas"`: how its last use went (3, 4, 5 or 6 below; absent if it has not been used since it was set up). While it is away, the display's own screen says the same in words.

| `wifi` | Meaning |
|---|---|
| absent, or 0 | Nothing has been set |
| 1 | Set, and not in use: Bluetooth is up |
| 2 | Joining the network |
| 3 | On the network and reading |
| 4 | Could not join: the name or the password is wrong, it is out of range, or the network is not one the display's radio can use (the desk display joins 2.4 GHz networks only) |
| 5 | The Mac would not have the token |
| 6 | On the network, and the Mac is not answering there |

**When something changes afterwards.** The Mac's address, the API's port and the token can all change (a new token above all, which shuts the display out). Each time the display that this Mac set up comes back on the encrypted Bluetooth link, RenderDock tells it where the Mac is now: name, address, port and token, without the network's password, which it does not have (`{"cmd":"wifi","host":…,"ip":…,"port":…,"token":…}`, no `ssid`; a display that already has exactly that does nothing). So after **New Token**, bring the display near once. A new network or a new password has to be set up again.

What it reads is [`GET /v1/device`](API.md#get-v1device-04). A display of your own can read the same stream.

## What has and has not been checked

- **Checked**: the protocol half. What goes into a snapshot, the limits, what is held back, which requests are offered, how the device's lines are put back together and read. These are covered by checks that need no device.
- **Checked with one device** (the desk display in [`firmware/desk-display`](../firmware/desk-display/README.md), on a Waveshare ESP32-S3-Touch-AMOLED-2.16): finding it, connecting, pairing by typing the six digits from its screen, the encrypted link, the snapshot with RenderDock's own fields and Chinese text arriving and being drawn, and going back to it without pairing again after the device restarts.
- **Checked once with the same device**: a notice, a task and a question from another program ([AGENT-ENTRY.md](AGENT-ENTRY.md)) arriving over Bluetooth, and a pick made on the device coming back and reaching the program that asked.
- **Checked once with the same device (2026-11-25)**: a board whose whole flash had been erased and written with the released image, pairing again with a Mac that had forgotten it, and coming back after a restart without pairing.
- **Checked once with the same device (2026-11-26), Wi-Fi**: the display's list of networks arriving in the sheet; the settings handed over; the display joining a real network within two seconds, finding the Mac and reading `/v1/device` with the token; its three pages drawn from that; a wrong token refused by the Mac, and the right one told again by itself two seconds after Bluetooth was back; the radio going off again when Bluetooth returned; no growth in memory over repeated failed attempts to join a network that is not there. For all of it "no computer on Bluetooth" was put on from the display's bring-up console, with the Mac in fact still connected.
- **Not checked, Wi-Fi**: a display really out of Bluetooth's reach (the quarter-minute rule left to itself, and the walk back); the everyday build of the firmware; how long a battery lasts on Wi-Fi; a Mac whose address changes while the display is away; more than one display.
- **Not checked**: an answer to a *request for permission* coming back from the device over Bluetooth; the reference firmware and other ports; a device that does not ask for pairing; the "no longer has its pairing" line on a live link (what it recognises was seen in the log before the line existed, and the recognising has its own checks, but the pairing was not broken a second time to watch it).

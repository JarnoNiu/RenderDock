# RenderDock desk display

> Released with RenderDock 0.3, and run on one board so far. **It pairs with RenderDock over Bluetooth and shows what the Mac is doing; a question from another program has been answered on it with a finger. Answering an agent's request for permission from the device has not been tried over Bluetooth.** What has and has not been tried is under [Known limits](#known-limits).

Firmware for a small screen that sits on the desk and shows how the renders and the coding agents on a Mac are doing. If you allow it, it also lets you answer an agent's request with a finger.

One board is supported: the [Waveshare ESP32-S3-Touch-AMOLED-2.16](https://docs.waveshare.net/ESP32-S3-Touch-AMOLED-2.16/) (ESP32-S3, 480 × 480 AMOLED, capacitive touch, Bluetooth).

## What it talks to

It speaks the Hardware Buddy protocol, the one the Claude desktop apps use and Anthropic documents in [anthropics/claude-desktop-buddy](https://github.com/anthropics/claude-desktop-buddy/blob/main/REFERENCE.md): the Nordic UART Service over Bluetooth LE, one JSON object per line.

- **RenderDock** as the other end: see [docs/DEVICES.md](../../docs/DEVICES.md). The device tells RenderDock that it understands a few extra fields, and RenderDock then sends the render's percentage, a list of what is going on, and how long is left to answer a request.
- **The Claude desktop app** as the other end: it works with the protocol's own fields alone, and shows counts and the app's own lines.

A device talks to one of them at a time.

## The screens

| When | What is shown |
|---|---|
| Nothing has connected | The name to look for (`Claude-` and four characters), and where to switch the link on |
| Pairing | Six digits, to be typed on the computer |
| Something is rendering | A ring, the percentage, the time left, the shot and its job |
| Agents are working, nothing renders | How many, and the one on top |
| A session needs you, and it cannot be answered here | Amber, with a line saying it is to be handled on the computer |
| A request that may be answered here | Who asks and with which tool, what it asks, whole, and the time left; **Deny** and **Allow once**, each to be held for a second |
| Another program asks a question | In lilac, so it is not taken for a request: who asks, the question, whole, the time left, and its two to four answers, each to be held for a second |
| Another program sent a notice | A mark for how it went, the title, a few lines, and who sent it; for eight seconds, or until the screen is touched |
| Another program reports on a task | The ring and the percentage a render has, or three dots when it does not say how far along it is |
| Something finished or failed | Green or red, for a few minutes |
| Nothing is going on | A dim clock; later the panel switches off |

Swipe up for the list of what is going on, down to go back. The page turns once the finger has gone far enough; it does not wait for the finger to lift.

## The keys

| Key | A press | Held a second and a half |
|---|---|---|
| Power | Screen off, or on again. The link stays up, and news still lights the screen | "Do not disturb" on or off: no sound, and the screen lights up only for a request |
| KEY3 | Turns the page: main screen, list, main screen | Sound off or on |
| BOOT | Back to the main screen | Nothing. (Held while the board is powered up, this key puts the chip into its flashing mode; that is the chip's doing) |

- **No key answers a request**, and while a request is on the screen no key turns the page away from it.
- A press, or a touch, on a dark screen lights it and does nothing else.
- Held for four seconds, the power key cuts the power. The power chip does that by itself, whatever the firmware is doing.
- "Do not disturb" and "sound off" are remembered across restarts, and show as a word in the corner of the main screen.

## The sounds

A few notes each, worked out by the firmware as they are played; there are no sound files.

| When | What |
|---|---|
| A request to answer arrives | Two notes going up. Once more after half a minute if nobody has touched it, and then no more |
| Another program asks a question | The same two notes, once |
| Another program sent a notice | By how it went: the soft note, the three notes of "done", or the two of "failed" |
| A session needs you, and it cannot be answered here | One soft note |
| Something finishes | Three notes going up, and only if things had been going on for two minutes or more |
| Something fails | Two notes going down |
| You answer a request or a question with a finger | A small tick |

- Quiet by default: the volume is moderate, and between eleven at night and eight in the morning (by the clock the computer sets) nothing sounds at all.
- "Sound off" (KEY3, held) and "do not disturb" (power key, held) silence everything.
- The board has no speaker of its own: the amplifier's output goes to a two-pin socket (P10 in Waveshare's schematic), and a small speaker has to be plugged into it.
- The amplifier is switched on only while a sound plays, and it takes a fifth of a second to wake, so every sound starts that much after it is asked for.
- Each sound has been heard by the board's own microphones (see "Bringing a board up"), and the volume was picked by ear.

## Answering

**Every button is held, none is tapped.** On a screen this small a touch is too easily a mistake, so nothing on it answers anything at a touch: not Allow, not Deny, not an answer to a question. A button has to be held for a full second; it fills while the finger stays on it, and because a finger hides the button, the bar above it fills too. Lifting early, or sliding off the button, does nothing.

Nothing can be pressed while the six digits of a pairing are on the screen, whatever is underneath.

A hold counts only for what it began on. One that began before the request or question had been on the screen for 0.7 seconds does nothing (the finger was already on its way), and so does one during which the screen changed to another request or question.

### A request

- **Deny** and **Allow once** are both held.
- If the request does not fit on the screen in three lines, there is no Allow button, only a line saying it has to be read on the computer: what cannot be read whole cannot be allowed here. The same goes for a request that did not arrive whole, one with a character that has no shape on the screen, and one whose tool name does not fit its plate.
- The line at the top says whose request it is only if the computer said so with the request. It is never taken from "the most urgent thing going on", which may be somebody else.
- One answer per request.
- The keys never answer anything (see "The keys").

### A question from another program

Questions come through RenderDock's [entry for other programs](../../docs/AGENT-ENTRY.md). They are not requests for permission: the answer goes back to the program that asked, and nothing is allowed by it.

- An answer is picked by holding it. One pick per question.
- The answers go one under another when each can be tall enough for a finger; four that cannot go two by two. If the question does not fit in three lines, or the answers do not fit their buttons, nothing of it is shown: the screen says to answer on the computer.
- A press of KEY3 or BOOT puts the question aside on the device without answering it. It stays on the computer.
- A request for permission comes first: a question waits behind it.
- Nothing can be read from or written to the device until the Bluetooth link is encrypted, and it only becomes encrypted after the six digits have been typed on the computer.
- A computer that connects and never pairs is let go after two minutes, so it cannot keep the device's one connection to itself.

Which requests reach the device at all is RenderDock's decision, not the device's: see [docs/ANSWERING-AGENTS.md](../../docs/ANSWERING-AGENTS.md).

## Building

With [PlatformIO](https://platformio.org/) installed:

```bash
pio run
```

With the board on USB:

```bash
pio run -t upload
```

### A ready-made image

Each release of RenderDock from 0.3 on carries the firmware as one file, `renderdock-desk-display-<version>-esp32-s3-touch-amoled-2.16.bin`, with a text file of the licences of everything in it. It holds the start-up program, the layout of the flash, the program and the fonts, and is written at address 0: with a web flasher, or with

```bash
esptool --chip esp32s3 write-flash 0x0 renderdock-desk-display-<version>-esp32-s3-touch-amoled-2.16.bin
```

It is the everyday build, without the console. Writing it **empties what the board remembers**: the computer it is paired with, its volume, its touch correction. A board that is already set up takes the program alone, with `pio run -t upload`.

`sh tools/make-image.sh` makes the same file from this folder, after the fonts have been fetched (below). It refuses to finish if the file carries the user name of whoever built it.

### The fonts

The redesigned screens use Source Han Sans for Chinese and Nunito for numerals and Latin, both under the SIL Open Font License. They are not in this repository, and the device cannot read font files: each character is drawn ahead of time on a computer, at the three sizes the screens use, and the result is written to its own part of the flash.

```bash
sh tools/fetch-fonts.sh
```

```bash
sh tools/flash-fonts.sh /dev/cu.usbmodem1101
```

The first fetches the font files (about 33 MB, from the fonts' own repositories, at fixed revisions) into `fonts/`. The second draws the characters (`tools/make-fonts.swift`, which uses the Mac's text engine, so this step needs macOS) and writes the 10 MB file to the board. It is needed once, and again when the fonts or sizes change; flashing the program leaves it alone. `tools/font-preview.py` draws text from the file into a picture, to check it without a board.

A board without the font file still works: it shows the first, rougher screens (a bitmap font, shapes with stepped edges), which are kept in `src/ui.cpp` for that. The redesigned ones are in `src/screens.cpp`, drawn with `src/shapes.cpp` and `src/font.cpp`.

The file covers the characters of GB 2312 (6,763 Chinese characters and its symbols), ASCII and a few more signs. Anything else, traditional characters and rare ones among them, is shown as a hollow box.

`partitions.csv` divides the 16 MB of flash: 3 MB for the program, 12 MB for the fonts. The part that remembers paired computers stays where the stock layout has it, so a board flashed with the earlier layout keeps its pairing.

Flashing replaces whatever firmware is on the board, the factory demo included. Waveshare's documentation has the factory firmware if you want it back.

The platform, the compiler and the libraries all come from PlatformIO's registry; `platformio.ini` lists them.

## Bringing a board up

There is a second build with a console on the USB port, for checking a board without Bluetooth:

```bash
pio run -e debug -t upload
```

It logs what the board does as it starts, where a finger lands, when a key goes down and what happens on the Bluetooth link (that a line came or went and how long it was, never what it said, and never the six digits), draws a mark where it thinks the finger is, and only dims the panel when idle (the everyday build switches it off after five minutes). It takes these lines:

| Line | What it does |
|---|---|
| `shot` | Sends back the frame as the firmware drew it |
| a line of JSON | Is shown as if a paired computer had sent it, without the sounds that would go with it |
| `feed loud`, `feed quiet` | Lets fed snapshots make their sounds, and stops them again |
| `calibrate`, `calibrate off` | Measures the touch: nine crosses come up one after another, each to be held with a finger for a second, and for each the console gets where the cross is and where the finger was read. Nothing marks the reading on the screen, so the hand does not correct for it |
| `touchfix`, `touchfix SX OX SY OY`, `touchfix reset` | Prints the touch correction in use; sets and keeps one (read = scale × aimed + offset, for X and then for Y); removes it |
| `feed off` | Goes back to showing only what arrives over Bluetooth |
| `down X Y`, `up` | Puts a finger on the screen at a point, and lifts it |
| `passkey 123456`, `passkey 0` | Shows the pairing screen with those digits, and stops |
| `image SECONDS`, then a frame of pixels | Shows a picture on the panel for that long, or until the screen is touched. For looking at a drawing on the glass itself |
| `i2c` | Which chips answer on the board's shared bus |
| `pmu` | How the power chip is set up for its key, and what it says about power |
| `keylog` | What each of the three keys has done since start-up, as a pin and as the power chip reports it |
| `bench` | How long one frame takes to reach the panel |
| `stall` | The longest the main loop has been held up, and how long the last frame took to draw and to send |
| `ui old`, `ui new` | Switches between the first screens and the redesigned ones |
| `round 2`, `round 3` | The rounded face of the numerals: Nunito, or M PLUS Rounded |
| `quiet SECONDS` | Leaves what the paired computer sends unshown for that long, so a fed snapshot stays on the screen |
| `key power`, `key power long`, `key user`, `key user long`, `key boot` | As if that key had been pressed |
| `sound N` | Plays a sound whatever the hour and the switches say: 0 a request, 1 waiting, 2 done, 3 failed, 4 the tick |
| `volume N` | How loud, 0 to 100 (70 to begin with) |
| `listen` | Plays a steady tone and records it through the microphone chip: says whether the playback chip puts a signal out (the third input is wired to its output), whether the microphones hear it when the amplifier is on (a speaker is connected), and how long the amplifier takes to wake |
| `hear N` | Plays sound N as it is normally played while a microphone listens, and prints what it heard, 16 ms at a time |
| `rails` | Which of the power chip's outputs are on, and at what voltage |

`tools/console.py` drives it and saves the frames as PNG files; `tools/feeds.py` writes a set of made-up snapshots, one for each screen; `tools/sheet.py` puts frames side by side. Opening the port the usual way restarts the board; `console.py PORT noreset …` looks at it as it is.

**Do not leave this build on a board you use.** Whoever can reach its USB port can put a finger on "Allow" from the console. The everyday build (`pio run -t upload`) has none of it.

`tools/feeds.py` writes one snapshot per screen, the questions, notices and tasks included.

A snapshot fed in from the console may set the clock, and with it the hours the board keeps quiet. So fed snapshots make no sound unless `feed loud` was sent first. (They used to: a test that set the clock to the morning rang the board about ten times in the middle of the night.) After feeding a time, send the real one again, or reconnect the computer, which does.

A request or a question fed in from the console is marked as made up: answering it on the screen sends nothing to a paired computer. (At first it did. RenderDock ignored those answers, since it only takes an answer for a request it offered itself, but another program at the other end might not have.)

A frame from `shot` is what the firmware drew into memory. It does not show what the glass shows: whether the panel is the right way up, how bright it is, and whether a touch lands where the finger is have to be looked at on the board itself.

## What has been checked

On one board, with the `debug` build and made-up snapshots fed over USB:

- The power chip, the screen and the touch controller answer at start-up.
- Every screen in the table above draws as intended, in the first look and in the redesigned one, with the list, a request of one line and of two, one too long to allow here, and the plain protocol without RenderDock's fields.
- With a finger put down from the console: a second's hold on Deny answers "deny" and on Allow "once"; a touch of a third of a second on either does nothing; a hold on a request too long to show does nothing for Allow; a hold during which another request took the screen answers nothing; a swipe up opens the list and a swipe down closes it.
- The same for a question from another program: two, three and four answers, one under another and two by two, in Chinese and in English; a second's hold picks; a short touch, a slide to another answer, a hold begun as the question appeared, and a hold during which another question took its place pick nothing; a question too long shows nothing to press; KEY3 puts it aside. A notice goes at a touch, at a key, and by itself after eight seconds.
- By hand, on the board: the picture is the right way up, the panel dims and brightens, and a side key wakes the panel. (This line used to say that the mark that follows a finger sits under it. It did not: see "Things learned the hard way".)
- The touch, with a finger on nine crosses, twice: with the axes turned, the readings follow the crosses; what is left is a steady offset, measured and kept on the board as a correction.
- The keys, by events put in from the console and then by pressing them: the page turning, the two switches with their notices and the word in the corner, the screen going dark and a key or a touch lighting it, and a key doing nothing to a request on the screen. The board's log of the real presses shows KEY3 and BOOT presses of 90 to 200 ms all caught, the power chip reporting a short press when its key is let go and a long press at a second and a half while it is still held, and pin 16 going high for as long as the power key is down.
- Over Bluetooth, with RenderDock on a Mac: the Mac finds the device, the six digits come up and are typed on the Mac, the link comes up encrypted, authenticated and bonded, and the render's percentage, time left, name and job on the device match what the Mac reports. After the device restarts, the Mac is back within a few seconds without pairing again.

## Things learned the hard way

An independent read of this code before its first release found what the tests had not, because the tests were written by the same hand as the code. Among them: the line that says who is asking was taken from the most urgent item on the Mac, so one session's request could appear under another session's name; a run of closing punctuation was allowed to hang off the end of a line without limit, so a request could count as "three lines, fits" with its beginning pushed off the screen; a zero byte inside a text ended it early with nothing to show for it; and one reading without a finger counted as a lift, so a finger resting on the glass could start a hold it had never begun. Each is fixed, and each has a made-up snapshot in `tools/feeds.py` that shows it.

The touch controller's axes are a quarter turn from the picture's on this board: a finger further right was read as a finger further down. It went unnoticed for weeks. A swipe still turned the page (a sideways one, as it turned out), the mark that follows a finger in the bring-up build did move when the finger moved, and nobody had held a real finger on a button. The first person who did had to try three times, and it looked like the touch landing too low. Guessing at an offset would have made it worse; what found it was measuring: `calibrate` puts up nine crosses and prints where each press was read. `hwTouchRaw()` in `src/hw.cpp` now turns the axes. **A touch screen is not checked until a finger has been put on known points and the readings compared**: "it follows my finger" is not that.

The measuring screen had a mistake of its own the first time: each cross after the first was drawn where the one before it had been, so the readings were paired with the wrong targets. The numbers still told the story once they were shifted back by one, but a look at the frames from the dry run would have caught it before a person was asked to press anything.

With the axes right, a finger is still read a little away from where it aims: on this board, in this hand, about 19 pixels to the right and 9 below (1.6 mm and 0.7 mm). That is the hand as much as the glass, so it is not built in: `touchfix` keeps a correction on the board itself, and a board without one uses the readings as they are. After the correction the nine points were within 5 pixels on average.

The first sounds could not be heard at all, though the playback chip started and took every sample. The amplifier needs about 200 ms after it is switched on before anything comes out, and it was given 12; the sounds are short and loudest at their start, so they were over before it woke. What found this was the board listening to itself: the schematic has the playback chip's output wired back into the microphone chip (for echo cancelling), and the microphones sit beside the speaker. `listen` and `hear` on the console are that test. A board that cannot be heard can still say what it hears.

A change on the screen used to wait for the next regular frame, and when nothing is moving those come once a second: a swipe took up to a second to show. Whatever changes what is shown now asks for a frame at once (`s_dirty` in `src/ui.cpp`).

A board on a computer's USB port, with no program reading that port, used to stop for two seconds at every line it printed: the screen froze and the touch went dead with it. The firmware now never waits for the port (`Serial.setTxTimeoutMs(0)` in `setup()`); a line that does not fit is dropped. Keep it that way when adding log lines.

Measured on the board: one whole frame takes about 60 ms to reach the panel, so the screens are drawn for ten frames a second at most. The touch is read twice a frame, once before drawing and once before sending. The redesigned screens take 19 to 41 ms to draw; working out the ring afresh, which happens when the percentage or the kind of ring changes, adds about 100 ms to that one frame. Filling large areas pixel by pixel through the smooth-edge code made a screen take 100 ms; only corners and edges go that way now, and the rest is filled as plain runs.

## Known limits

- **Tried once**: a question from another program, sent by RenderDock over Bluetooth, answered with a real finger held on the screen, the pick arriving back at the program that asked.
- **Not yet tried**: answering a *request for permission* from the device over Bluetooth (those buttons have only been worked from the console, with nothing on the other end); the Claude desktop app as the other end; switching the panel off and waking it again; running from a battery.
- On the glass, one person has used the screens, answered a question with a finger and gone through the touch calibration. Nobody has judged the rest by eye yet: whether the small text is large enough at arm's length, and whether the corners of the panel cut anything.
- The released image was compared, part by part and byte for byte, with a board running those parts. That board kept its memory, so **a first start from an empty flash and a first pairing have not been run again on the released build**; they were last run on an earlier one.
- The everyday build has been on the board only long enough to see it start, find its fonts and go back to its computer over Bluetooth. Every screen was checked on the build with the console, which draws with the same code.
- There is next to no motion: the mark on the "needs you" screen breathes, and the hold on Allow shows as it goes.
- On the first screens (a board without the font file): a character the bitmap font does not have is left out without a trace.
- The microphones are used only by the bring-up tests.
- No rounded-corner safe area has been measured for this panel; the layout keeps away from the corners by eye.

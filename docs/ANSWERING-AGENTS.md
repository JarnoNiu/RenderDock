# Answering agents from RenderDock

> New in 0.3, and **not yet run against a live agent** (see the end of this page). Off by default, and it stays off until you do two things yourself.

When a coding agent wants to do something it needs your permission for, it stops and asks in its own window. With this switched on, the request also appears at the top of RenderDock's panel, with two buttons: **Allow once** and **Deny**. Your click goes back to the agent, and it carries on or stops.

An answer comes from the panel. It can also come from a [device on your desk](DEVICES.md), but only after two more switches of your own: the link to the device, and "Agents' Requests May Be Answered on the Device". With that last one off, which is how it starts, a device is told that something waits on the Mac and nothing more.

Only Claude Code is supported so far.

## What it will and will not do

- **One request, one answer.** An answer is for exactly the request shown, once. There is no "always allow" here.
- **Only what you can see whole.** A request is shown with everything in it: the command or the path first, then every other field by name (`-i: true`, `glob: *.ts`, an edit's old and new text). Nothing rides along unseen. One that is too long to show whole, runs over several lines, or contains characters with no shape on the screen (ones that reverse the reading order, ones with no width, control codes) cannot be allowed here. In the panel a request that may be allowed is never shortened, however many lines it takes.
- **A click just after the cards moved is not taken.** When a request ends and the next one slides into its place, a click in the next half second answers nothing: the card under the pointer may not be the one you read.
- **Only what you said may be allowed here.** By default that is reading and searching: `Read`, `Glob`, `Grep`, `LS`. Everything else, running a command or changing a file, shows up with a **Deny** button only, and a note that it has to be handled on the computer.
- **Silence is not consent.** If nobody answers in 100 seconds, if RenderDock is not running, if this is switched off, or if RenderDock quits while a request is waiting, the agent asks in its own window exactly as it would have. Nothing is ever allowed by default.
- **The agent's own prompt is not replaced, but it may have to wait.** Claude Code's documentation says that in hosts built on its SDK, which includes the Claude desktop app, the hook runs alongside the host's own prompt and whichever decides first applies; the request then disappears from the panel. For a session in a terminal it says only that the hook runs when Claude Code is about to ask. Whether the terminal's prompt is on screen while the hook waits has not been seen by this project. If it is not, it appears when the hook hands the question back: after your answer here, or after the wait runs out. If you would rather answer at the terminal most of the time, shorten `timeoutSec` (below).
- **Everything is on record.** Each answer, and each request that ran out of time, is written to a file on this Mac.

## Turning it on

Two steps, and both are yours. RenderDock never does either on its own.

**1. Switch it on in RenderDock.** Menu-bar icon → **Answer Agents' Requests Here**.

**2. Put the hook into the agent's settings**, for one project:

```bash
/Applications/RenderDock.app/Contents/Helpers/renderdock hooks install --project ~/path/to/project
```

That only prints what it would write. Add `--yes` to write it:

```bash
/Applications/RenderDock.app/Contents/Helpers/renderdock hooks install --project ~/path/to/project --yes
```

It adds one entry, `hooks.PermissionRequest`, to that project's `.claude/settings.local.json`, which is the file for settings that are yours alone and not shared with the project. If the file existed, a copy of it as it was is kept in RenderDock's own directory (`~/Library/Application Support/RenderDock/control/hook-backups/`, readable by you alone), so nothing extra appears inside the project. A permission hook of your own, even one in the same group, is left where it is, on installing and on uninstalling.

Start with one project. `--global` instead of `--project` writes to `~/.claude/settings.json`, which every Claude Code session on the Mac reads, including the ones already open. Do that only once you have seen it work.

To see whether it is there, and to take it out:

```bash
renderdock hooks status --project ~/path/to/project
renderdock hooks uninstall --project ~/path/to/project --yes
```

If the file has not been edited since, uninstalling puts back exactly what was there before, byte for byte. If RenderDock created the file and it holds nothing else, the file is removed.

Either step alone does nothing. With the hook in place and the switch off, the hook prints nothing and the agent behaves as before.

## What may be allowed here

`~/Library/Application Support/RenderDock/control/control.json`, if you create it:

```json
{
  "approvable": ["Read", "Glob", "Grep", "LS"],
  "timeoutSec": 100,
  "maxDetail": 160
}
```

- `approvable` — the agent's own names for what may be allowed from RenderDock. Add `Bash` here and any single-line command that fits in `maxDetail` characters, together with its other fields, can be allowed with one click. Add `Edit` and the same holds for an edit whose old and new text are short enough to be shown on one line. Think before you do.
- `timeoutSec` — how long a request waits here, between 5 and 110 seconds. It is kept inside the hook's own limit of 120 seconds, so the hook always ends by handing the question back rather than being cut off.
- `maxDetail` — the longest text that can still be allowed here.

The file is read for every request, so a change takes effect at once.

## How it works

```
agent  →  its PermissionRequest hook runs `renderdock hook`
       →  that asks the app over a Unix socket, and waits
       →  the app shows the request; you allow it once or deny it
       →  the answer goes back the same way, and the hook prints it for the agent
```

- The socket is in `~/Library/Application Support/RenderDock/control/`, a directory only your user can enter. Nothing listens on the network.
- Each time the app starts listening it writes a fresh token there, and a caller must present it.
- An answer names the request by its id and carries the request's fingerprint, made from the action and its whole input. The hook checks that the answer is for what it asked.
- If the app is not listening, `renderdock hook` returns in about a hundredth of a second and prints nothing. The hook always exits with status 0: it never gets in the agent's way.
- A request whose input is larger than 256 KB is not taken at all, not even to be denied: the agent asks in its own window.
- Any program running as you can reach the socket. It cannot allow anything (an answer comes only from your click, or your hold on a device), but it can ask, and a program that connects and says nothing holds the others up for a second at a time.

## The record

`~/Library/Application Support/RenderDock/control/audit.jsonl`, readable by you alone. One line per outcome:

```json
{"action":"Read","at":"2027-01-15T08:00:02Z","decision":"allow","detail":"src/login.ts","fingerprint":"5d0c…","id":"kqmtv","project":"demo-site","source":"panel","tool":"claude-code","waitedSec":2}
```

`decision` is `allow`, `deny` or `none`. `source` says where it came from: `panel` for your click, `device` for an answer given on a desk device, `timeout`, `gone` when the question was answered or dropped on the agent's side, `stopped` when RenderDock quit.

Unlike the API and the notifications, this file does hold the text of each request, up to 200 characters, because a record of what was allowed is worth nothing without it. It stays on this Mac.

## What has and has not been checked

Checked, on macOS 26:

- The whole path with stand-in requests: the real `renderdock hook` command, fed the input the Claude Code hooks documentation describes, against the real app. Allowing a read printed the allow answer; trying to allow a command was refused and the request stayed; denying printed the deny answer; quitting the app released the waiting hook with no output; with the app not running the hook returned in 0.013 seconds.
- Installing and uninstalling the hook in throwaway project folders, including the byte-for-byte restore.

**Not checked: a real agent.** This has not been run against a live Claude Code session. The hook's input and output follow Claude Code's published hooks reference, but until someone installs it and clicks a button in a real session, that last link is unproven. If you try it, a report either way is welcome.

## For testing

`RENDERDOCK_CONTROL` replaces the control directory. Keep the path short: a Unix socket path cannot be much longer than a hundred bytes.

`RenderDock --snapshot <dir> --demo --control --at 15` draws the panel with two made-up requests, one that may be allowed here and one that may not.

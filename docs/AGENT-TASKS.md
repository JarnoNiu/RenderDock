# Coding agents' sessions

> New in 0.3.

A render is not the only long job on a Mac. From 0.3 on, RenderDock also shows what the coding agents on this Mac are doing: which sessions are working, which have just finished, and which are waiting for you.

It only reads. It installs no hooks, changes no agent's configuration, and sends nothing to a session.

## What you see

- **On the capsule**: a small badge with a count while a session is waiting for you, or has failed. Nothing otherwise. When nothing is rendering, the capsule's text speaks for the agents instead.
- **At the top of the panel**: one line naming the session that needs you.
- **In the panel**: an **Agents** block. Sessions that are doing something get a row each, with the tool, the project, the state and how long it has been in it. Idle sessions are folded into one line.
- **In the menu**: the same lines, and two switches: **Show Agents' Sessions (read-only)** and **Show Session Titles**.
- **On the command line**: `renderdock agents`, or `renderdock agents --json`.
- **In the API**: the `agents` block of `GET /v1/state`, and agent events on `GET /v1/events` (see [API.md](API.md)).
- **As notifications**, if you have turned notifications on: when a session starts to need you, fails, or finishes a long turn (see [NOTIFICATIONS.md](NOTIFICATIONS.md)).
- **For a light or a small screen**: the summary in the state document counts agents and renders together (see [SMALL-DISPLAYS.md](SMALL-DISPLAYS.md)).

Clicking a row does nothing yet.

## States

One vocabulary for every agent, in the order a single light should prefer:

| State | Meaning |
|---|---|
| `error` | It failed |
| `waiting` | It is waiting for you: a permission, an answer, a choice |
| `working` | It is working |
| `done` | It has just finished and is waiting for you to look. After a few minutes this becomes `idle` |
| `idle` | Nothing to do |
| `stale` | It should be working, but nothing has been heard from it for a long while |

## Where it comes from

| Agent | Read from | Can show | Cannot show |
|---|---|---|---|
| **Claude Code** | Its own command, `claude agents --json`, which its documentation names as the way to read session state from another program | `working`, `waiting` (with what it waits for), `idle`, `done`; `error` for background sessions | Which tool it is using; whether a finished turn went well |
| **Codex** | The session records under `~/.codex/sessions` | `working`, `done`, `stale` | **A pending approval**: from the records, a session waiting for you looks the same as one that is working. Failed turns |
| **Gemini** (the Gemini desktop app, its `agy` command line, Antigravity; from 0.4) | The list of conversations they share, `~/.gemini/antigravity/conversation_summaries.db` | `working`, `waiting`, `done`, `stale` | What a session waits for. Failed turns. Conversations inside other conversations (an agent's own helpers) are left out |
| **Hermes** | `~/.hermes/gateway_state.json` and its kanban database | The gateway idle or working; kanban tasks with a live worker | Anything outside the gateway and the kanban |

Each row carries where it came from: `official` when the tool's own command reported it, `files` when it was read from the tool's local files. Hover over a row to see which.

An agent that is not installed costs one directory check per scan.

### Claude Code

- The command is run inside a sandbox that denies network access. Run plainly, it opens an outbound connection each time; inside the sandbox it opens none and returns the same list. RenderDock asking never makes a connection.
- It is not run on every scan. RenderDock watches Claude Code's session registry (`~/.claude/sessions`) for *change* — file names and modification times only — and runs the command when something changed, or after 20 to 60 seconds without news. One run takes about 0.2 seconds.
- If the command cannot be found or fails, the registry files themselves are read, sessions whose process is gone are dropped, and the rows are marked `files`.
- `done` is RenderDock's own reading: a session that went idle less than five minutes ago, and not straight after starting.
- `claude` is looked for in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local` and `~/.npm-global/bin`.

### Codex

- Two things are taken from a record: its first line (the thread, its working directory, whether it is a subagent's thread) and the type and time of its last task event. Thread names come from `~/.codex/session_index.jsonl`.
- A chat started in Codex's own app without a project works in a folder Codex makes up for it (`~/Documents/Codex/<date>/<a few letters>`). Those letters are cut from the chat's title: they are not a project, and a piece of a title is not shown off this Mac. Such a session's project reads **chat** (对话 in Chinese), everywhere: the dock, the menu, the API, a desk display. If you make that folder a repository, it is a project like any other, by its own name. (Up to 0.4's first builds the letters were shown as the project: a chat with a Chinese title came out as three letters.)
- A turn that started and has not ended is `working`, as long as a Codex process is running. With nothing written for 15 minutes it becomes `stale`.
- A turn that ended less than 10 minutes ago is `done`. Older ones, interrupted ones and subagents' threads are not listed.
- Only records touched in the last 24 hours are looked at. Of each, its first lines, and then whatever has been written since the last look, however much that is. On a first look the record is read backwards from its end until a turn's start or end turns up (64 MB back at most). A turn's start can be megabytes from the end: one command's output is enough. (Up to 0.4's first builds only the last 512 KB were read, and a turn that had written more than that since it started was shown nowhere while it was at work.)
- A record's size and date are read afresh at every look. (They used to be taken from the listing of the folder, which is made every 20 seconds: a turn's start or end was noticed up to that much later.)

### Gemini and Antigravity (0.4)

Google's agent runs under several names (the Gemini desktop app, its `agy` command line, Antigravity) and keeps one folder for all of them, with a small database that lists the conversations. RenderDock shows them as **Gemini**.

- From the list, for each conversation: whether the program says it is running, when it last changed, when you last spoke in it, and the folders it works in. `CASCADE_RUN_STATUS_RUNNING` (or `_BUSY`) is `working`; `_IDLE` within ten minutes of its last change is `done`; one being cancelled, one that was killed, one that was opened and never spoken in, and one that belongs to another conversation are not listed.
- A running conversation has a database of its own with its steps. One question is asked of it: is a step marked as waiting (status 9, `WAITING` in the program's own list of names)? Then the session is `waiting`. **This has not been seen live yet**: the number comes from the program's descriptors, not from watching a conversation wait.
- "Running" in the list only counts while one of the agent's programs is running (the one its own note under `daemon` names, or a process called `agy`, `Gemini` or `Antigravity…`). Left over from a crash, it is not shown. With nothing changed for 15 minutes it is `stale`.
- The project is the name of the folder the conversation works in. One that works in no folder reads **chat**, as with Codex.
- Both databases are opened read-only, and nothing is created beside them: while their owner has them open they are read the ordinary way, and once it has closed them the main file is read as it is. (Opening a closed one the ordinary way would make SQLite put two files of its own in that folder.) Nothing that was said is read: not the preview, not a step's content.
- Checked against Gemini 1.147 on macOS 26, with one live conversation: at work, then done, matching the app. The words and numbers for the states were read out of the program itself.

### Hermes

- The gateway is listed while its state file says it is running and its process is alive: `working` when it reports active agents, `idle` otherwise.
- A kanban task is listed while it has a worker process that is alive and no completion time.
- The database is opened read-only.

## What is not read, and what stays on the Mac

- **Nothing that was said in a session is kept or shown.** Claude Code's command does not carry it. Codex's records do contain it; RenderDock looks only for task events in them and keeps a type and a time.
- **Session titles stay on this Mac**, with one exception that is yours to make. They appear in the panel, where you can switch them off. They are never in the API, in an event, in `renderdock agents --json`, or in a notification. The exception: a desk display may show them in place of projects if you switch that on ([DEVICES.md](DEVICES.md#sessions-titles-on-the-device-04-off-by-default)), and then only over the encrypted Bluetooth link.
- **No paths.** A session's project is the repository's directory name.
- **Nothing is recorded.** Agent sessions are not written to the history database.

## Limits

- The formats belong to the tools. Claude Code's command is in research preview, and the Codex and Hermes files are internal: an update to any of them can break the reading. When RenderDock cannot read something it shows nothing, rather than guess.
- Only Claude Code can be seen waiting for you.
- Checked on macOS 26 against Claude Code 2.1.282 (the live sessions matched the command's own list one for one), the Codex desktop app 26.1117 and Hermes. A Codex turn in progress was first watched live on 2026-11-26, and that is how the two faults above were found (a turn that wrote a lot vanished; a chat without a project was named by a folder). **Not yet seen live:** a session actually waiting, a Hermes task in progress. Those paths are covered by checks with made-up records only.

## For testing

| Variable | Replaces |
|---|---|
| `RENDERDOCK_CLAUDE` | The path to `claude` |
| `RENDERDOCK_CLAUDE_HOME` | `~/.claude` |
| `RENDERDOCK_CODEX_HOME` | `~/.codex` |
| `RENDERDOCK_HERMES_HOME` | `~/.hermes` |

`RenderDock --snapshot <dir> --demo --at 15` draws the demo at the moment one of its made-up sessions asks for permission.

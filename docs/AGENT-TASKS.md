# Coding agents' sessions

> Part of 0.3, which is still in development.

A render is not the only long job on a Mac. From 0.3 on, RenderDock also shows what the coding agents on this Mac are doing: which sessions are working, which have just finished, and which are waiting for you.

It only reads. It installs no hooks, changes no agent's configuration, and sends nothing to a session.

## What you see

- **On the capsule**: a small badge with a count while a session is waiting for you, or has failed. Nothing otherwise. When nothing is rendering, the capsule's text speaks for the agents instead.
- **At the top of the panel**: one line naming the session that needs you.
- **In the panel**: an **Agents** block. Sessions that are doing something get a row each, with the tool, the project, the state and how long it has been in it. Idle sessions are folded into one line.
- **In the menu**: the same lines, and two switches: **Show Agents' Sessions (read-only)** and **Show Session Titles**.
- **On the command line**: `renderdock agents`, or `renderdock agents --json`.
- **In the API**: the `agents` block of `GET /v1/state` (see [API.md](API.md)).

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
- A turn that started and has not ended is `working`, as long as a Codex process is running. With nothing written for 15 minutes it becomes `stale`.
- A turn that ended less than 10 minutes ago is `done`. Older ones, interrupted ones and subagents' threads are not listed.
- Only records touched in the last 24 hours are looked at, and only their first and last few hundred kilobytes.

### Hermes

- The gateway is listed while its state file says it is running and its process is alive: `working` when it reports active agents, `idle` otherwise.
- A kanban task is listed while it has a worker process that is alive and no completion time.
- The database is opened read-only.

## What is not read, and what stays on the Mac

- **Nothing that was said in a session is kept or shown.** Claude Code's command does not carry it. Codex's records do contain it; RenderDock looks only for task events in them and keeps a type and a time.
- **Session titles stay on this Mac.** They appear in the panel, where you can switch them off. They are never in the API, in `renderdock agents --json`, or in a notification.
- **No paths.** A session's project is the repository's directory name.
- **Nothing is recorded.** Agent sessions are not written to the history database.

## Limits

- The formats belong to the tools. Claude Code's command is in research preview, and the Codex and Hermes files are internal: an update to any of them can break the reading. When RenderDock cannot read something it shows nothing, rather than guess.
- Only Claude Code can be seen waiting for you.
- Checked on macOS 26 against Claude Code 2.1.282 (the live sessions matched the command's own list one for one), the Codex desktop app 26.1117 and Hermes. **Not yet seen live:** a session actually waiting, a Codex turn in progress, a Hermes task in progress. Those paths are covered by checks with made-up records only.

## For testing

| Variable | Replaces |
|---|---|
| `RENDERDOCK_CLAUDE` | The path to `claude` |
| `RENDERDOCK_CLAUDE_HOME` | `~/.claude` |
| `RENDERDOCK_CODEX_HOME` | `~/.codex` |
| `RENDERDOCK_HERMES_HOME` | `~/.hermes` |

`RenderDock --snapshot <dir> --demo --at 15` draws the demo at the moment one of its made-up sessions asks for permission.

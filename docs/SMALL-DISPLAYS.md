# For small displays

> New in 0.3.

A light, a strip of LEDs, a two-line screen: none of them can show a list of jobs and sessions. So the state document carries a summary made for them. Whatever the display, it reads the same few fields from `summary` in `GET /v1/state` (see [API.md](API.md)).

```json
"summary": {
  "state": "waiting",
  "top":   { "kind": "agent", "name": "demo-site", "state": "waiting",
             "tool": "claude-code", "waitingFor": "permission prompt" },
  "line":  "1 waiting | render 62%",
  "agents": { "error": 0, "waiting": 1, "working": 2, "done": 1, "idle": 3, "stale": 0 },
  "rendering": 1, "paused": 0, "stalled": 0, "queued": 0,
  "focus": { "name": "s040_explode", "state": "rendering", "fraction": 0.62, "exact": true, "etaSec": 1662 }
}
```

## One word: `summary.state`

Renders and agents' sessions together, as one word. It is the most urgent of these that applies:

| State | When | A light might |
|---|---|---|
| `error` | A session failed, or a render that was started with `renderdock run` failed in the last five minutes | Blink red, fast |
| `waiting` | A session is waiting for you, or a render looks stalled | Blink amber |
| `working` | Something is rendering, or a session is working | Breathe blue, slowly |
| `done` | A session has just finished, or a render finished in the last five minutes, and nothing else is going on | Stay green |
| `idle` | None of the above | Go dim or dark |

The colours are a suggestion. Projects that drive a light from a coding agent agree on amber for waiting, green for done and red for an error; they do not agree on a colour for working, and red is better kept for errors.

Three things are deliberate:

- **A paused render is not `waiting`.** Queues pause shots on purpose; a light that blinked for that would blink for hours.
- **A render that merely disappeared is not `done`.** Only an exit status of 0, recorded by `renderdock run`, counts as a finish. Without it RenderDock cannot tell a finished render from a crashed one.
- **`done` and `error` fade.** After five minutes a finished or failed render no longer counts, and a session that has just finished becomes idle.

## One thing: `summary.top`

What the word is about. Absent when the state is `idle`.

| Field | Meaning |
|---|---|
| `kind` | `agent` or `render` |
| `name` | For an agent, the project it works in. For a render, the shot's name |
| `state` | The same vocabulary as `summary.state` |
| `tool`, `waitingFor` | For an agent: which one, and what it waits for |
| `fraction`, `exact`, `etaSec` | For a render in progress. Show `~` or no percentage when `exact` is false |

While a render and a session are both working, the render is the top item: it has a percentage to show.

## One line: `summary.line`

Plain ASCII, at most 23 characters, for displays with no room and no fonts: `1 waiting | render 62%`.

It lists, most urgent first and as many as fit: sessions and renders that failed, those waiting, the render's percentage (`~62%` when the total is an estimate, or a count when there is no percentage), sessions working, and what has just finished. When nothing applies it is `idle`.

It never contains a project name or a title, so it is safe on any display.

## Each side by itself: `summary.renderSide`, `summary.agentSide` (from 0.4)

`summary.state` and `summary.top` are the more urgent of the two sides, which is right for one light or one line. A display with room for a page each wants both: while a session waits for you, the render behind it is still at 62%. `renderSide` and `agentSide` each have a `state` and a `top` of their own, in the same vocabulary. A render that failed in the last five minutes is `error`, one that stopped moving is `waiting`; `top` is absent when that side is idle.

## Counts

`summary.agents` has the number of sessions in each state. `summary.rendering`, `paused`, `stalled` and `queued` count render shots and jobs, as before.

## Polling or listening

- **Polling** `GET /v1/state` every few seconds is enough for a light.
- **Listening** to `GET /v1/events` gets a `state` event after each scan, and the moments themselves as they happen: `agent.waiting`, `agent.done`, `agent.error`, `agents.idle`, `job.ended` and the rest. A display that wants to flash once, or make a sound, should use those.

The API listens on this Mac only. A device elsewhere on the network cannot reach it yet.

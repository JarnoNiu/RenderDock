# History, queue estimates and odd frames

> Part of 0.3, which is still in development.

From 0.3 on, RenderDock remembers the shots it watched. That is what makes two other things possible: an estimate for a whole queue, and a short list of what ended recently.

## What is remembered

For every shot it sees: the job's title, the project name, the script's name, the shot's name, when it started and ended, how many frames it rendered, whether the total was exact, the seconds per frame, and how it ended. It also keeps how the frame count grew over time.

It lives in one SQLite file:

```
~/Library/Application Support/RenderDock/history.sqlite
```

- **No file-system paths are stored.** Titles and names only.
- Nothing leaves the Mac. The file is yours; delete it and RenderDock starts again from nothing.
- Shots that ended more than 90 days ago are dropped.
- Only the app records. The command line only reads, and never creates the file.

How a shot ended is one of:

| Outcome | Meaning |
|---|---|
| `done` | The queue moved on past it |
| `finished` | It was started with `renderdock run` and exited with status 0 |
| `failed` | It was started with `renderdock run` and exited with another status |
| `ended` | Its processes are gone and nothing says why |

## When will the whole queue be done

A queue's card shows, while the queue is running:

> Queue done in ~2h 10m, ≈ 03:40

It is always an estimate, and it is put together like this:

- **The shot in progress**: its own time left, or what is left of its previous duration, whichever is longer. A shot is more than its render — compositing and checks follow — and the previous duration knows about those.
- **A shot still to come**: how long it took the last time it ran to the end.
- **A shot that never ran before**: the average of this queue's shots that have finished so far. When any shot is estimated this way, the line says **(rough)**.
- **Parallel streams** of one queue are added up separately; the longest one counts.

There is no estimate when the queue is paused or waiting, for a single job (its own time left is already shown), or when there is nothing yet to base one on: the first shot of a queue that has never run, before its first frame.

The first time a queue runs, the estimate is rough. The second time, it is based on what each shot really took.

## Odd frames

Under a shot, RenderDock may show a hint:

> ⚠ 2 frames with an unusually small file: #412 #413

- **Unusually small file**: under a quarter of the usual size among the most recent frames, where the usual size is at least 20 KB. Such a frame may be empty or black.
- **Took unusually long**: the gap before the frame was more than five times the usual one, and more than 20 seconds. A hard frame — or the job was paused.

These are hints, not verdicts. A shot that fades to black has small frames for good reason. At least a dozen frames are needed before anything is flagged, the newest frame is left out while it may still be being written, and at most the five latest are listed.

## Looking at it

In the panel: **Recently ended**, the last four shots, with duration, frames and the time they ended.

On the command line:

```bash
renderdock history
renderdock history --limit 50 --json
```

Through the API: `GET /v1/history` (see [API.md](API.md)).

# History, queue estimates and odd frames

> New in 0.3.

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
- From 0.3.1: the time-left estimates it showed, once a minute, as seconds. See "How close the estimates were" below.

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

## How close the estimates were (from 0.3.1)

An estimate is only worth showing if it turns out roughly right, so RenderDock writes down what it said and holds it against what happened.

While something renders, once a minute, it notes the time left it is showing: for the shot in progress, and for the whole queue. Only the number of seconds, when, and which shot or queue (by its row, not by its name). Later:

```bash
renderdock estimates
renderdock estimates --days 7 --json
```

```
time-left estimates held against what happened, 12-01 21:04 to 12-02 06:40

shots                 412 estimates, 9 shots      off by 2m 10s (6%)        said 1m 5s too long       88% within a fifth
  under 10 min left   61 estimates, 9 shots       off by 20s (9%)           said 12s too short        77% within a fifth
  10 to 60 min left   351 estimates, 9 shots      off by 2m 40s (6%)        said 1m 30s too long      90% within a fifth

queues                530 estimates, 1 queue      off by 14m 0s (9%)        said 14m 0s too short     81% within a fifth
  ...
```

(The numbers above are made up, to show the shape.)

- **Off by**: how far the estimates were from the time that really was left, the middle value of all of them, and the same as a percentage.
- **The lean**: whether they tended to say too long or too short.
- **Within a fifth**: the share of estimates that came within 20% of the time that really was left.
- The lines are split by how much time really was left, because an estimate ten minutes from the end is a different thing from one five hours out.

What an estimate is held against:

- A shot's estimate is of its frames, so it is held against the next moment the frame count was full. A shot that counts its frames twice (rendering, then compositing) has two such moments. When the last frames were written between two looks, the moment the shot was no longer in progress is used.
- A queue's estimate is held against the end of its last shot.

What is left out, and said so at the end of the report:

- **still running**: the shot or queue has not come to its end.
- **did not finish**: the shot failed or was stopped, or the queue ended with fewer shots than the estimate was counting on. A queue stopped half-way says nothing about how good the estimate was. A shot that is simply gone (`ended`, above) counts as finished if at least 98 in 100 of an exact number of frames had been counted.
- **queue changed**: more shots ended than the estimate was counting on.

Estimates are written down from 0.3.1 on; there is nothing to hold against what happened before that. They are dropped after 90 days with the rest.

## What a shot drew (from 0.4)

On a Mac whose controller reports what the machine is drawing, RenderDock adds that up for every shot while it renders, and keeps the sum with the shot: `renderdock history` shows it after the frame count (`480 frames · 118 Wh`), the dock's list of recently ended shots has it, and `/v1/history` carries it as `energyWh`.

What that number is, so that it is not taken for more:

- **The whole Mac's draw, not the render's.** The screen, the disks and everything else running are in it. A shot rendered while you also edit video looks more expensive than the same shot rendered overnight.
- **Shared equally among the shots rendering at the same moment.** Nothing says which of two renders the machine was working for, so each gets half. The shares of all the shots add up to what the Mac drew while anything was rendering.
- **As the Mac's own controller reports it**, read every two seconds; not measured at the wall, and the power adapter's own losses are not in it.
- **Only while RenderDock was running and looking.** A stretch longer than a quarter of a minute without a look (the Mac slept, RenderDock was quit) is left out rather than guessed at. A shot that began before 0.4 was installed has only what was drawn since.

It is good for comparing like with like (this week's render of a shot against last week's, one render setting against another) and for a rough idea of what a night's queue costs. It is not a bill.

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

`renderdock estimates` is described above, under "How close the estimates were".

Through the API: `GET /v1/history` (see [API.md](API.md)).

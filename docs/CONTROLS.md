# Hands on: pausing, letting go, moving out of the way

> New in 0.4. Every switch here is off unless you turn it on.

Everything else in RenderDock only looks. This is the part that can stop a render and let it go on again, and move it out of the way of whatever else you are doing on the Mac.

## The switches

Menu-bar icon → **Hands On the Renders**. Five switches, each its own. Turning one on is asked about first, in a sentence that says what it will do; turning it off needs no asking, and at once undoes what was done under it.

| Switch | What it does |
|---|---|
| **Pause and Resume from the Dock** | Each job in the dock gets a pause button, or a resume button once it is stopped. Pausing stops the render process where it is; resumed, it goes on from there and loses nothing |
| **Move a Render Out of the Way from the Dock** | Each job gets a button that puts it in the system's background band: it renders on what the Mac has to spare, slower, while you use the Mac. The same button puts it back. It is said of the job: when a queue goes on to its next shot, that process is moved too |
| **One Job at a Time** | Of the jobs running at once, only the one that began first goes on; the others are paused, and each goes on when the one before it has ended. A queue that is between two shots (one written, the next not started) has not ended: it keeps its turn through the gap |
| **Pause Renders While on Battery** | When the power adapter is unplugged, every job that is rendering is paused; plugged in again, they go on |
| **Pause Renders While Slowed Down for Heat** | When the system starts slowing the Mac down for heat (its own "serious" or "critical"), every job that is rendering is paused; they go on once it has been cool for a full minute |

A job that RenderDock is holding says why on its card: *Paused by RenderDock: the Mac is on its battery*, *…waiting for the job before it*, *Paused here by you*.

## What it will and will not touch

- **Nothing happens unless a switch for it is on.** With all five off, RenderDock does not so much as look at whether there would be anything to do.
- **Only processes it shows as renders, and only yours.** Before every single action it checks that the process is still there, is still the same process (the same number and the same start: a number is handed to another process once its owner is gone) and belongs to you. Anything else is refused and nothing is sent.
- **It lets go only of what it stopped itself.** A render you stopped in a terminal (`kill -STOP`) is left alone by the rules: they neither count it as running nor wake it up. The resume button in the dock does wake it, because that is you asking.
- **What you decide by hand wins.** A job you paused in the dock stays paused whatever the rules say, and is not waited for by "one at a time". A job you let go on by hand is not stopped again by any rule for as long as it lasts.
- **Whatever it stopped goes on again when RenderDock quits**, and whatever it moved is moved back. If RenderDock is killed instead, it remembers what it was holding (`controls.json`, beside the log) and sorts it out when it starts again: held if a rule still asks for it, let go if not.
- **Everything it does is written down**: `~/Library/Application Support/RenderDock/controls.log`, one line each with the time, the job and the reason; **Open the Log of What Was Done** in the same menu shows it. The last four hundred lines are kept.
- **The API is still read-only.** Nothing here can be asked for over the local API, from the network, by an agent through MCP, or from the desk display.

## What "paused" and "out of the way" are

Pausing is the system's own `SIGSTOP`, and resuming its `SIGCONT`: the process is frozen where it stands, keeps its memory (and its hold on the graphics chip's memory), and writes nothing while it waits. It is what `kill -STOP` does, and what the dock already showed as *Paused* when you did that yourself.

What is stopped is the process RenderDock shows as doing the work: the Blender or ffmpeg process of the shot being rendered, not the script that started it. The script waits for it, so a queue stands still and goes on from the same shot. **For a ComfyUI server that process is the server itself**: paused, its page stops answering until it is let go.

"Out of the way" is the system's background band (`setpriority` with `PRIO_DARWIN_BG`): on Apple silicon that is the efficiency cores and the back of the queue for the disk. A render that works mostly on the graphics chip is slowed less than one that works on the processor. It is not `nice`: it can be undone without admin rights, which `nice` cannot.

## What has and has not been checked

- **Checked on a real process**, a stand-in started by the checks themselves and never anybody's render: stopping it and letting it go, moving it into the background band and back (read from the scheduler's own priority for it), and every refusal: a process that has ended, the same number with another start, a process of another user's, process 1.
- **Checked without stopping anything**, against a made-up set of jobs: every rule and how they sit with one another and with what is done by hand, a switch going off, quitting, a restart, a process that will not be stopped, a waiting job that starts another process. And with every switch off, that nothing at all is done.
- **Seen in the dock** in a demo instance, where the jobs are made up and "stopping" one changes only what is shown: the buttons, the line that says why, the menu, the log.
- **Not checked: the whole way round on a real render.** No switch has been on in an installed copy with a real Blender or ffmpeg job under it. Nor: how a render on the graphics chip takes being stopped for hours, or what "out of the way" does to its speed. Start with **Pause and Resume from the Dock** on a job you can afford to lose.

## Not there

- Stopping a job for good, or starting one. RenderDock starts nothing and ends nothing.
- A command to run when a job ends. "One at a time" lets waiting jobs go on; it does not launch anything.
- Rules of your own. There are the three above.
- Any of this from the command line, the API or the desk display.

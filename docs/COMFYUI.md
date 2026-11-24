# ComfyUI

> New in 0.3.

When a ComfyUI server is running on this Mac and has something in its queue, it appears in RenderDock as a job called **ComfyUI**. Each prompt in the queue is one segment of its bar: done, running, up next.

There is nothing to set up. To leave ComfyUI alone, put `"comfyui": false` in [`adapters.json`](ADAPTERS.md).

## How it is read

- A ComfyUI server is recognised among the running processes: a Python whose script is `main.py`, in a folder (or with a path) that says ComfyUI. Its port is `--port` from its command line, or 8188.
- While such a process exists, RenderDock asks it for its queue: `GET http://127.0.0.1:<port>/queue`, at most once every couple of seconds. That is a request from this Mac to this Mac, and the only one. Nothing is ever sent to ComfyUI, and nothing is read of the workflows themselves: only each prompt's number and id.
- A prompt that was in the queue and no longer is counts as done. The queue does not say whether it finished or was cancelled, so neither does RenderDock. When the queue empties, the job goes.

## What it does not show: a percentage

The running prompt has no percentage, and this is not an oversight. ComfyUI sends its step-by-step progress only to the browser tab that queued the prompt (its source says so: "to ensure message is only sent to the initiating client"). A second listener gets none of it, and joining under the tab's own name would take the tab's connection away from it, which RenderDock will not do.

So: how many prompts are done, which one is running and for how long, how many are waiting. Not how many steps the sampler has left.

## What has and has not been checked

- **Checked** against a stand-in server started the way ComfyUI is started (`python3 main.py --port …` in a folder named for ComfyUI) and answering `/queue` in ComfyUI's shape: it was found, its three prompts moved through the bar one after another, and the job went when the queue emptied.
- **Not checked: a real ComfyUI.** The author does not have one installed. The shape of `/queue` and the default port were taken from ComfyUI's source. If your ComfyUI is started in a way RenderDock does not recognise, the process's command line (`ps -o command= -p <pid>`) is what is needed to fix that.

# Adapter rules

> New in 0.2.

Out of the box RenderDock recognises headless Blender renders, bare `ffmpeg` processes, and anything started with `renderdock run`. If your pipeline has other long steps — compositing frames in a script, a custom encoder — you can describe them in a small file instead of asking for a code change.

The file is optional:

```
~/Library/Application Support/RenderDock/adapters.json
```

It is read again whenever it changes; there is nothing to restart. A file that does not parse is ignored, and the built-in detection keeps working.

## A step with its own frames

Say a pipeline renders with Blender and then composites the frames with a Node script, `node render.mjs --scene s040 --shot explode`, writing them to `out/frames/s040-explode/` and knowing the frame count from a JSON file the render left behind:

```json
{
  "adapters": [
    {
      "name": "composite",
      "process": "node",
      "args": ["render.mjs", "--scene"],
      "notAbove": "blender",
      "state": "compositing",
      "frames": "{cwd}/out/frames/{--scene}-{--shot}",
      "total": { "jsonFile": "{cwd}/out/blender/{--scene}-{--shot}/meta.json", "countOf": "frames" },
      "freshDir": true
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | For your own reference |
| `process` | The executable's name. Case-insensitive |
| `args` | Arguments that must all be present. A file name also matches a path ending in it |
| `notAbove` | Ignore a matching process that has a descendant with this name. Here: while `node` is still running Blender underneath, the Blender process is the shot, not `node` |
| `state` | What the card says: `rendering` (default), `compositing`, `encoding`, `finishing` |
| `title` | What to call it. A template. Without it, the usual naming applies (`--scene` / `--shot` arguments, then the process name) |
| `frames` | The folder where finished frames appear. A template |
| `total` | Where the frame count comes from: `{"jsonFile": …, "countOf": "key"}` counts the entries of an array or object in a JSON file; `{"arg": "--frames"}` reads a number from the command line |
| `freshDir` | The step empties `frames` when it starts: until the folder is newer than the process, what is in it is not counted |

Templates may use `{cwd}` (the process's working directory) and `{--flag}` (the value of that command-line argument, written `--flag value` or `--flag=value`). If a placeholder has no value, the path is not used at all.

## Queues that leave a file per finished shot

RenderDock reads `scene:shot` arguments on a queue script's command line as the queue. While a shot is rendering, everything before it counts as done. Between two shots, or while the whole queue is paused, it cannot tell — unless you say which file marks a finished shot:

```json
{
  "queueDoneFile": "{cwd}/out/{scene}-{shot}.mp4"
}
```

A shot counts as done when that file exists and is newer than the queue script's start.

## Checking a rule

```bash
renderdock status
```

prints what the scanner sees, with your rules applied. Set `RENDERDOCK_ADAPTERS=/path/to/file.json` to try a rules file without installing it.

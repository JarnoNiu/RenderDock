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

## Queues written another way

`scene:shot` is one way of listing what a queue script will render. It used to be the only way RenderDock could read; it is now a rule like the ones above, and you can add your own next to it:

```json
{
  "queues": [
    {
      "name": "episodes",
      "script": "render_all.sh",
      "item": "{seq}/{shot}",
      "flags": { "--seq": "{seq}", "--shot": "{shot}" },
      "contains": "{seq}_{shot}",
      "title": "{seq} / {shot}",
      "doneFile": "{cwd}/out/{seq}_{shot}.mov"
    }
  ]
}
```

With that, `render_all.sh ep04/intro ep04/table ep05/open` is a queue of three.

| Field | Meaning |
|---|---|
| `item` | How one item is written among the script's arguments. The names in braces are yours; they can be used in the other fields. Required |
| `script` | Only for a script with this file name. Leave it out and the rule is tried on every script, so give it when the pattern is a loose one |
| `flags` | A process is rendering an item when it carries these arguments with these values |
| `contains` | When a process does not carry all of those flags: it belongs to an item if one of its arguments contains this text. This is also how a step that follows the render (a check, a re-encode) is recognised as part of the item |
| `title` | What to call an item. Without it: the parts joined by ` · `, leaving out a part that only repeats the one before |
| `doneFile` | A file whose existence, newer than the queue's start, means the item is finished. `{cwd}` is the script's working folder |

How an argument is read against `item`:

- Each part is letters, digits, `-`, `_` and `.` only, and the first part has at least one letter. So `12:30` and `http://example.com` are not taken for items.
- A part ends at the first place the text that follows it in the pattern appears: with `{a}-{b}`, `s040-explode-wide` is `s040` and `explode-wide`.
- Arguments that start with `-` are options, not items, and the script's own path is not an item.

Your rules are tried first, then the standard one. It is, written out:

```json
{ "item": "{scene}:{shot}", "flags": { "--scene": "{scene}", "--shot": "{shot}" }, "contains": "{scene}-{shot}" }
```

with `queueDoneFile` as its `doneFile`. To switch it off, add `"standardQueue": false`.

## ComfyUI

A ComfyUI server on this Mac is read without any rule: see [COMFYUI.md](COMFYUI.md). `"comfyui": false` leaves it alone.

## Checking a rule

```bash
renderdock status
```

prints what the scanner sees, with your rules applied. Set `RENDERDOCK_ADAPTERS=/path/to/file.json` to try a rules file without installing it.

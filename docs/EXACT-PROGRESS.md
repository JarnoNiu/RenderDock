# Exact progress

> New in 0.2.

RenderDock shows a percentage only when it knows the total. There are seven ways it can know. Use whichever fits how you start renders.

| Way | You change | Works when |
|---|---|---|
| 1. Put the frame range on the command line | nothing, if you already do | `blender -b … -s 1 -e 250 -a` or `-f 1..250` |
| 2. Start the job with `renderdock run --` | one word in front of your command | the range is inside the `.blend`, or the output folder is |
| 3. Print `FRAME i/N` lines | one `print` in your script, plus the wrapper | your script renders frame by frame itself |
| 4. Write `render-progress.json` | one line in your script | you would rather not wrap the command |
| 5. Load the Blender hook | one `--python` argument, or an add-on | you render from the Blender window, or cannot wrap the command |
| 6. Send the output to a log file (from 0.3) | nothing, if you already do | `blender -b … > render.log` |
| 7. Leave the range in the `.blend` (from 0.3) | nothing | `blender -b file.blend -a`, with a file saved without compression |

An ffmpeg encode has no frames to count on and is its own case: see [ffmpeg](#ffmpeg-from-03) below.

## `renderdock run`

```bash
renderdock run -- blender -b shot_010.blend -a
```

It runs the command exactly as you wrote it. Input and output pass straight through, byte for byte, and the wrapper exits with the command's own exit status, so it can sit inside an existing script or pipeline. On the way past, it reads the output:

- **Blender 5.x**: `Rendering animation (frames 1..250)` gives the total, `Fra: 12 | … | Sample 8/64` gives the frame and the samples inside it, `Saved: '…'` marks a frame as finished.
- **Blender 4.x**: `Fra:12 Mem:… | … Sample 8/64`, `Saved: '…'`, `Append frame 12`.
- **Anything**: a line that starts with `FRAME 12/720` or `PROGRESS 12/720`.

What you get in the panel:

- An exact percentage and time left, even when neither the range nor the output folder is on the command line.
- Progress inside a long frame: a half-sampled frame counts as half a frame.
- When the job ends, RenderDock knows whether it **finished** (exit status 0) or **failed**, and says so in the notification and in the `job.ended` event. Without the wrapper it can only say the job has ended.

Options, before the `--`:

| Option | |
|---|---|
| `--name NAME` | What to call the job in the panel |
| `--total N` | The number of frames, if you know it and the output does not say |

Several files with the same frame number (a beauty pass and a shadow pass, say) count as one frame. Files without a number whose name starts with `_` are treated as temporary and not counted.

### Where the command lives

It ships inside the app. After `zsh scripts/install.sh`:

```bash
/Applications/RenderDock.app/Contents/Helpers/renderdock version
```

To call it as `renderdock`, link it somewhere on your `PATH`, or add an alias to your shell profile:

```bash
alias renderdock=/Applications/RenderDock.app/Contents/Helpers/renderdock
```

### In a pipeline that starts Blender for you

If a tool launches Blender from a path it reads from a setting or an environment variable, point that setting at a two-line script:

```bash
#!/bin/zsh
exec /Applications/RenderDock.app/Contents/Helpers/renderdock run -- /Applications/Blender.app/Contents/MacOS/Blender "$@"
```

The tool still sees Blender's output and exit status unchanged.

### It is not only for Blender

Any long job started through the wrapper shows up as a card: elapsed time, CPU and memory, and progress if it prints `FRAME i/N` lines.

```bash
renderdock run --name "encode trailer" -- ./encode.sh
```

An ffmpeg command wrapped this way shows real progress with nothing more to do: see [ffmpeg](#ffmpeg-from-03).

### What the wrapper writes, and where

One small JSON file per job in `~/Library/Application Support/RenderDock/reports/`, named after the process id. It holds frames done, the total, the output folder, the times the latest frames finished and, at the end, the exit status. Reports older than three days are removed.

**Nothing is written into your render folder.**

### Limits

- The command sees a pipe on its standard output, not a terminal. Programs that colour their output only for a terminal will print plain text.
- Standard output and standard error are passed through separately, so their relative order on screen can differ slightly from an unwrapped run.
- Wrap the render itself, not a script that runs several renders one after another: one wrapper keeps one count.
- Checked with Blender 5.2 (Cycles and EEVEE). The 4.x line formats are taken from Blender's source and have not been run.

## `FRAME i/N` lines

If your script renders frames in its own loop, print the count and start the script through the wrapper:

```python
print(f"FRAME {i + 1}/{len(frames)}", flush=True)
```

These lines take precedence over everything else the wrapper could infer.

## `render-progress.json`

Without the wrapper: after each frame, write this file into the output folder.

```json
{"done": 12, "total": 720}
```

```python
(out_dir / "render-progress.json").write_text(json.dumps({"done": i + 1, "total": len(frames)}))
```

## The Blender hook

`blender/renderdock_hook.py` reports from inside Blender. Installed copies of the app carry it at `/Applications/RenderDock.app/Contents/Resources/renderdock_hook.py`.

On the command line, load it before the render flags:

```bash
blender -b scene.blend --python /Applications/RenderDock.app/Contents/Resources/renderdock_hook.py -a
```

Or install it as an add-on (Preferences → Add-ons → Install from Disk) and enable **RenderDock Hook**: then renders started from the Blender window appear in RenderDock too.

What it reports depends on how Blender was asked to render, because it only reports what it can count honestly:

| How Blender renders | What the hook reports |
|---|---|
| `-b … -a` | The scene's frame range, including the step. Exact total |
| `-b … -f 1,5` or `-f 1..250` | The listed frames, counted together across the `-f` flags |
| From the Blender window | One report per render. For an animation the total is known from the second frame on |
| `-b` with a Python script that calls the renderer itself | **Nothing.** Such a script may render several passes per frame, or frames that are not scene frames, so the hook cannot know what a frame is. Print `FRAME i/N` and use the wrapper instead |

The hook writes the same kind of report as the wrapper, in the same place, and nothing anywhere else. It does not touch the scene, the render settings or the output folder.

Checked with Blender 5.2 on the command line. Not yet checked: Blender 4.x, and the add-on route in the Blender window.

## A log file (from 0.3)

If a render's output is redirected to a file, RenderDock reads Blender's own frame lines from that file. Nothing to install and nothing to change:

```bash
blender -b scene.blend -a > render.log 2>&1
```

It works even when the frame range and the output folder are only in the `.blend`: Blender 5.x prints the range at the start, and every saved frame names its folder.

- Only a regular file counts: not a terminal, not a pipe to another program.
- Several renders may append to one log, one after another. RenderDock counts only what follows the previous render's last line.
- Two renders writing to the same log at the same time cannot be told apart. Give each its own file.
- The file is only ever read.

## The range stored in the `.blend` (from 0.3)

`blender -b file.blend -a` renders the range the scene was saved with, and the command line does not say what it is. RenderDock now reads it from the file: the active scene's start, end and step, or those of the scene named with `-S`. Where the command line gives part of the range (`-s 100 -a`), that part is taken from the command line and the rest from the file.

- The file is only ever read, and only the handful of bytes that hold the range.
- A file saved with Blender's **Compress** option cannot be read this way. Such a job shows up as before, with frames counted and no total. (Use the wrapper, or put the range on the command line.)
- If the command line also runs a script (`-P`, `--python`, `--python-expr`), the script may change the range before the render starts. The total is then shown as an estimate, marked `≈`, until something better says otherwise: with the wrapper or a log file, Blender's own "Rendering animation (frames 1..250)" line does.
- Checked with files saved by Blender 5.2. The older file layout (before Blender 5) is read too; that part is written from the published format and has been run only against files put together in the project's own checks.

## ffmpeg (from 0.3)

An encode is shown by how much of the output has been written, against how long the output will be: `0:12 / 1:30`, a percentage, the speed, and the time left.

RenderDock gets that from ffmpeg's own status line, in either of two ways:

```bash
renderdock run -- ffmpeg -i in.mov -c:v libx264 out.mp4      # wrapped
ffmpeg -i in.mov -c:v libx264 out.mp4 2> encode.log          # or with its output sent to a file
```

An ffmpeg started any other way (in a terminal, in a script that does not redirect it) is listed as before: encoding, with CPU and memory, without a percentage. Its status line goes to the terminal, and RenderDock does not read terminals.

How long the output will be is worked out from what ffmpeg prints about its inputs and from the command line:

| The command line | The length is |
|---|---|
| one input, nothing that changes timing | that input's length: exact |
| `-t 10` shorter than every input | 10 seconds: exact |
| several inputs of different lengths, a seek (`-ss`, `-to`), `-shortest`, or a filter that changes timing (`setpts`, `trim`, `atempo`, …) | the longest input, as an estimate, marked `≈` |
| inputs joined with a `concat` filter | their lengths added up, as an estimate |
| ffmpeg told not to print about its inputs (`-loglevel error -stats`) | not known: the position is shown, without a percentage |

If the output runs past the length it was thought to have, the guess is dropped and only the position is shown. `-progress pipe:1` output is read as well as the status line. With `-nostats` and no `-progress` there is nothing to read.

Checked with ffmpeg 9.0, wrapped and with a log file: video, audio only, `-t`, and `-progress`.

## Which one wins

When several are present for the same job: `render-progress.json`, then the wrapper's or the hook's report, then the log file, then the command line, then the range in the `.blend`, then the estimate from an older clip (marked `≈`).

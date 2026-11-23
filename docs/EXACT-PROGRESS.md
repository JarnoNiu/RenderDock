# Exact progress

> New in 0.2.

RenderDock shows a percentage only when it knows the total. There are five ways it can know. Use whichever fits how you start renders.

| Way | You change | Works when |
|---|---|---|
| 1. Put the frame range on the command line | nothing, if you already do | `blender -b … -s 1 -e 250 -a` or `-f 1..250` |
| 2. Start the job with `renderdock run --` | one word in front of your command | the range is inside the `.blend`, or the output folder is |
| 3. Print `FRAME i/N` lines | one `print` in your script, plus the wrapper | your script renders frame by frame itself |
| 4. Write `render-progress.json` | one line in your script | you would rather not wrap the command |
| 5. Load the Blender hook | one `--python` argument, or an add-on | you render from the Blender window, or cannot wrap the command |

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

## Which one wins

When several are present for the same job: `render-progress.json`, then the wrapper's report, then the command line, then the estimate from an older clip (marked `≈`).

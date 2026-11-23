# RenderDock hook for Blender.
#
# Reports render progress to RenderDock from inside Blender, so renders started from the Blender
# window show up too, and the total is exact even when the frame range lives in the .blend.
#
# Two ways to use it:
#
#   1. On the command line, before the render flags:
#        blender -b scene.blend --python renderdock_hook.py -a
#   2. As an add-on: Preferences → Add-ons → Install from Disk, pick this file, enable "RenderDock Hook".
#
# It writes one small JSON file per Blender process to
#   ~/Library/Application Support/RenderDock/reports/<pid>.json
# and nothing anywhere else. It never touches the scene, the render settings or the output folder.
#
# Works with Blender 4.2 and later. Checked with 5.2; the 4.x path has not been run.

bl_info = {
    "name": "RenderDock Hook",
    "author": "RenderDock",
    "version": (0, 2, 0),
    "blender": (4, 2, 0),
    "location": "Runs in the background while rendering",
    "description": "Reports render progress to RenderDock (https://github.com/JarnoNiu/RenderDock)",
    "category": "Render",
}

import json
import os
import re
import subprocess
import sys
import time

import bpy
from bpy.app.handlers import persistent

_SAMPLES = re.compile(r"Sample (\d+)/(\d+)|Rendering (\d+) / (\d+) samples")
_state = {"report": None, "first_frame": None, "last_write": 0.0}


def _reports_dir():
    custom = os.environ.get("RENDERDOCK_REPORTS")
    return custom or os.path.expanduser("~/Library/Application Support/RenderDock/reports")


def _process_start():
    """When this Blender process started. RenderDock matches a report to a process by pid AND start time."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-o", "lstart=", "-p", str(os.getpid())],
            capture_output=True, text=True, timeout=3, env={"LC_ALL": "C", "PATH": "/bin:/usr/bin"},
        ).stdout.strip()
        return time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y"))
    except Exception:
        return time.time()


_STARTED = _process_start()


def _write(force=False):
    report = _state["report"]
    if report is None:
        return
    now = time.time()
    if not force and now - _state["last_write"] < 0.5:
        return
    report["updatedAt"] = now
    try:
        folder = _reports_dir()
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, "%d.json" % os.getpid())
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({k: v for k, v in report.items() if v is not None}, f, sort_keys=True)
        os.replace(tmp, path)
        _state["last_write"] = now
    except OSError:
        pass   # reporting must never get in the way of the render


def _own_arguments():
    return sys.argv[: sys.argv.index("--")] if "--" in sys.argv else sys.argv


def _frames_on_command_line():
    """How many frames the -f flags ask for (-f 1,5  -f 1..250). None when a flag cannot be counted (+10, -1)."""
    argv = _own_arguments()
    count = 0
    for i, arg in enumerate(argv):
        if arg not in ("-f", "--render-frame") or i + 1 >= len(argv):
            continue
        for part in argv[i + 1].split(","):
            if part.startswith(("+", "-")):
                return None
            if ".." in part:
                a, _, b = part.partition("..")
                if not (a.isdigit() and b.isdigit()) or int(b) < int(a):
                    return None
                count += int(b) - int(a) + 1
            elif part.isdigit():
                count += 1
            else:
                return None
    return count or None


def _mode():
    """How this Blender was asked to render, which decides what can honestly be reported.

    ui      the Blender window: one report per render
    anim    -b … -a: the scene's frame range
    frames  -b … -f …: each listed frame is its own render; they are counted together
    script  -b with a Python script calling the renderer itself: the hook cannot know what a "frame" is
            there (several passes per frame, frames that are not scene frames), so it stays silent.
            Such scripts should print `FRAME i/N` and run under `renderdock run`, or write render-progress.json.
    """
    if not bpy.app.background:
        return "ui"
    argv = _own_arguments()
    if "-a" in argv or "--render-anim" in argv:
        return "anim"
    if "-f" in argv or "--render-frame" in argv:
        return "frames"
    return "script"


def _range_count(scene, start):
    step = max(1, scene.frame_step)
    return max(0, (scene.frame_end - start) // step) + 1


def _output_folder(scene):
    path = bpy.path.abspath(scene.render.filepath)
    if not path:
        return None
    folder = path if path.endswith(("/", os.sep)) else os.path.dirname(path)
    return os.path.normpath(folder) if os.path.isabs(folder) else None


@persistent
def _on_init(scene, *_):
    mode = _mode()
    if mode == "script":
        _state["report"] = None
        return
    if mode == "frames" and _state["report"] is not None:
        return   # the next frame of the same -f list: keep counting in the same report
    name = os.path.splitext(os.path.basename(bpy.data.filepath))[0] or None
    _state["report"] = {
        "v": 1, "pid": os.getpid(), "startedAt": _STARTED, "source": "hook", "name": name,
        "done": 0, "total": None, "frame": None, "sampleDone": None, "sampleTotal": None,
        "outDir": _output_folder(scene), "recent": [], "updatedAt": time.time(),
        "exitCode": None, "endedAt": None,
    }
    _state["first_frame"] = None
    if mode == "anim":
        _state["report"]["total"] = _range_count(scene, scene.frame_start)
    elif mode == "frames":
        _state["report"]["total"] = _frames_on_command_line()
    _write(force=True)


@persistent
def _on_pre(scene, *_):
    report = _state["report"]
    if report is None:
        return
    frame = scene.frame_current
    report["frame"] = frame
    report["sampleDone"] = report["sampleTotal"] = None
    if _state["first_frame"] is None:
        _state["first_frame"] = frame
    elif report["total"] is None and not bpy.app.background:
        # In the Blender window there is no flag to tell an animation from a single image.
        # A second frame means it is an animation: from here on the total is known.
        report["total"] = _range_count(scene, _state["first_frame"])
    _write()


@persistent
def _on_post(scene, *_):
    report = _state["report"]
    if report is None:
        return
    report["done"] += 1
    report["recent"] = (report["recent"] + [time.time()])[-30:]
    report["sampleDone"] = report["sampleTotal"] = None
    _write(force=True)


@persistent
def _on_stats(text, *_):
    report = _state["report"]
    if report is None or not isinstance(text, str):
        return
    m = _SAMPLES.search(text)
    if m:
        done, total = (m.group(1), m.group(2)) if m.group(1) else (m.group(3), m.group(4))
        report["sampleDone"], report["sampleTotal"] = int(done), int(total)
        _write()


def _finish(code):
    report = _state["report"]
    if report is None:
        return
    if code == 0 and report["total"] is None:
        report["total"] = report["done"]   # a single image, or a script-driven render: now we know
    report["exitCode"] = code
    report["endedAt"] = time.time()
    _write(force=True)
    _state["report"] = None


@persistent
def _on_complete(scene, *_):
    report = _state["report"]
    if report is None:
        return
    if _mode() == "frames" and (report["total"] is None or report["done"] < report["total"]):
        # More frames of the -f list are still to come (or cannot be counted): the job is not over.
        # If the process ends without getting there, RenderDock reports it as ended, not as finished.
        _write(force=True)
        return
    _finish(0)


@persistent
def _on_cancel(scene, *_):
    _finish(130)   # cancelled: reported like an interrupted process


_HANDLERS = (
    ("render_init", _on_init), ("render_pre", _on_pre), ("render_post", _on_post),
    ("render_stats", _on_stats), ("render_complete", _on_complete), ("render_cancel", _on_cancel),
)


def register():
    for name, fn in _HANDLERS:
        handlers = getattr(bpy.app.handlers, name)
        if fn not in handlers:
            handlers.append(fn)


def unregister():
    for name, fn in _HANDLERS:
        handlers = getattr(bpy.app.handlers, name)
        if fn in handlers:
            handlers.remove(fn)


if __name__ == "__main__":
    register()   # loaded with --python

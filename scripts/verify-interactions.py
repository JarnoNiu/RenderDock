#!/usr/bin/env python3
"""RenderDock interaction check: injects simulated clicks and drags into an instance launched with --debug, then reads back the window state to verify it.

Usage: python3 -I scripts/verify-interactions.py build/RenderDock.app/Contents/MacOS/RenderDock

What it checks is the app's own logic (click to expand, button to collapse, drag snapping, anchors, returning to the original place after collapsing).
What it can't check: real-mouse click-through and auto-collapse when clicking elsewhere (these need system-level events) — test those two by hand.
During the check the window moves around the main screen by itself a few times, and ends up at the top-right corner of the main screen.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

R = sys.argv[1]
TMP = tempfile.mkdtemp()
TOL = 1.5
results = []


def send(cmd):
    subprocess.run([R, "--send", cmd], check=True)


def state():
    path = os.path.join(TMP, "state.json")
    if os.path.exists(path):
        os.remove(path)
    send(f"state {path}")
    for _ in range(60):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            try:
                with open(path) as f:
                    return json.load(f)
            except ValueError:
                pass
        time.sleep(0.05)
    sys.exit("No state read back: was the app launched without --debug?")


def check(name, ok, detail=""):
    results.append(ok)
    print(("✓ " if ok else "✗ ") + name + (f"  （{detail}）" if detail else ""))


def near(a, b):
    return abs(a - b) <= TOL


def mouse(*points):
    send("mouse " + " ".join(f"{x:.1f},{y:.1f}" for x, y in points))


def rect(s):
    x, y, w, h = s["visual"]
    return x, y, w, h


# Pin the panel for the whole run: otherwise a real click elsewhere on the desktop collapses it mid-test
send("pin on")
send("collapse")
time.sleep(0.8)
send("reset")
time.sleep(0.8)
s = state()
x, y, w, h = rect(s)
ax, ay, aw, ah = s["screenVisible"]
check("Reset: capsule at the top-right of the main screen", not s["expanded"] and near(s["gapRight"], 10) and near(s["gapTop"], 6) and s["anchor"] == "right-top",
      f"right {s['gapRight']:.0f} top {s['gapTop']:.0f} width {w:.0f}×height {h:.0f}")

# Click the capsule → expands, growing down-left from the top-right corner
mouse((x + w / 2, y + h / 2))
time.sleep(1.2)
s = state()
px, py, pw, ph = rect(s)
check("Click the capsule: expands into the panel", s["expanded"] and near(pw, 388), f"{pw:.0f}×{ph:.0f}")
check("Top-right corner stays put after expanding", near(s["gapRight"], 10) and near(s["gapTop"], 6), f"right {s['gapRight']:.0f} top {s['gapTop']:.0f}")

# Click the collapse button at the top right
mouse((px + pw - 27, py + ph - 29))
time.sleep(1.1)
s = state()
x, y, w, h = rect(s)
check("Click the collapse button: back to a capsule, in its original place", not s["expanded"] and near(h, 42) and near(s["gapRight"], 10) and near(s["gapTop"], 6),
      f"right {s['gapRight']:.0f} top {s['gapTop']:.0f}")

# Drag near the bottom-left corner → snaps to the bottom-left corner
cx, cy = x + w / 2, y + h / 2
mouse((cx, cy), (ax + 22 + w / 2, ay + 26 + h / 2))
time.sleep(1.3)
s = state()
x, y, w, h = rect(s)
check("Drag near the bottom-left corner: snaps to the bottom-left corner", near(s["gapLeft"], 10) and near(s["gapBottom"], 10) and s["anchor"] == "left-bottom",
      f"left {s['gapLeft']:.0f} bottom {s['gapBottom']:.0f} anchor {s['anchor']}")
check("Releasing after a drag is not treated as a click", not s["expanded"])

# Expand at the bottom-left corner → grows up and to the right
mouse((x + w / 2, y + h / 2))
time.sleep(1.2)
s = state()
px, py, pw, ph = rect(s)
check("Expand at the bottom-left: that corner stays put, the panel grows up and to the right", s["expanded"] and near(s["gapLeft"], 10) and near(s["gapBottom"], 10),
      f"left {s['gapLeft']:.0f} bottom {s['gapBottom']:.0f} height {ph:.0f}")

# While expanded, grab the header and drag it to the top centre → snaps to the centre of the top edge
dx = (ax + aw / 2 + 9) - (px + pw / 2)
dy = (ay + ah - 16) - (py + ph)
gx, gy = px + 130, py + ph - 29
mouse((gx, gy), (gx + dx, gy + dy))
time.sleep(1.3)
s = state()
px, py, pw, ph = rect(s)
check("Drag the header to the top centre while expanded: snaps to the centre of the top edge", s["expanded"] and s["anchor"] == "center-top" and near(px + pw / 2, ax + aw / 2) and near(s["gapTop"], 6),
      f"centre-line offset {px + pw / 2 - (ax + aw / 2):.1f} top {s['gapTop']:.0f}")

send("collapse")
time.sleep(1.1)
s = state()
x, y, w, h = rect(s)
check("Collapse at the top centre: the capsule is centred", not s["expanded"] and near(x + w / 2, ax + aw / 2) and near(s["gapTop"], 6),
      f"centre-line offset {x + w / 2 - (ax + aw / 2):.1f}")

# Drag to the middle of the screen, a little down-left → no snap, stays where it is
tx, ty = ax + aw / 2 - 260, ay + ah / 2 - 120
mouse((x + w / 2, y + h / 2), (tx, ty))
time.sleep(1.3)
s = state()
x, y, w, h = rect(s)
free = min(s["gapLeft"], s["gapRight"], s["gapTop"], s["gapBottom"]) > 40
check("Drag to the middle of the screen: no snap, stays where it was released", free and near(x + w / 2, tx) and near(y + h / 2, ty) and s["anchor"] == "left-bottom",
      f"centre ({x + w / 2:.0f}, {y + h / 2:.0f}), target ({tx:.0f}, {ty:.0f}), anchor {s['anchor']}")

# Expand in the middle, then collapse → back to the original place
home = (x, y)
mouse((x + w / 2, y + h / 2))
time.sleep(1.2)
s = state()
px, py, pw, ph = rect(s)
# When the whole panel does not fit above, it is pushed down as a whole back onto the screen (leaving 4 from the top edge)
anchored = near(py, home[1]) or (py < home[1] and s["gapTop"] < 10)
check("Expand in the middle of the screen: anchored at the capsule's bottom-left corner, pushed back onto the screen if it does not fit", s["expanded"] and near(px, home[0]) and anchored,
      f"({px:.0f}, {py:.0f}), top {s['gapTop']:.0f}")
send("collapse")
time.sleep(1.1)
s = state()
x, y, w, h = rect(s)
check("Back to the original place after collapsing", not s["expanded"] and near(x, home[0]) and near(y, home[1]), f"({x:.0f}, {y:.0f})")

send("pin off")
send("reset")
time.sleep(0.5)
print(f"\n{sum(results)}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)

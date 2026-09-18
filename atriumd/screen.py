"""Capture a tmux pane into a cell grid, and diff it against the last capture.

The whole premise of this project: tmux is already the terminal emulator, so
`capture-pane -p -e -N` hands us rendered cells. We parse only the colour
escapes (sgr.py), pad every row to the pane width, and emit row diffs.

⚠️ -N, never -J. -J joins wrapped lines, which destroys a fixed cell grid.
"""

import subprocess
import threading

import sgr

TMUX = "/usr/bin/tmux"


class CaptureError(RuntimeError):
    pass


def _tmux(args, timeout=5):
    try:
        p = subprocess.run(
            [TMUX] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise CaptureError("tmux timed out: %r" % (args,))
    except FileNotFoundError:
        raise CaptureError("tmux not found at %s" % TMUX)
    if p.returncode != 0:
        raise CaptureError(p.stderr.strip() or "tmux exit %d" % p.returncode)
    return p.stdout


def pane_info(target):
    """Geometry and cursor for a pane. One tmux call, not four."""
    fmt = "#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}\t#{alternate_on}\t#{pane_current_command}\t#{pane_pid}"
    out = _tmux(["display-message", "-p", "-t", target, fmt]).rstrip("\n")
    parts = out.split("\t")
    if len(parts) < 7 or any(p == "" for p in parts[:5]):
        # tmux exits 0 with empty fields for an unknown target, so a non-zero
        # return code is not enough to detect a bad pane.
        raise CaptureError("no such tmux target: %r" % target)
    return {
        "cols": int(parts[0]),
        "rows": int(parts[1]),
        "cursor": {"x": int(parts[2]), "y": int(parts[3]), "visible": True},
        "alt": parts[4] == "1",
        "command": parts[5],
        "pid": int(parts[6]),
    }


def capture(target, info=None):
    """Return a full frame: {cols, rows, alt, cursor, grid:[[run,...],...]}."""
    if info is None:
        info = pane_info(target)
    cols = info["cols"]
    nrows = info["rows"]

    raw = _tmux(["capture-pane", "-p", "-e", "-N", "-t", target])
    lines = raw.split("\n")
    # capture-pane emits a trailing empty element from the final newline
    if lines and lines[-1] == "":
        lines.pop()

    # Pad or trim to the pane height so the grid is always rows x cols.
    if len(lines) < nrows:
        lines = lines + [""] * (nrows - len(lines))
    elif len(lines) > nrows:
        lines = lines[-nrows:]

    grid = []
    style = None
    for ln in lines:
        runs, style = sgr.parse_line(ln, cols, style)
        grid.append(runs)

    return {
        "cols": cols,
        "rows": nrows,
        "alt": info["alt"],
        "cursor": info["cursor"],
        "grid": grid,
    }


class PaneMirror:
    """Holds the last frame for one pane and produces diffs against it."""

    def __init__(self, target):
        self.target = target
        self.rev = 0
        self.last = None
        # ⚠️ The screen loop polls this mirror on its own thread while a client
        # thread can ask for a full frame. Without the lock, `full()` clearing
        # `last` and the loop refilling it interleave, and the client's "give me
        # everything" comes back None — a panel that stays blank until the pane
        # happens to change. Cheap: one capture per mirror at 12 Hz.
        self._lock = threading.Lock()

    def poll(self):
        """Capture and return a frame message, or None if nothing changed.

        base == 0 means a full frame (every row). Otherwise base is the rev
        this diff applies to, and only changed rows are included.
        """
        with self._lock:
            return self._poll()

    def _poll(self):
        info = pane_info(self.target)
        frame = capture(self.target, info)

        prev = self.last
        geometry_changed = (
            prev is None
            or prev["cols"] != frame["cols"]
            or prev["rows"] != frame["rows"]
        )

        if geometry_changed:
            changed = list(range(frame["rows"]))
            base = 0
        else:
            changed = [
                y for y in range(frame["rows"])
                if frame["grid"][y] != prev["grid"][y]
            ]
            cursor_moved = prev["cursor"] != frame["cursor"] or prev["alt"] != frame["alt"]
            if not changed and not cursor_moved:
                self.last = frame
                return None
            base = self.rev

        self.rev += 1
        self.last = frame
        return {
            "type": "screen",
            "key": self.target,
            "rev": self.rev,
            "base": base,
            "cols": frame["cols"],
            "rows": frame["rows"],
            "alt": frame["alt"],
            "cursor": frame["cursor"],
            "lines": [{"y": y, "runs": frame["grid"][y]} for y in changed],
        }

    def full(self):
        """Force a complete frame — used when a client connects or resyncs."""
        with self._lock:
            self.last = None
            return self._poll()


def crop_runs(runs, width):
    """Keep the leftmost `width` cells of a run list, padding if a wide glyph
    straddles the cut. Result is exactly `width` cells wide."""
    out = []
    used = 0
    for fg, bg, attrs, text in runs:
        if used >= width:
            break
        buf = []
        for ch in text:
            w = sgr.char_width(ch)
            if used + w > width:
                break
            buf.append(ch)
            used += w
        if buf:
            out.append([fg, bg, attrs, "".join(buf)])
        if used < width and len(buf) < len(text):
            break
    if used < width:
        pad = " " * (width - used)
        last = out[-1] if out else None
        if last and last[0] == sgr.DEFAULT and last[1] == sgr.DEFAULT and last[2] == 0:
            last[3] += pad
        else:
            out.append([sgr.DEFAULT, sgr.DEFAULT, 0, pad])
    return out


def crop_frame(msg, cols, rows):
    """A `screen` message viewed through a smaller window: the bottom `rows`
    lines (where the prompt lives) and the leftmost `cols` cells.

    Used for sessions that opted out of pinning: the desktop keeps its size
    and the headset shows what fits. Row indices, the cursor and diff
    semantics all shift consistently, so a client cannot tell the pane is
    bigger than what it sees. A frame that already fits is returned as-is."""
    R, C = msg["rows"], msg["cols"]
    r = min(rows, R) if rows and rows > 0 else R
    c = min(cols, C) if cols and cols > 0 else C
    if r == R and c == C:
        return msg
    off = R - r
    lines = []
    for ln in msg.get("lines", []):
        y = ln["y"] - off
        if 0 <= y < r:
            lines.append({"y": y, "runs": crop_runs(ln["runs"], c) if c != C else ln["runs"]})
    cur = dict(msg.get("cursor") or {})
    if cur:
        cur["y"] = cur.get("y", 0) - off
        if cur["y"] < 0 or cur.get("x", 0) >= c:
            cur["visible"] = False
            cur["y"] = max(0, min(cur["y"], r - 1))
            cur["x"] = min(cur.get("x", 0), c - 1)
    out = dict(msg)
    out.update({"cols": c, "rows": r, "cursor": cur, "lines": lines, "cropped": [C, R]})
    return out


def to_text(frame_grid):
    """Plain-text mirror of a grid — the zero-client-code verification path."""
    return "\n".join(sgr.runs_to_text(r).rstrip() for r in frame_grid)

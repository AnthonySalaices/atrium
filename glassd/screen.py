"""Capture a tmux pane into a cell grid, and diff it against the last capture.

The whole premise of this project: tmux is already the terminal emulator, so
`capture-pane -p -e -N` hands us rendered cells. We parse only the colour
escapes (sgr.py), pad every row to the pane width, and emit row diffs.

⚠️ -N, never -J. -J joins wrapped lines, which destroys a fixed cell grid.
"""

import subprocess

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

    def poll(self):
        """Capture and return a frame message, or None if nothing changed.

        base == 0 means a full frame (every row). Otherwise base is the rev
        this diff applies to, and only changed rows are included.
        """
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
        self.last = None
        return self.poll()


def to_text(frame_grid):
    """Plain-text mirror of a grid — the zero-client-code verification path."""
    return "\n".join(sgr.runs_to_text(r).rstrip() for r in frame_grid)

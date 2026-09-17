"""Pin a tmux window to VR geometry — and always put it back.

⛔ THE RULE: never resize somebody's live session without a recorded
previous value and a restore path. A host running `window-size latest` with real
real panes are ~258x62; leaving one at 80x28 after the headset drops off the
network would break their desktop work every single day.

Restore fires on: unsubscribe, client disconnect, a silence watchdog, and
tools/unpin.sh as a manual escape hatch.
"""

import subprocess
import threading
import time

TMUX = "/usr/bin/tmux"
# ⚠️ Was 90 s. The headset stops sending keepalives every time the app is
# backgrounded (taking the headset off does it), so a short timeout restored
# the wide desktop geometry, the agent redrew wide, and on resume the re-pin
# left every already-drawn line truncated at 80 columns — "the text cuts off
# instead of wrapping" (owner, 9/17). Ten minutes covers a coffee break; the
# daily pane still comes back if the headset really is gone.
SILENCE_TIMEOUT = 600.0

_lock = threading.Lock()
_pinned = {}                  # key -> {"size": str, "cols": int, "rows": int, "seen": float}


def _tmux(args, timeout=5):
    try:
        p = subprocess.run([TMUX] + args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def _get_window_size(key):
    """Returns the explicit value, or None when the option is UNSET.

    ⚠️ The difference matters: writing "latest" back onto a window that had no
    explicit value leaves an override that was never there. Restoring must
    UNSET it (`set-option -u`) in that case.
    """
    v = _tmux(["show-options", "-w", "-v", "-t", key, "window-size"])
    return v if v else None


def pin(key, cols, rows):
    """Resize `key` to cols x rows, remembering what it was."""
    with _lock:
        if key in _pinned:
            _pinned[key]["seen"] = time.time()
            return True
        prev = _get_window_size(key)        # None = was unset
        cur = _tmux(["display-message", "-p", "-t", key, "#{window_width}\t#{window_height}"])
        pc, pr = (0, 0)
        if cur and "\t" in cur:
            a, b = cur.split("\t")[:2]
            try:
                pc, pr = int(a), int(b)
            except ValueError:
                pass
        if _tmux(["set-option", "-w", "-t", key, "window-size", "manual"]) is None:
            return False
        _tmux(["resize-window", "-t", key, "-x", str(cols), "-y", str(rows)])
        _pinned[key] = {"size": prev, "cols": pc, "rows": pr, "seen": time.time()}
        print("[pin] %s -> %dx%d (was %dx%d, window-size %s)"
              % (key, cols, rows, pc, pr, prev if prev else "<unset>"), flush=True)
        return True


def keepalive(key):
    with _lock:
        if key in _pinned:
            _pinned[key]["seen"] = time.time()


def unpin(key):
    """Put the window back exactly as it was."""
    with _lock:
        st = _pinned.pop(key, None)
    if st is None:
        return False
    if st["size"] is None:
        # ⚠️ ORDER MATTERS. resize-window SETS window-size to manual, so putting
        # the dimensions back must come FIRST and the unset LAST — otherwise the
        # resize re-creates the very override we are removing. Doing it the other
        # way round leaves the session at VR geometry (a detached session has no
        # client to re-derive from), which is the bug this whole module exists
        # to prevent.
        if st["cols"] and st["rows"]:
            _tmux(["resize-window", "-t", key, "-x", str(st["cols"]), "-y", str(st["rows"])])
        _tmux(["set-option", "-w", "-u", "-t", key, "window-size"])
    else:
        _tmux(["set-option", "-w", "-t", key, "window-size", st["size"]])
        if st["size"] == "manual" and st["cols"] and st["rows"]:
            _tmux(["resize-window", "-t", key, "-x", str(st["cols"]), "-y", str(st["rows"])])
    print("[pin] %s restored (window-size %s)"
          % (key, st["size"] if st["size"] else "<unset>"), flush=True)
    return True


def unpin_all():
    for key in list(_pinned.keys()):
        unpin(key)


def watchdog_loop():
    """A client that vanishes without saying goodbye must not leave a pin."""
    while True:
        now = time.time()
        stale = []
        with _lock:
            for key, st in _pinned.items():
                if now - st["seen"] > SILENCE_TIMEOUT:
                    stale.append(key)
        for key in stale:
            print("[pin] %s silent for %.0fs — restoring" % (key, SILENCE_TIMEOUT), flush=True)
            unpin(key)
        time.sleep(5.0)


def status():
    with _lock:
        return {k: dict(v) for k, v in _pinned.items()}

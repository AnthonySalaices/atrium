"""Pin a tmux window to VR geometry — and always put it back.

⛔ THE RULE: never resize somebody's live session without a recorded
previous value and a restore path. A host running `window-size latest` with real
real panes are ~258x62; leaving one at 80x28 after the headset drops off the
network would break their desktop work every single day.

Restore fires on: unsubscribe, client disconnect, a silence watchdog, daemon
exit (SIGTERM/SIGINT), daemon start (`recover`), and tools/unpin.sh as a
manual escape hatch.

⚠️ The restore record lives ON THE TMUX WINDOW (`@atrium_prev`), not only
in this process. 9/17 the daemon was restarted while a window was pinned; the
new process saw "80x28, manual" as the previous geometry and could never put
the desktop back — the user's desktop session stayed shrunk. A tmux user option
survives us; an in-memory dict does not.

A window can opt out of pinning entirely: `tmux set -w @atrium_pin off`
(`atrium pin off`). The headset then receives a crop of the desktop-sized
pane instead (see screen.crop_frame).
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

PIN_OPT = "@atrium_pin"     # user-set on a window: "off" = never resize this one
PREV_OPT = "@atrium_prev"   # daemon-set: "<window-size>|<cols>|<rows>", "-" = unset

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


def opted_out(key):
    """True when the window carries `@atrium_pin off`."""
    v = _tmux(["show-options", "-w", "-v", "-t", key, PIN_OPT])
    return (v or "").strip().lower() in ("off", "0", "no", "false")


def is_pinned(key):
    with _lock:
        return key in _pinned


def _read_prev(key):
    """The restore record a previous daemon left on the window, or None."""
    v = _tmux(["show-options", "-w", "-v", "-t", key, PREV_OPT])
    if not v or "|" not in v:
        return None
    parts = v.split("|")
    try:
        size = None if parts[0] in ("", "-") else parts[0]
        return {"size": size, "cols": int(parts[1]), "rows": int(parts[2])}
    except (IndexError, ValueError):
        return None


def _write_prev(key, size, cols, rows):
    _tmux(["set-option", "-w", "-t", key, PREV_OPT,
           "%s|%d|%d" % (size if size else "-", cols, rows)])


def _clear_prev(key):
    _tmux(["set-option", "-w", "-u", "-t", key, PREV_OPT])


def _current_geometry(key):
    cur = _tmux(["display-message", "-p", "-t", key, "#{window_width}\t#{window_height}"])
    if cur and "\t" in cur:
        a, b = cur.split("\t")[:2]
        try:
            return int(a), int(b)
        except ValueError:
            pass
    return 0, 0


def pin(key, cols, rows):
    """Resize `key` to cols x rows, remembering what it was.

    Returns False without touching the window when it is opted out."""
    with _lock:
        if key in _pinned:
            _pinned[key]["seen"] = time.time()
            return True
        if opted_out(key):
            return False
        rec = _read_prev(key)
        adopted = rec is not None
        if adopted:
            # A previous daemon pinned this window and never restored it. Its
            # record is the truth; what tmux reports now is VR geometry.
            prev, pc, pr = rec["size"], rec["cols"], rec["rows"]
            print("[pin] %s adopting restore record left by a previous daemon (%dx%d, window-size %s)"
                  % (key, pc, pr, prev if prev else "<unset>"), flush=True)
        else:
            prev = _get_window_size(key)        # None = was unset
            pc, pr = _current_geometry(key)
            _write_prev(key, prev, pc, pr)
        if _tmux(["set-option", "-w", "-t", key, "window-size", "manual"]) is None:
            # ⚠️ Only drop a record we wrote ourselves a few lines ago. An
            # adopted one is the last surviving copy of the desktop geometry.
            if not adopted:
                _clear_prev(key)
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
    _clear_prev(key)
    print("[pin] %s restored (window-size %s)"
          % (key, st["size"] if st["size"] else "<unset>"), flush=True)
    return True


def unpin_all():
    for key in list(_pinned.keys()):
        unpin(key)


def recover():
    """Daemon start: put back any window a previous daemon left pinned.

    Nothing is subscribed yet at this point, so every leftover record is a
    window somebody is looking at on their desktop at headset geometry."""
    names = _tmux(["list-sessions", "-F", "#{session_name}"]) or ""
    n = 0
    for key in names.split("\n"):
        key = key.strip()
        if not key:
            continue
        rec = _read_prev(key)
        if rec is None:
            continue
        with _lock:
            _pinned[key] = dict(rec, seen=0.0)
        print("[pin] %s left pinned by a previous daemon — restoring" % key, flush=True)
        unpin(key)
        n += 1
    return n


def install_exit_hooks():
    """SIGTERM/SIGINT/atexit -> restore every pin before the process dies.

    Threads are daemonic, so without this a plain `kill` leaves every watched
    window at VR geometry with only the on-window record to recover from."""
    import atexit
    import os
    import signal

    atexit.register(unpin_all)

    def _bye(signum, frame):
        unpin_all()
        os._exit(0)

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, _bye)
        except (ValueError, OSError):
            pass


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

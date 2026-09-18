"""Follow mode: the pane takes the size of whoever typed last.

The alternative to pin.py. Instead of forcing a window to the headset's
geometry (which shrinks the desktop too — a tmux window has ONE size), the
daemon attaches a real tmux client in control mode per watched session, tells
tmux that client is cols x rows, and sets the window to `window-size latest`.
Type on the desktop and the window is desktop-sized; type in the headset and it
is headset-sized. Nothing to restore, no watchdog: when the headset goes quiet
the next desktop keystroke simply takes the window back, and when the daemon
dies its control clients get EOF and detach.

⚠️ Only a command FROM the client claims "latest". `send-keys` does not (tested
on tmux 3.3a); `select-window` does — so claim() runs before every keystroke
batch and scroll from the headset.
⚠️ `-f no-output`: a control client otherwise receives %output for every byte
the pane prints, and nothing here reads it.
"""

import subprocess
import threading

TMUX = "/usr/bin/tmux"

_lock = threading.Lock()
_clients = {}          # key -> {"proc": Popen, "cols": int, "rows": int}


def _tmux(args):
    try:
        return subprocess.run([TMUX] + args, capture_output=True, text=True, timeout=5)
    except Exception:
        return None


def _cmd(st, line):
    p = st["proc"]
    if p.poll() is not None:
        return False
    try:
        p.stdin.write(line + "\n")
        p.stdin.flush()
        return True
    except (BrokenPipeError, OSError, ValueError):
        return False


def _drain(p):
    """Replies to our commands still arrive (%begin/%end); read and discard."""
    try:
        for _ in p.stdout:
            pass
    except Exception:
        pass


def _target(key):
    # `=` = exact session match (see tmux_session_exists); trailing `:` = its
    # current window.
    return "=%s:" % key


def is_attached(key):
    with _lock:
        st = _clients.get(key)
        return bool(st) and st["proc"].poll() is None


def attach(key, cols, rows):
    """Watch `key` at cols x rows. Idempotent; a changed size re-sizes."""
    with _lock:
        st = _clients.get(key)
        if st and st["proc"].poll() is None:
            if (st["cols"], st["rows"]) != (cols, rows):
                st["cols"], st["rows"] = cols, rows
                _cmd(st, "refresh-client -C %dx%d" % (cols, rows))
            _cmd(st, "select-window -t %s" % _target(key))
            return True
        _tmux(["set-option", "-w", "-t", _target(key), "window-size", "latest"])
        try:
            p = subprocess.Popen([TMUX, "-C", "attach-session", "-f", "no-output", "-t", "=" + key],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1)
        except OSError:
            return False
        threading.Thread(target=_drain, args=(p,), daemon=True).start()
        st = {"proc": p, "cols": cols, "rows": rows}
        _clients[key] = st
        _cmd(st, "refresh-client -C %dx%d" % (cols, rows))
        _cmd(st, "select-window -t %s" % _target(key))
        print("[follow] %s attached at %dx%d (window-size latest)" % (key, cols, rows), flush=True)
        return True


def claim(key):
    """Make the headset the latest client of `key` — call before its input."""
    with _lock:
        st = _clients.get(key)
        if st:
            _cmd(st, "select-window -t %s" % _target(key))


def detach(key):
    with _lock:
        st = _clients.pop(key, None)
    if not st:
        return
    p = st["proc"]
    _cmd(st, "detach-client")
    try:
        p.stdin.close()
    except Exception:
        pass
    try:
        p.wait(timeout=2)
    except Exception:
        p.kill()
    print("[follow] %s detached" % key, flush=True)


def detach_all():
    for key in list(_clients):
        detach(key)

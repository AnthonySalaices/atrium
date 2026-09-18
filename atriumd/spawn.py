"""Open and close tmux sessions for the headset's New / Close buttons.

⛔ The client never names the command. It only says "new"; what runs is the
host's own config (`sessions.new`), so an authed client can start an agent but
cannot run an arbitrary program. Close is limited to a session the client is
already watching — the same rule as typing into one.
"""

import os
import re
import shlex
import subprocess

TMUX = "/usr/bin/tmux"
_NAME = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")


def _exists(name):
    p = subprocess.run([TMUX, "has-session", "-t", "=" + name],
                       capture_output=True, text=True, timeout=5)
    return p.returncode == 0


def next_name(prefix, exists=_exists):
    """cc, cc-2, cc-3 … — the same scheme as `cc new` on the desktop."""
    if not _NAME.match(prefix or ""):
        raise ValueError("sessions.new.prefix %r is not a valid session name" % prefix)
    name, n = prefix, 1
    while exists(name):
        n += 1
        name = "%s-%d" % (prefix, n)
    return name


def new_session(spec):
    """Start `spec["command"]` in a fresh detached session. Returns its name."""
    name = next_name(spec.get("prefix", "cc"))
    cwd = os.path.expanduser(spec.get("cwd") or "~")
    if not os.path.isdir(cwd):
        cwd = os.path.expanduser("~")
    argv = shlex.split(spec.get("command") or "claude")
    if not argv:
        raise ValueError("sessions.new.command is empty")
    p = subprocess.run([TMUX, "new-session", "-d", "-s", name, "-c", cwd, "--"] + argv,
                       capture_output=True, text=True, timeout=10)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or "tmux new-session failed").strip())
    return name


def close_session(name):
    if not _NAME.match(name or ""):
        raise ValueError("not a session name: %r" % name)
    p = subprocess.run([TMUX, "kill-session", "-t", "=" + name],
                       capture_output=True, text=True, timeout=10)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or "tmux kill-session failed").strip())

#!/usr/bin/env python3
"""Follow mode against real tmux: the pane takes the size of whoever typed last.

A "desktop" is a genuine tmux client attached from inside another session, so
tmux sees two clients exactly as it does with WezTerm + the headset.

    tools/follow-smoke.py

⚠️ Creates and kills `atrium-follow` and `atrium-follow-desk` only.
"""

import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "atriumd"))
import follow  # noqa: E402

T = "/usr/bin/tmux"
S, DESK = "atrium-follow", "atrium-follow-desk"
fails = []


def t(*a):
    return subprocess.run([T, *a], capture_output=True, text=True).stdout.strip()


def size():
    time.sleep(0.8)
    return t("display", "-p", "-t", "=" + S + ":", "#{window_width}x#{window_height}")


def check(ok, what, got=""):
    print(("  ok   " if ok else "  FAIL ") + what + ("" if ok else "  (got %s)" % got))
    if not ok:
        fails.append(what)


for s in (S, DESK):
    t("kill-session", "-t", "=" + s)
t("new-session", "-d", "-s", S, "-x", "210", "-y", "53", "bash --norc")
t("new-session", "-d", "-s", DESK, "-x", "210", "-y", "54", "env -u TMUX tmux attach -t =" + S)
try:
    got = size(); check(got.startswith("210x"), "desktop alone: desktop size", got)
    follow.attach(S, 80, 28)
    got = size(); check(got == "80x28", "headset attaches: 80x28", got)
    t("send-keys", "-t", "=" + DESK + ":", "y")
    got = size(); check(got.startswith("210x"), "desktop keystroke takes it back", got)
    follow.claim(S)
    got = size(); check(got == "80x28", "headset keystroke (claim) takes it again", got)
    follow.attach(S, 100, 30)
    got = size(); check(got == "100x30", "a new headset size applies live", got)
    follow.detach(S)
    got = size(); check(got.startswith("210x"), "detach: desktop size, nothing to restore", got)
    check(not follow.is_attached(S), "no control client left")
finally:
    follow.detach_all()
    for s in (S, DESK):
        t("kill-session", "-t", "=" + s)
print("all green" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)

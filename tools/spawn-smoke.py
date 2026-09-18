#!/usr/bin/env python3
"""End-to-end test for the headset's New / Close buttons, over the real socket.

  * new_session starts the host-configured command in the next free session
  * closing needs a subscription (a client cannot kill what it is not watching)
  * close kills the tmux session and broadcasts its removal

    tools/spawn-smoke.py

⚠️ Starts ONE real session from `sessions.new` (default: claude) and kills it
seconds later. It never closes a session it did not create.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, tmux, token          # noqa: E402

fails = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)


def wait_for(ws, pred, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        m = ws.recv(timeout=max(0.1, end - time.time()))
        if m and pred(m):
            return m
    return None


ws = WS("/ws?token=" + token())
ws.send({"op": "close_session", "key": "definitely-not-mine"})
m = wait_for(ws, lambda m: m.get("type") == "error")
check(m is not None and "not subscribed" in m.get("error", ""), "close refused for an unwatched session")

ws.send({"op": "new_session"})
m = wait_for(ws, lambda m: m.get("type") in ("session-created", "error"))
name = (m or {}).get("key", "")
check(m is not None and m.get("type") == "session-created" and name, "new_session -> session-created %s" % name)
if name:
    check(tmux("has-session", "-t", "=" + name).returncode == 0, "tmux session %s exists" % name)
    ws.send({"op": "subscribe", "key": name, "cols": 80, "rows": 28})
    time.sleep(1.5)
    ws.send({"op": "close_session", "key": name})
    m = wait_for(ws, lambda m: m.get("type") == "session-closed")
    check(m is not None, "close_session -> session-closed")
    time.sleep(0.5)
    check(tmux("has-session", "-t", "=" + name).returncode != 0, "tmux session %s is gone" % name)
    if tmux("has-session", "-t", "=" + name).returncode == 0:
        tmux("kill-session", "-t", "=" + name)
print("all green" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)

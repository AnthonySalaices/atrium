#!/usr/bin/env python3
"""End-to-end test for the headset's ⚙ panel, over the real socket.

  * set_settings writes settings.json and every client gets the new config
  * a path or value outside the panel schema is refused and changes nothing
  * reset_settings puts config.lua's value back
  * config.lua itself is never touched

    tools/settings-smoke.py

⚠️ Runs against the LIVE daemon and the user's real config dir. It saves
settings.json first and restores it byte for byte at the end.
"""

import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, token          # noqa: E402

CFG = os.path.expanduser("~/.config/atrium")
SP = os.path.join(CFG, "settings.json")
LUA = os.path.join(CFG, "config.lua")
fails = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)


def wait_for(ws, pred, timeout=6):
    end = time.time() + timeout
    while time.time() < end:
        m = ws.recv(timeout=max(0.1, end - time.time()))
        if m and pred(m):
            return m
    return None


def sha(p):
    try:
        return hashlib.sha256(open(p, "rb").read()).hexdigest()
    except OSError:
        return None


saved = open(SP, "rb").read() if os.path.exists(SP) else None
lua_before = sha(LUA)
ws = WS("/ws?token=" + token())
try:
    first = wait_for(ws, lambda m: m.get("type") == "config")
    check(first is not None and "settings" in first, "config frame carries the settings schema")
    hand0 = first["config"]["pointer"]["hand"]
    other = "left" if hand0 != "left" else "right"

    ws.send({"op": "set_settings", "values": {"pointer.hand": other}})
    m = wait_for(ws, lambda m: m.get("type") == "config"
                 and m["config"]["pointer"]["hand"] == other)
    check(m is not None and m["settings"]["overrides"].get("pointer.hand") == other,
          "set pointer.hand=%s -> broadcast config + override listed" % other)

    ws.send({"op": "set_settings", "values": {"sessions.new.command": "true"}})
    m = wait_for(ws, lambda m: m.get("type") == "error")
    check(m is not None and "not a panel setting" in m.get("error", ""), "unknown path refused")
    ws.send({"op": "set_settings", "values": {"pointer.hand": "tentacle"}})
    m = wait_for(ws, lambda m: m.get("type") == "error")
    check(m is not None and "cannot be" in m.get("error", ""), "bad value refused")

    ws.send({"op": "reset_settings", "keys": ["pointer.hand"]})
    m = wait_for(ws, lambda m: m.get("type") == "config"
                 and m["config"]["pointer"]["hand"] == hand0)
    check(m is not None and "pointer.hand" not in m["settings"]["overrides"],
          "reset -> config.lua value (%s) is back" % hand0)
    check(sha(LUA) == lua_before, "config.lua untouched")
finally:
    if saved is None:
        if os.path.exists(SP):
            os.remove(SP)
    else:
        open(SP, "wb").write(saved)
print("all green" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)

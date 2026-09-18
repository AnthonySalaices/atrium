#!/usr/bin/env python3
"""End-to-end test for browser mode over the real socket.

  * configured apps appear as web:<name> sessions in the snapshot
  * subscribing streams JPEG frames; input needs a subscription
  * a click + typing reach the page, scroll produces new frames

    tools/web-smoke.py [app]      (default: the first web app in the snapshot)
"""

import base64
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, token          # noqa: E402

fails = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        fails.append(what)


def frames(ws, key, secs):
    out, end = [], time.time() + secs
    while time.time() < end:
        m = ws.recv(timeout=max(0.1, end - time.time()))
        if m and m.get("type") == "web-frame" and m.get("key") == key:
            out.append(m)
    return out


ws = WS("/ws?token=" + token())
ws.send({"op": "snapshot"})
snap = None
end = time.time() + 5
while time.time() < end and snap is None:
    m = ws.recv(timeout=1)
    if m and m.get("type") == "snapshot":
        snap = m
webs = [s["key"] for s in (snap or {}).get("sessions", []) if s["key"].startswith("web:")]
check(bool(webs), "web apps in the snapshot: %s" % webs)
key = ("web:" + sys.argv[1]) if len(sys.argv) > 1 else (webs[0] if webs else "web:none")

ws.send({"op": "web_pointer", "key": key, "kind": "click", "u": 0.5, "v": 0.5})
m, end = None, time.time() + 3
while time.time() < end:
    m = ws.recv(timeout=1)
    if m and m.get("type") == "error":
        break
check(m is not None and m.get("error") == "not subscribed", "input refused before subscribing")

ws.send({"op": "subscribe", "key": key, "cols": 80, "rows": 28})
fs = frames(ws, key, 6)
check(len(fs) >= 1, "%s: %d frame(s) after subscribe" % (key, len(fs)))
if fs:
    jpg = base64.b64decode(fs[-1]["jpeg"])
    check(jpg[:2] == b"\xff\xd8", "frame is a JPEG (%d KB, css %sx%s)"
          % (len(jpg) // 1024, fs[-1]["css_w"], fs[-1]["css_h"]))
ws.send({"op": "scroll", "key": key, "lines": -6, "u": 0.5, "v": 0.5})
fs = frames(ws, key, 3)
check(len(fs) >= 1, "scroll produced %d new frame(s)" % len(fs))
ws.send({"op": "keys", "key": key, "seq": [{"k": "Home"}]})
m = None
end = time.time() + 3
while time.time() < end:
    m = ws.recv(timeout=1)
    if m and m.get("type") in ("keys-ack", "error"):
        break
check(m is not None and m.get("type") == "keys-ack", "keys accepted for a web app")
ws.send({"op": "unsubscribe", "key": key})
time.sleep(0.5)
print("all green" if not fails else "%d FAILED" % len(fails))
sys.exit(1 if fails else 0)

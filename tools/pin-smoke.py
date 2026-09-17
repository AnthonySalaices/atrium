#!/usr/bin/env python3
"""End-to-end smoke test for tmux geometry pinning — no headset required.

Drives the real WebSocket against two throwaway tmux sessions:
  * a normal one must shrink to the headset's cols x rows while subscribed,
    carry a restore record on the window, and come back on unsubscribe;
  * an opted-out one (`@glasshouse_pin off`) must keep its desktop size and
    stream a cropped frame instead.

    tools/pin-smoke.py            # against a running glassd on 127.0.0.1:7570

⚠️ It creates and kills its own tmux sessions (`glasshouse-pinsmoke-*`) and
never touches any other session.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, tmux, token          # noqa: E402

NORMAL, OPTOUT = "glasshouse-pinsmoke-a", "glasshouse-pinsmoke-b"
fails = []


def check(ok, what, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(what)


def geometry(s):
    return tmux("display-message", "-p", "-t", s, "#{window_width}x#{window_height}").stdout.strip()


def opt(s, name):
    return tmux("show-options", "-w", "-v", "-t", s, name).stdout.strip()


def make(s):
    tmux("kill-session", "-t", s)
    tmux("new-session", "-d", "-s", s, "-x", "200", "-y", "50")
    tmux("set-option", "-w", "-t", s, "window-size", "manual")
    tmux("resize-window", "-t", s, "-x", "200", "-y", "50")


def main():
    tok = token()
    make(NORMAL)
    make(OPTOUT)
    tmux("set-option", "-w", "-t", OPTOUT, "@glasshouse_pin", "off")
    try:
        ws = WS("/ws?token=" + tok)
        check(ws.wait_for("snapshot") is not None, "snapshot on connect")

        ws.send({"op": "subscribe", "key": NORMAL, "cols": 80, "rows": 28})
        f = ws.wait_for("screen")
        check(f is not None and (f["cols"], f["rows"]) == (80, 28), "normal: frame is 80x28",
              str(f and (f["cols"], f["rows"])))
        time.sleep(0.3)
        check(geometry(NORMAL) == "80x28", "normal: window pinned to 80x28", geometry(NORMAL))
        check(opt(NORMAL, "@glasshouse_prev") == "manual|200|50", "normal: restore record on the window",
              opt(NORMAL, "@glasshouse_prev"))
        check("cropped" not in f, "normal: frame is not a crop")

        ws.send({"op": "subscribe", "key": OPTOUT, "cols": 80, "rows": 28})
        f = ws.wait_for("screen")
        while f and f.get("key") != OPTOUT:
            f = ws.wait_for("screen")
        check(f is not None and (f["cols"], f["rows"]) == (80, 28), "opt-out: frame is 80x28",
              str(f and (f["cols"], f["rows"])))
        check(f is not None and f.get("cropped") == [200, 50], "opt-out: frame is a crop of 200x50",
              str(f and f.get("cropped")))
        check(f is not None and all(len(l["runs"]) and sum(len(r[3]) for r in l["runs"]) == 80
                                    for l in f["lines"]), "opt-out: every cropped row is 80 wide")
        time.sleep(0.3)
        check(geometry(OPTOUT) == "200x50", "opt-out: window untouched", geometry(OPTOUT))
        check(opt(OPTOUT, "@glasshouse_prev") == "", "opt-out: no restore record written")

        ws.send({"op": "unsubscribe", "key": NORMAL})
        time.sleep(0.5)
        check(geometry(NORMAL) == "200x50", "normal: restored on unsubscribe", geometry(NORMAL))
        check(opt(NORMAL, "@glasshouse_prev") == "", "normal: record cleared after restore")
        ws.close()
    finally:
        tmux("kill-session", "-t", NORMAL)
        tmux("kill-session", "-t", OPTOUT)
    print("\n%d failure(s)" % len(fails) if fails else "\nall green")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

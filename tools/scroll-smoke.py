#!/usr/bin/env python3
"""End-to-end smoke test for pointer scrolling — no headset required.

Drives the real WebSocket with `{"op":"scroll"}` against two throwaway tmux
sessions and reads the result back out of tmux:

  1. an app with mouse reporting on (here: `cat -v` after enabling it), which
     must receive the SGR wheel bytes at the pointer's cell, and
  2. a plain shell with scrollback, which must enter copy-mode on scroll-up
     and LEAVE it again when scrolled back to the bottom.

    tools/scroll-smoke.py          # against a running atriumd on 127.0.0.1:7570

⚠️ It creates and kills its own sessions (`atrium-smoke-wheel`, `atrium-smoke-shell`)
and never touches any other session.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, tmux, token          # noqa: E402

WHEEL = "atrium-smoke-wheel"
SHELL = "atrium-smoke-shell"

fails = []


def check(ok, what, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(what)


def fmt(session, f):
    return tmux("display-message", "-p", "-t", session, f).stdout.strip()


def main():
    tok = token()
    for s in (WHEEL, SHELL):
        tmux("kill-session", "-t", s)

    # 1. Mouse-reporting app. The shell prints the enable sequences, then cat -v
    #    shows every byte that arrives afterwards.
    tmux("new-session", "-d", "-s", WHEEL, "-x", "80", "-y", "28",
         "sh -c \"printf '\\033[?1000h\\033[?1006h'; exec cat -v\"")
    # 2. Plain shell with 200 lines of history.
    tmux("new-session", "-d", "-s", SHELL, "-x", "80", "-y", "28", "bash --norc")
    time.sleep(0.5)
    tmux("send-keys", "-t", SHELL, "seq 1 200", "Enter")
    time.sleep(0.5)
    check(fmt(WHEEL, "#{mouse_any_flag}") == "1", "wheel pane reports mouse mode on")
    check(fmt(SHELL, "#{alternate_on} #{pane_in_mode}") == "0 0", "shell pane is normal screen, not in a mode")
    check(int(fmt(SHELL, "#{history_size}")) > 100, "shell pane has scrollback")

    ws = WS("/ws?token=" + tok)
    check(ws.wait_for("snapshot") is not None, "snapshot on connect")

    print("── not subscribed")
    ws.send({"op": "scroll", "key": WHEEL, "lines": 1, "col": 1, "row": 1})
    err = ws.wait_for("error")
    check(err is not None and "not subscribed" in err.get("error", ""),
          "scroll into an unsubscribed pane is refused", str(err))

    for s in (WHEEL, SHELL):
        ws.send({"op": "subscribe", "key": s, "cols": 80, "rows": 28})
        check(ws.wait_for("screen") is not None, "subscribed to " + s)

    print("── wheel delivery")
    ws.send({"op": "scroll", "key": WHEEL, "lines": 2, "col": 12, "row": 7})
    ack = ws.wait_for("scroll-ack")
    check(ack is not None and ack.get("via") == "wheel" and ack.get("sent") == 2,
          "acked as wheel, 2 sent", str(ack))
    time.sleep(0.3)
    text = tmux("capture-pane", "-p", "-t", WHEEL).stdout
    check("^[[<64;12;7M^[[<64;12;7M" in text, "the app received two SGR wheel-up events at (12,7)",
          repr(text[:200]))
    ws.send({"op": "scroll", "key": WHEEL, "lines": -1, "col": 3, "row": 4})
    ws.wait_for("scroll-ack")
    time.sleep(0.3)
    text = tmux("capture-pane", "-p", "-t", WHEEL).stdout
    check("^[[<65;3;4M" in text, "wheel-down is button 65", repr(text[-80:]))

    print("── copy-mode delivery")
    ws.send({"op": "scroll", "key": SHELL, "lines": 5, "col": 1, "row": 1})
    ack = ws.wait_for("scroll-ack")
    check(ack is not None and ack.get("via") == "copy-mode" and ack.get("sent") == 5,
          "acked as copy-mode, 5 sent", str(ack))
    time.sleep(0.3)
    check(fmt(SHELL, "#{pane_in_mode} #{scroll_position}") == "1 5",
          "pane is in copy-mode, scrolled 5 up", fmt(SHELL, "#{pane_in_mode} #{scroll_position}"))
    ws.send({"op": "scroll", "key": SHELL, "lines": 3, "col": 1, "row": 1})
    ws.wait_for("scroll-ack")
    time.sleep(0.3)
    check(fmt(SHELL, "#{scroll_position}") == "8", "another 3 stacks to 8", fmt(SHELL, "#{scroll_position}"))
    ws.send({"op": "scroll", "key": SHELL, "lines": -8, "col": 1, "row": 1})
    ws.wait_for("scroll-ack")
    time.sleep(0.3)
    check(fmt(SHELL, "#{pane_in_mode}") == "0",
          "⭐ scrolling back to the bottom LEAVES copy-mode (the exit design)", fmt(SHELL, "#{pane_in_mode}"))
    ws.send({"op": "scroll", "key": SHELL, "lines": -2, "col": 1, "row": 1})
    ack = ws.wait_for("scroll-ack")
    check(ack is not None and ack.get("sent") == 0 and "bottom" in ack.get("skipped", ""),
          "scroll-down at the bottom sends nothing", str(ack))
    # The pane is live again: typing must land in the shell, not in copy-mode.
    ws.send({"op": "keys", "key": SHELL, "seq": [{"l": "echo back-to-live"}, {"k": "Enter"}]})
    ws.wait_for("keys-ack")
    time.sleep(0.5)
    text = tmux("capture-pane", "-p", "-t", SHELL).stdout
    check(text.count("back-to-live") >= 2, "typing after the scroll reaches the live shell", repr(text[-160:]))

    print("── rejected input")
    ws.send({"op": "scroll", "key": SHELL, "lines": 0, "col": 1, "row": 1})
    err = ws.wait_for("error")
    check(err is not None and "rejected" in err.get("error", ""), "lines=0 is rejected", str(err))

    ws.close()
    for s in (WHEEL, SHELL):
        tmux("kill-session", "-t", s)
    print()
    if fails:
        print("%d FAILED: %s" % (len(fails), ", ".join(fails)))
        sys.exit(1)
    print("all green")


if __name__ == "__main__":
    main()

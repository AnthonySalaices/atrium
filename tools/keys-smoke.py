#!/usr/bin/env python3
"""End-to-end smoke test for M4 typing — no headset required.

Drives the real WebSocket the headset uses: subscribe to a throwaway tmux
session, type into it, and read the result back out of the pane. This is the
test that would have caught a wrong tmux key name, a broken op, or the
not-subscribed guard, all of which are otherwise invisible until someone is
wearing the Quest.

    tools/keys-smoke.py            # against a running glassd on 127.0.0.1:7570

⚠️ It creates and kills its own tmux session (`glasshouse-smoke`) and never
touches any other session.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, tmux, token          # noqa: E402

SESSION = "glasshouse-smoke"

fails = []


def check(ok, what, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(what)


def pane_text():
    return tmux("capture-pane", "-p", "-t", SESSION).stdout


def main():
    tok = token()

    tmux("kill-session", "-t", SESSION)
    # `cat` echoes whatever is typed and interprets nothing, so the pane shows
    # exactly the bytes that arrived.
    tmux("new-session", "-d", "-s", SESSION, "-x", "80", "-y", "28", "cat")
    time.sleep(0.4)
    before = tmux("display-message", "-p", "-t", SESSION,
                  "#{window_width}x#{window_height}").stdout.strip()

    ws = WS("/ws?token=" + tok)
    check(ws.wait_for("snapshot") is not None, "snapshot on connect")

    ws.send({"op": "subscribe", "key": SESSION, "cols": 80, "rows": 28})
    check(ws.wait_for("screen") is not None, "first screen frame")

    print("── typing")
    ws.send({"op": "keys", "key": SESSION, "seq": [{"l": "hello from vr"}], "t": 1234})
    ack = ws.wait_for("keys-ack")
    check(ack is not None and ack.get("n") == 1, "literal text acked",
          "ack=%s" % ack)
    check(ack is not None and ack.get("t") == 1234, "stamp echoed back for latency",
          "ack=%s" % ack)
    time.sleep(0.4)
    check("hello from vr" in pane_text(), "typed text reached the pane",
          repr(pane_text()[:80]))

    print("── named keys")
    ws.send({"op": "keys", "key": SESSION, "seq": [{"k": "Enter"}, {"l": "second"}]})
    check(ws.wait_for("keys-ack") is not None, "named key acked")
    time.sleep(0.4)
    txt = pane_text()
    check("second" in txt, "Enter + text produced a new line", repr(txt[:120]))

    print("── the trap: a name tmux would TYPE instead of refusing")
    ws.send({"op": "keys", "key": SESSION, "seq": [{"k": "S-Tab"}]})
    err = ws.wait_for("error")
    check(err is not None and "reject" in str(err.get("error", "")),
          "S-Tab rejected by the host", "err=%s" % err)
    time.sleep(0.3)
    check("S-Tab" not in pane_text(), "the literal text 'S-Tab' never reached the pane")

    print("── authorisation")
    ws.send({"op": "keys", "key": "some-other-session", "seq": [{"l": "x"}]})
    err = ws.wait_for("error")
    check(err is not None and "not subscribed" in str(err.get("error", "")),
          "keys refused for a session this client does not watch", "err=%s" % err)

    print("── cleanup")
    ws.send({"op": "unsubscribe", "key": SESSION})
    time.sleep(0.5)
    ws.close()
    time.sleep(0.5)
    after = tmux("display-message", "-p", "-t", SESSION,
                 "#{window_width}x#{window_height}").stdout.strip()
    check(after == before, "tmux geometry restored (%s -> %s)" % (before, after))
    tmux("kill-session", "-t", SESSION)

    print()
    if fails:
        print("FAILED: %d of the checks above" % len(fails))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

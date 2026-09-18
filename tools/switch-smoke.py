#!/usr/bin/env python3
"""End-to-end test for switching the focus panel between sessions.

The switcher is what makes the glow actionable — a glow you cannot act on is a
notification with no button. This drives the real WebSocket the headset uses:

  * sessions arrive in STABLE order (by name, never by urgency)
  * the host recommends who has been waiting longest (`focus` in the snapshot)
  * switching unsubscribes the old session, and the host RESTORES its geometry
  * the new session's frames actually arrive

    tools/switch-smoke.py

⚠️ Creates and kills its own tmux sessions (`gh-smoke-a`, `gh-smoke-b`) and never
touches any other session.
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _ws import WS, tmux, token          # noqa: E402

A, B = "gh-smoke-a", "gh-smoke-b"
EMIT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    "atriumd", "glow-emit.sh")

fails = []


def check(ok, what, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(what)


def emit(session, payload):
    """Fire the hook shim as if an agent in `session` had reported something."""
    import subprocess
    pane = tmux("display-message", "-p", "-t", session, "#{pane_id}").stdout.strip()
    env = dict(os.environ, TMUX_PANE=pane)
    subprocess.run([EMIT, "claude-code"], input=payload, text=True, env=env,
                   capture_output=True, timeout=5)


def geometry(session):
    return tmux("display-message", "-p", "-t", session,
                "#{window_width}x#{window_height}").stdout.strip()


def main():
    tok = token()
    for name in (A, B):
        tmux("kill-session", "-t", name)
        tmux("new-session", "-d", "-s", name, "-x", "200", "-y", "50", "cat")
    time.sleep(0.5)
    before_a = geometry(A)

    ws = WS("/ws?token=" + tok)
    snap = ws.wait_for("snapshot")
    check(snap is not None, "snapshot on connect")

    print("── stable order")
    ws.send({"op": "subscribe", "key": A, "cols": 80, "rows": 28})
    check(ws.wait_for("screen") is not None, "streaming %s" % A)
    # Make B the urgent one, then re-read the snapshot.
    emit(B, '{"hook_event_name":"Notification","notification_type":"permission_prompt"}')
    time.sleep(0.6)
    ws.send({"op": "snapshot"})
    snap = ws.wait_for("snapshot")
    keys = [s["key"] for s in snap.get("sessions", [])]
    ours = [k for k in keys if k in (A, B)]
    check(ours == [A, B], "order is alphabetical even though %s is urgent" % B,
          "got %s" % keys)
    check(keys == sorted(keys), "whole list is stably ordered", "got %s" % keys)

    print("── the host says who needs you")
    check(snap.get("focus") == B, "focus recommendation is %s" % B,
          "focus=%r" % snap.get("focus"))
    bstate = next((s for s in snap["sessions"] if s["key"] == B), {})
    check(bstate.get("state") == "needs-input",
          "%s is needs-input via the hook shim" % B, "state=%r" % bstate.get("state"))

    print("── switch to it, the way jump_to_glow does")
    ws.send({"op": "unsubscribe", "key": A})
    ws.send({"op": "subscribe", "key": B, "cols": 80, "rows": 28})
    frame = ws.wait_for("screen")
    check(frame is not None and frame.get("key", B) == B, "frames now come from %s" % B)
    time.sleep(0.8)
    check(geometry(A) == before_a,
          "%s geometry restored on unsubscribe (%s)" % (A, before_a), geometry(A))

    print("── typing goes to the NEW session, and only that one")
    ws.send({"op": "keys", "key": B, "seq": [{"l": "switched"}]})
    check(ws.wait_for("keys-ack") is not None, "keys accepted for %s" % B)
    ws.send({"op": "keys", "key": A, "seq": [{"l": "should not arrive"}]})
    err = ws.wait_for("error")
    check(err is not None and "not subscribed" in str(err.get("error", "")),
          "keys refused for %s now that it is unsubscribed" % A)
    time.sleep(0.4)
    check("switched" in tmux("capture-pane", "-p", "-t", B).stdout,
          "text landed in %s" % B)
    check("should not arrive" not in tmux("capture-pane", "-p", "-t", A).stdout,
          "nothing leaked into %s" % A)

    print("── a killed session stops being offered")
    tmux("kill-session", "-t", A)
    time.sleep(3.0)                       # poll interval + margin
    ws.send({"op": "snapshot"})
    snap = ws.wait_for("snapshot")
    check(all(s["key"] != A for s in snap.get("sessions", [])),
          "%s reaped from the switcher" % A,
          "still listed: %s" % [s["key"] for s in snap.get("sessions", [])])

    ws.send({"op": "unsubscribe", "key": B})
    time.sleep(0.4)
    ws.close()
    tmux("kill-session", "-t", B)

    print()
    if fails:
        print("FAILED: %d of the checks above" % len(fails))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

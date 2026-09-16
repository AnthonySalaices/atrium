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

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time

HOST, PORT = "127.0.0.1", 7570
SESSION = "glasshouse-smoke"
TOKEN_PATH = os.path.expanduser("~/.config/glasshouse/token")
TMUX = "/usr/bin/tmux"

fails = []


def check(ok, what, detail=""):
    print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if detail and not ok else ""))
    if not ok:
        fails.append(what)


class WS:
    """The smallest client that speaks to glassd's hand-rolled WebSocket."""

    def __init__(self, path):
        self.s = socket.create_connection((HOST, PORT), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(
            ("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
             "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
             "Sec-WebSocket-Version: 13\r\n\r\n" % (path, HOST, PORT, key)).encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        head, rest = buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            raise SystemExit("handshake failed: %s" % head.split(b"\r\n")[0])
        self.buf = rest

    def send(self, obj):
        p = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(p)
        h = bytes([0x81])
        if n < 126:
            h += bytes([0x80 | n])
        else:
            h += bytes([0x80 | 126]) + struct.pack(">H", n)
        self.s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))

    def _fill(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            if not d:
                raise EOFError
            self.buf += d

    def recv(self, timeout=5):
        """Next JSON message, or None on timeout."""
        self.s.settimeout(timeout)
        try:
            self._fill(2)
            b1, b2 = self.buf[0], self.buf[1]
            ln = b2 & 0x7F
            off = 2
            if ln == 126:
                self._fill(4)
                ln = struct.unpack(">H", self.buf[2:4])[0]
                off = 4
            elif ln == 127:
                self._fill(10)
                ln = struct.unpack(">Q", self.buf[2:10])[0]
                off = 10
            self._fill(off + ln)
            payload = self.buf[off:off + ln]
            self.buf = self.buf[off + ln:]
            if b1 & 0x0F != 0x1:
                return {}
            return json.loads(payload.decode())
        except (socket.timeout, EOFError):
            return None

    def wait_for(self, kind, timeout=6.0):
        end = time.time() + timeout
        while time.time() < end:
            m = self.recv(timeout=max(0.2, end - time.time()))
            if m and m.get("type") == kind:
                return m
        return None

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def tmux(*args, **kw):
    return subprocess.run([TMUX] + list(args), capture_output=True, text=True, timeout=5, **kw)


def pane_text():
    return tmux("capture-pane", "-p", "-t", SESSION).stdout


def main():
    if not os.path.exists(TOKEN_PATH):
        raise SystemExit("no token at %s — is glassd running?" % TOKEN_PATH)
    token = open(TOKEN_PATH).read().strip()

    tmux("kill-session", "-t", SESSION)
    # `cat` echoes whatever is typed and interprets nothing, so the pane shows
    # exactly the bytes that arrived.
    tmux("new-session", "-d", "-s", SESSION, "-x", "80", "-y", "28", "cat")
    time.sleep(0.4)
    before = tmux("display-message", "-p", "-t", SESSION,
                  "#{window_width}x#{window_height}").stdout.strip()

    ws = WS("/ws?token=" + token)
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

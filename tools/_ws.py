"""Minimal WebSocket client for the smoke tests.

glassd speaks a hand-rolled RFC 6455 subset, so this is a hand-rolled client to
match: enough to connect, send masked text frames and read unmasked ones. Shared
by the smoke tools so the protocol lives in exactly one place.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import time

HOST, PORT = "127.0.0.1", 7570
TOKEN_PATH = os.path.expanduser("~/.config/glasshouse/token")
TMUX = "/usr/bin/tmux"


def token():
    if not os.path.exists(TOKEN_PATH):
        raise SystemExit("no token at %s — is glassd running?" % TOKEN_PATH)
    return open(TOKEN_PATH).read().strip()


def tmux(*args, **kw):
    return subprocess.run([TMUX] + list(args), capture_output=True, text=True,
                          timeout=5, **kw)


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

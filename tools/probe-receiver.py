#!/usr/bin/env python3
"""Write-only probe receiver for the spike APK.

Deliberately NOT part of atriumd. atriumd streams terminal contents and stays on
loopback; this accepts results from the headset and nothing else, so it is the
only thing that ever binds the LAN during a headset window.

    python3 tools/probe-receiver.py           # binds 0.0.0.0:7572
    tail -f logs/probe.jsonl

Accepts POST /api/probe with a JSON body; appends one line per report. GET / is
a liveness check so the headset can confirm it has the right address.
"""

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG = os.path.join(ROOT, "logs", "probe.jsonl")
MAX_BYTES = 8 * 1024 * 1024        # cap; a runaway client must not fill the disk
MAX_BODY = 256 * 1024

# One-slot mailbox so the host can put text on a panel inside the headset.
# Asked for mid-session, from inside the headset: "text me something here if you want
# something from me." It is the first piece of the real product's host->headset
# display path, not just a debugging aid.
_message = {"text": "", "seq": 0}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/say"):
            body = json.dumps(_message).encode()
            return self._reply(200, body, "application/json")
        self._reply(200, b"probe-receiver ok\n")

    def do_POST(self):
        if self.path.startswith("/api/say"):
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return self._reply(400, b"bad length\n")
            raw = self.rfile.read(max(0, min(n, MAX_BODY)))
            _message["text"] = raw.decode("utf-8", "replace")[:600]
            _message["seq"] += 1
            print("[say #%d] %s" % (_message["seq"], _message["text"]), flush=True)
            return self._reply(200, b'{"ok":true}', "application/json")

        if not self.path.startswith("/api/probe"):
            return self._reply(404, b"not found\n")
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400, b"bad length\n")
        if n <= 0 or n > MAX_BODY:
            return self._reply(413, b"body too large\n")

        raw = self.rfile.read(n)
        try:
            payload = json.loads(raw)
        except ValueError:
            return self._reply(400, b"invalid json\n")

        rec = {"t": time.time(), "from": self.client_address[0], "data": payload}
        try:
            if os.path.exists(LOG) and os.path.getsize(LOG) > MAX_BYTES:
                os.replace(LOG, LOG + ".1")
            os.makedirs(os.path.dirname(LOG), exist_ok=True)
            with open(LOG, "a") as f:
                f.write(json.dumps(rec) + "\n")
        except OSError as e:
            return self._reply(500, ("write failed: %s\n" % e).encode())

        kind = payload.get("kind", "?")
        print("[%s] %s from %s (%d bytes)"
              % (time.strftime("%H:%M:%S"), kind, self.client_address[0], n), flush=True)
        return self._reply(200, b'{"ok":true}', "application/json")

    def log_message(self, *_a):
        pass        # our own prints are enough; suppress the default noise


if __name__ == "__main__":
    port = int(os.environ.get("PROBE_PORT", "7572"))
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("probe-receiver on 0.0.0.0:%d -> %s" % (port, LOG), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)

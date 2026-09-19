#!/usr/bin/env python3
"""glowd - XR workspace session-state daemon (stdlib only, Python 3.11).

UDP  :PORT  ingest of agent events (hooks, notify, tmux poller)
TCP  :PORT  clients:  GET /state  -> JSON snapshot
            (the /ws link is bidirectional: {"op":"keys"} types via tmux send-keys)
                      GET /ws     -> RFC6455 WebSocket (Godot WebSocketPeer)
                      GET /events -> SSE (browser debug)
"""
import base64, hashlib, json, os, re, selectors, socket, struct, subprocess, threading, time

PORT = int(os.environ.get("ATRIUM_PORT", "7570"))
BIND = os.environ.get("ATRIUM_BIND", "127.0.0.1")
PROTO = 1
STALE_WORKING_S = 900     # working with no event this long -> unknown
POLL_S = 2.0

STATES = ("idle", "working", "needs-input", "error", "done", "gone")
RANK = {s: i for i, s in enumerate(STATES)}

_lock = threading.RLock()
_sessions = {}            # key -> session dict
_seq = 0
_clients = []             # list of Client


import screen as _screen
import pin as _pin
import keys as _keys
import focus as _focus
import agents as _agents
import pairing as _pairing
import spawn as _spawn
import follow as _follow
import browser as _browsermod

_pair = _pairing.Pairing()

TOKEN_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "atrium", "token")


def load_token():
    """32-hex shared secret, auto-created 0600.

    ⚠️ This service streams the full terminal contents, titles and cwds of every
    agent on the host. It must never be reachable without this token, and must
    never go behind a public proxy. `auth:none` is an explicit opt-out for a
    loopback-only dev loop, nothing else.
    """
    if os.environ.get("ATRIUM_AUTH") == "none":
        return None
    try:
        with open(TOKEN_PATH) as f:
            t = f.read().strip()
            if t:
                return t
    except OSError:
        pass
    import binascii
    t = binascii.hexlify(os.urandom(16)).decode()
    os.makedirs(os.path.dirname(TOKEN_PATH), exist_ok=True)
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(t + "\n")
    return t


TOKEN = load_token()


def authed(path, hdrs):
    if TOKEN is None:
        return True
    q = path.split("?", 1)[1] if "?" in path else ""
    for part in q.split("&"):
        if part.startswith("token="):
            return part[6:] == TOKEN
    auth = hdrs.get("authorization", "")
    return auth == "Bearer " + TOKEN
import config as _config
import files as _files
import settings as _settings

_cfgwatch = None


def cfgwatch():
    global _cfgwatch
    if _cfgwatch is None:
        _cfgwatch = _config.ConfigWatcher()
    return _cfgwatch


def _current_config():
    """The resolved config, or {} before the first successful load."""
    try:
        return cfgwatch().config or {}
    except Exception:
        return {}


def screen_loop():
    """Push screen diffs to subscribed clients.

    Only panes with at least one subscriber are captured — an unwatched session
    costs nothing. ~12 Hz is well under tmux's cost and plenty for a terminal.
    """
    while True:
        try:
            wanted = set()
            for c in list(_clients):
                if c.alive:
                    wanted |= c.subs
            for key in wanted:
                if _browsermod.is_web(key):
                    continue           # frames come from the web sender
                try:
                    msg = mirror_for(key).poll()
                except Exception:
                    continue
                if not msg:
                    continue
                for c in list(_clients):
                    if c.alive and key in c.subs:
                        c.send(c.view(key, msg))
        except Exception:
            pass
        time.sleep(0.08)


def config_poll_loop():
    """Re-evaluate user config when it changes on disk and push it to clients.

    This is what makes editing config.lua restyle the live panels with no
    rebuild — the whole reason the Lua runs on the host and not in the headset.
    """
    while True:
        try:
            w = cfgwatch()
            if w.poll():
                _broadcast(w.frame())
                browser_sync(w.config)
        except Exception:
            pass
        time.sleep(1.0)

_mirrors = {}
_mirrors_lock = threading.Lock()


def pin_excluded(key):
    """Never resize this window: the tmux option (`atrium pin off`) or a
    `sessions.pin_exclude` pattern in config.lua."""
    if _pin.opted_out(key):
        return True
    try:
        cfg = cfgwatch().config or {}
    except Exception:
        return False
    for pat in ((cfg.get("sessions") or {}).get("pin_exclude") or []):
        try:
            if re.search(str(pat), key):
                return True
        except re.error:
            continue
    return False


# ── browser mode ────────────────────────────────────────────────────────────
_browser = None                # browser.Browser, created only once an app is configured
_web_latest = {}               # key -> newest frame not yet sent
_web_cond = threading.Condition()


def _on_web_frame(key, msg):
    """Browser thread: park the newest frame and wake the sender. Never sends
    from here — a slow client must not stall Chromium's event loop."""
    with _web_cond:
        _web_latest[key] = msg
        _web_cond.notify()


def web_send_loop():
    """Send each app's NEWEST frame to its watchers; older ones are dropped, so
    a slow link gets fewer frames instead of a growing backlog."""
    while True:
        with _web_cond:
            while not _web_latest:
                _web_cond.wait()
            batch = dict(_web_latest)
            _web_latest.clear()
        for key, msg in batch.items():
            for c in list(_clients):
                if c.alive and key in c.subs:
                    c.send(msg)


def browser_sync(cfg):
    """Match running web apps to `browser.apps`. Chromium starts only when the
    first app is configured, so a user without any costs nothing."""
    global _browser
    b = (cfg or {}).get("browser") or {}
    apps = b.get("apps", []) if b.get("enabled", True) else []
    if not apps and _browser is None:
        return
    if _browser is None:
        try:
            _browser = _browsermod.Browser(_on_web_frame)
        except Exception as e:
            print("[browser] could not start: %s" % e, flush=True)
            return
    keys = set(_browser.configure(dict(b, apps=apps)))
    with _lock:
        stale = [k for k in _sessions if _browsermod.is_web(k) and k not in keys]
    for k in stale:
        drop(k, "removed-from-config")
    for a in apps:
        upsert(_browsermod.PREFIX + a["name"], source="web", agent="web",
               title=a.get("title") or a["name"], state="idle")
    print("[browser] %d app(s): %s" % (len(keys), ", ".join(sorted(keys)) or "none"), flush=True)


def _follow_mode():
    """sessions.pin_mode: "follow" = the pane takes the size of whoever typed
    last (follow.py); "resize" = force the headset's size (pin.py)."""
    return ((_current_config().get("sessions") or {}).get("pin_mode") == "follow")


def headset_hold(key, cols, rows):
    """Give `key` the headset's geometry, the configured way. Returns True if held."""
    if _follow_mode():
        return _follow.attach(key, cols, rows)
    return _pin.pin(key, cols, rows)


def headset_release(key):
    """Let go of `key` whichever way it is held (both are no-ops when not)."""
    _follow.detach(key)
    _pin.unpin(key)


def mirror_for(key):
    """One PaneMirror per tmux session, created on demand."""
    with _mirrors_lock:
        m = _mirrors.get(key)
        if m is None:
            m = _screen.PaneMirror(key)
            _mirrors[key] = m
        return m


def now(): return time.time()


def _bump():
    global _seq
    _seq += 1
    return _seq


def _blank(key):
    return {"key": key, "agent": "unknown", "session_id": None, "tmux": None,
            "pane": None, "title": key, "cwd": None, "state": "idle",
            "reason": None, "detail": None, "unread": False, "pid": None,
            "last_activity": now(), "state_since": now(), "source": "init",
            "rev": 0}


def upsert(key, **fields):
    """Merge fields into a session; broadcast a delta if anything changed."""
    with _lock:
        s = _sessions.get(key)
        new = s is None
        if new:
            s = _blank(key)
            _sessions[key] = s
        changed = {}
        for k, v in fields.items():
            if v is None and k not in ("reason", "detail"):
                continue
            if s.get(k) != v:
                s[k] = v
                changed[k] = v
        if "state" in changed:
            s["state_since"] = now()
        if changed or new:
            s["last_activity"] = now()
            s["rev"] = _bump()
            _broadcast({"type": "session", "seq": s["rev"], "session": dict(s)})
        return s


def drop(key, reason="ended"):
    with _lock:
        if key in _sessions:
            _sessions.pop(key)
            _broadcast({"type": "removed", "seq": _bump(), "key": key, "reason": reason})


def snapshot():
    """Sessions in STABLE order, plus who is waiting longest.

    Order is by name and never by urgency — see atriumd/focus.py for why moving a
    panel when it becomes urgent is the wrong trade.
    """
    with _lock:
        sessions = [dict(v) for v in _sessions.values()]
    return {"type": "snapshot", "proto": PROTO, "seq": _seq, "now": now(),
            "sessions": _focus.stable_order(sessions),
            "focus": _focus.focus_candidate(sessions)}


# ---------------------------------------------------------------- event mapping
# Claude Code hook_event_name / Codex hook_event_name / notify / tmux poller
CC_MAP = {
    "SessionStart":      ("idle",        None,          False),
    "UserPromptSubmit":  ("working",     None,          False),
    "PreToolUse":        ("working",     None,          False),
    "PostToolUse":       ("working",     None,          False),
    "PostToolUseFailure":("working",     "tool-failed", False),
    "PermissionRequest": ("needs-input", "permission",  True),
    "Elicitation":       ("needs-input", "elicitation", True),
    "Notification":      (None,          None,          True),   # refined by notification_type
    "Stop":              ("idle",        "turn-done",   True),
    "StopFailure":       ("error",       "api-error",   True),
    "SubagentStop":      ("working",     None,          False),
    "SessionEnd":        ("gone",        None,          False),
    "Interrupt":         ("idle",        "interrupted", False),
    # Gemini CLI (and its forks) name the turn boundaries differently.
    "BeforeAgent":       ("working",     None,          False),
    "AfterAgent":        ("idle",        "turn-done",   True),
}
NOTIF_MAP = {
    "permission_prompt":  ("needs-input", "permission"),
    "idle_prompt":        ("needs-input", "idle"),
    "agent_needs_input":  ("needs-input", "agent"),
    "elicitation_dialog": ("needs-input", "elicitation"),
    "agent_completed":    ("done",        "completed"),
}


def handle_event(ev):
    src = ev.get("src", "hook")
    if src == "tmux-poll":
        return handle_poll(ev)

    key = ev.get("key") or ev.get("tmux") or ev.get("session_id")
    if not key:
        return
    hname = ev.get("hook_event_name") or ev.get("type")
    reason = None
    unread = None
    state = None

    if hname == "notify":
        # Tier 1: `atrium notify <session> <state>` from any tool or script.
        # The state is the caller's word for it, validated; nothing is inferred.
        st = str(ev.get("state", ""))
        if st not in STATES:
            return
        state, reason = st, str(ev.get("reason") or "notify")
        unread = st in ("needs-input", "error", "done")
    elif hname == "agent-turn-complete":            # codex `notify` (pre-hooks Codex)
        state, reason, unread = "idle", "turn-done", True
    elif hname in CC_MAP:
        state, reason, unread = CC_MAP[hname]
        if hname == "Notification":
            nt = ev.get("notification_type", "")
            state, reason = NOTIF_MAP.get(nt, ("needs-input", nt or "notification"))
            unread = True

    if hname == "SessionEnd":
        drop(key, "session-end")
        return

    fields = {"agent": ev.get("agent"), "session_id": ev.get("session_id"),
              "tmux": ev.get("tmux"), "pane": ev.get("pane"), "cwd": ev.get("cwd"),
              "pid": ev.get("pid"), "source": hname}
    if state:
        fields["state"] = state
    fields["reason"] = reason
    d = ev.get("last_assistant_message") or ev.get("last-assistant-message") \
        or ev.get("notification_text") or ev.get("tool_name")
    fields["detail"] = (d[:280] if isinstance(d, str) else None)
    if ev.get("title"):
        fields["title"] = ev["title"]
    if unread is True:
        fields["unread"] = True
    elif unread is False and state == "working":
        fields["unread"] = False
    upsert(key, **fields)


def handle_poll(ev):
    """tmux poller: only allowed to move sessions it knows are stale/absent."""
    key = ev["key"]
    with _lock:
        s = _sessions.get(key)
    if s is None:
        upsert(key, agent=ev.get("agent", "unknown"), tmux=ev.get("tmux"),
               pane=ev.get("pane"), pid=ev.get("pid"), title=ev.get("title") or key,
               state=ev.get("state", "idle"), reason="discovered", source="tmux-poll")
        return
    # heartbeat only; never override a hook-set needs-input/error
    if s["state"] in ("needs-input", "error"):
        return
    ps = ev.get("state")
    if ps and ps != s["state"]:
        upsert(key, state=ps, reason="heuristic", source="tmux-poll")
    else:
        upsert(key, pid=ev.get("pid"), title=ev.get("title") or s["title"])


# ---------------------------------------------------------------- transports
def udp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((BIND, PORT))
    while True:
        try:
            data, addr = s.recvfrom(65535)
            ev = json.loads(data.decode("utf-8", "replace"))
            if isinstance(ev, dict) and ev.get("atrium") == "discover":
                # First-run discovery: a headset broadcasts, every daemon on the
                # LAN answers with its name. No secrets in either direction.
                s.sendto(json.dumps({"atrium": "here", "name": socket.gethostname(),
                                     "port": PORT, "proto": PROTO}).encode(), addr)
                continue
            handle_event(ev)
        except Exception:
            pass


class Client:
    def __init__(self, conn, kind):
        self.conn, self.kind, self.alive = conn, kind, True
        # ⚠️ Several threads send to one socket (screen loop, reader, web
        # sender); a 160 KB web frame interleaved with a diff corrupts both.
        self._wlock = threading.Lock()
        self.subs = set()          # tmux session names this client wants pixels for
        self.want = {}             # key -> (cols, rows) the client asked for

    def view(self, key, msg):
        """A screen message as THIS client should see it. A pinned window
        already has the client's geometry; an opted-out one is cropped."""
        if not msg or _pin.is_pinned(key):
            return msg
        cols, rows = self.want.get(key, (0, 0))
        if cols <= 0 or rows <= 0:
            return msg
        return _screen.crop_frame(msg, cols, rows)

    def send(self, obj):
        try:
            payload = json.dumps(obj, separators=(",", ":")).encode()
            with self._wlock:
                if self.kind == "ws":
                    self.conn.sendall(ws_frame(payload))
                else:                       # sse
                    self.conn.sendall(b"data: " + payload + b"\n\n")
        except Exception:
            self.alive = False


def _broadcast(obj):
    dead = []
    for c in list(_clients):
        c.send(obj)
        if not c.alive:
            dead.append(c)
    for c in dead:
        try: _clients.remove(c)
        except ValueError: pass
        try: c.conn.close()
        except Exception: pass


def ws_frame(payload, opcode=0x1):
    n = len(payload)
    h = bytes([0x80 | opcode])
    if n < 126:   h += bytes([n])
    elif n < 1 << 16: h += bytes([126]) + struct.pack(">H", n)
    else:         h += bytes([127]) + struct.pack(">Q", n)
    return h + payload


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def serve_conn(conn):
    conn.settimeout(10)
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk: return
            req += chunk
            if len(req) > 65536: return
        head, body_bytes = req.split(b"\r\n\r\n", 1)
        head = head.decode("latin1")
        lines = head.split("\r\n")
        parts0 = lines[0].split(" ")
        method = parts0[0].upper() if parts0 else "GET"
        path = parts0[1] if len(parts0) > 1 else "/"
        hdrs = {}
        for l in lines[1:]:
            if ":" in l:
                k, v = l.split(":", 1)
                hdrs[k.strip().lower()] = v.strip()

        def reply(status, obj):
            body = json.dumps(obj).encode()
            conn.sendall(("HTTP/1.1 %s\r\nContent-Type: application/json\r\n"
                          "Access-Control-Allow-Origin: *\r\n"
                          "Content-Length: %d\r\n\r\n" % (status, len(body))).encode() + body)

        def read_body():
            n = int(hdrs.get("content-length", "0") or 0)
            n = min(n, 4096)
            b = body_bytes
            while len(b) < n:
                chunk = conn.recv(4096)
                if not chunk: break
                b += chunk
            try:
                return json.loads(b[:n].decode("utf-8", "replace") or "{}")
            except Exception:
                return {}

        # ── pairing ──────────────────────────────────────────────────────
        # /pair is the ONE unauthenticated route: a 6-digit single-use code
        # (issued by `atrium pair`, which IS authenticated) buys the token.
        # Brute force is handled in pairing.py (5 tries, then a 5-minute lock).
        if path.split("?")[0] == "/pair" and method == "POST":
            ok, why = _pair.redeem(str(read_body().get("code", "")))
            if ok:
                reply("200 OK", {"token": TOKEN or "", "port": PORT, "proto": PROTO})
            else:
                reply("429 Too Many Requests" if why == "locked" else "400 Bad Request",
                      {"error": why})
            return

        # ⛔ Everything here exposes terminal contents. No token, no data.
        if not authed(path, hdrs):
            body = b'{"error":"unauthorized"}'
            conn.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\n"
                         + ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
            return

        if path.startswith("/ws") and "websocket" in hdrs.get("upgrade", "").lower():
            acc = base64.b64encode(
                hashlib.sha1((hdrs["sec-websocket-key"] + GUID).encode()).digest()).decode()
            # ⚠️ Godot's WebSocketPeer rejects a handshake with fewer than FOUR
            # response headers ("Not enough response headers. Got: 3, expected
            # >= 4") even though RFC 6455 only requires three. Python/browser
            # clients accept it, so this only shows up on the real device.
            conn.sendall(("HTTP/1.1 101 Switching Protocols\r\n"
                          "Upgrade: websocket\r\n"
                          "Connection: Upgrade\r\n"
                          f"Sec-WebSocket-Accept: {acc}\r\n"
                          "Sec-WebSocket-Version: 13\r\n"
                          "Server: atriumd/0.1\r\n\r\n").encode())
            conn.settimeout(None)
            c = Client(conn, "ws")
            c.send(snapshot())
            try: c.send(cfgwatch().frame())
            except Exception: pass
            _clients.append(c)
            ws_reader(c)
            return

        if path.split("?")[0] == "/pair/new" and method == "POST":
            code, ttl = _pair.new_code()
            reply("200 OK", {"code": code, "ttl": ttl, "bind": BIND, "port": PORT})
            return

        if path.startswith("/events"):
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                         b"Cache-Control: no-cache\r\nConnection: keep-alive\r\n"
                         b"Access-Control-Allow-Origin: *\r\n\r\n")
            conn.settimeout(None)
            c = Client(conn, "sse")
            c.send(snapshot())
            _clients.append(c)
            while c.alive:
                time.sleep(15)
                try: conn.sendall(b": ping\n\n")
                except Exception: c.alive = False
            return

        if path.startswith("/config"):
            try:
                body = json.dumps(cfgwatch().frame()).encode()
            except Exception as e:
                body = json.dumps({"type": "config", "error": str(e)}).encode()
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                         b"Access-Control-Allow-Origin: *\r\n"
                         + ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
            return

        # ── the user's own backdrop ──────────────────────────────────────
        # ⛔ One file, named by the config and never by the request. See files.py.
        if path.split("?")[0] == "/backdrop.glb":
            try:
                cfg = cfgwatch().config or {}
            except Exception:
                cfg = {}
            fp, why = _files.backdrop_path(cfg)
            if fp is None:
                body = json.dumps({"error": why}).encode()
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n"
                             + ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
                return
            tag = _files.etag(fp)
            if hdrs.get("if-none-match", "") == tag:
                # The client already has this exact file cached on the device.
                print("[glb] 304 %s" % os.path.basename(fp), flush=True)
                conn.sendall(b"HTTP/1.1 304 Not Modified\r\nETag: " + tag.encode()
                             + b"\r\nContent-Length: 0\r\n\r\n")
                return
            with open(fp, "rb") as fh:
                data = fh.read()
            print("[glb] 200 %s (%.1f MB)" % (os.path.basename(fp), len(data) / 1048576.0),
                  flush=True)
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: model/gltf-binary\r\n"
                         + b"ETag: " + tag.encode() + b"\r\n"
                         + b"Access-Control-Allow-Origin: *\r\n"
                         + ("Content-Length: %d\r\n\r\n" % len(data)).encode() + data)
            return

        if path.startswith("/screen/"):
            name = path[len("/screen/"):].split("?")[0]
            fmt = "txt"
            if name.endswith(".txt"):
                name, fmt = name[:-4], "txt"
            elif name.endswith(".json"):
                name, fmt = name[:-5], "json"
            try:
                m = mirror_for(name)
                if fmt == "json":
                    msg = m.full()
                    body = json.dumps(msg).encode()
                    ctype = b"application/json"
                else:
                    frame = _screen.capture(name)
                    body = _screen.to_text(frame["grid"]).encode("utf-8")
                    ctype = b"text/plain; charset=utf-8"
            except Exception as e:
                body = ("screen error: %s\n" % e).encode()
                ctype = b"text/plain; charset=utf-8"
                conn.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Type: " + ctype +
                             b"\r\n" + ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
                return
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: " + ctype +
                         b"\r\nAccess-Control-Allow-Origin: *\r\n" +
                         ("Content-Length: %d\r\n\r\n" % len(body)).encode() + body)
            return

        body = json.dumps(snapshot()).encode()
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                     b"Access-Control-Allow-Origin: *\r\n"
                     + f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    except Exception:
        pass
    finally:
        try: conn.close()
        except Exception: pass


def ws_reader(c):
    """Read client frames: ping/pong/close + optional {"op":"snapshot"|"ack"}."""
    conn = c.conn
    try:
        while c.alive:
            hdr = _recvn(conn, 2)
            if not hdr: break
            op = hdr[0] & 0x0F
            masked = hdr[1] & 0x80
            ln = hdr[1] & 0x7F
            if ln == 126: ln = struct.unpack(">H", _recvn(conn, 2))[0]
            elif ln == 127: ln = struct.unpack(">Q", _recvn(conn, 8))[0]
            mask = _recvn(conn, 4) if masked else b""
            data = _recvn(conn, ln) if ln else b""
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if op == 0x8: break
            if op == 0x9:
                conn.sendall(ws_frame(data, 0xA)); continue
            if op == 0x1:
                try: msg = json.loads(data.decode())
                except Exception: continue
                if msg.get("op") == "snapshot":
                    c.send(snapshot())
                elif msg.get("op") == "ack" and msg.get("key"):
                    upsert(msg["key"], unread=False)
                elif msg.get("op") == "subscribe" and _browsermod.is_web(msg.get("key")):
                    key = msg["key"]
                    if _browser is None or key not in _browser.keys():
                        c.send({"type": "error", "key": key, "error": "no such web app"})
                        continue
                    if key not in c.subs:
                        c.subs.add(key)
                        try:
                            first = _browser.watch(key)
                            if first:
                                c.send(first)
                        except Exception as e:
                            c.send({"type": "error", "key": key, "error": "web: %s" % e})
                elif msg.get("op") == "subscribe" and msg.get("key"):
                    key = msg["key"]
                    c.subs.add(key)
                    cols = int(msg.get("cols", 0) or 0)
                    rows = int(msg.get("rows", 0) or 0)
                    c.want[key] = (cols, rows)
                    if cols > 0 and rows > 0:
                        if pin_excluded(key):
                            print("[pin] %s opted out — streaming a %dx%d crop, desktop untouched"
                                  % (key, cols, rows), flush=True)
                        else:
                            headset_hold(key, cols, rows)
                    # A session you are WATCHING must appear in the switcher even
                    # if no agent has reported state for it — otherwise the panel
                    # you are looking at is missing from the list you cycle
                    # through, and next/prev skips straight past it. Guarded by
                    # has-session so a stale key cannot conjure an entry.
                    if tmux_session_exists(key):
                        upsert(key, source="subscribe")
                    try:
                        m = mirror_for(key)
                        full = m.full()
                        if full:
                            c.send(c.view(key, full))
                    except Exception as e:
                        c.send({"type": "error", "key": key, "error": str(e)})
                elif msg.get("op") == "unsubscribe" and _browsermod.is_web(msg.get("key")):
                    if msg["key"] in c.subs:
                        c.subs.discard(msg["key"])
                        if _browser is not None:
                            _browser.unwatch(msg["key"])
                elif msg.get("op") in ("web_pointer", "web_nav") and msg.get("key"):
                    key = msg["key"]
                    if key not in c.subs or _browser is None or not _browsermod.is_web(key):
                        c.send({"type": "error", "key": key, "error": "not subscribed"})
                        continue
                    if msg["op"] == "web_nav":
                        if msg.get("what") == "back":
                            _browser.back(key)
                        elif msg.get("what") == "reload":
                            _browser.reload(key)
                    elif msg.get("kind") == "click":
                        _browser.click(key, msg.get("u", 0.5), msg.get("v", 0.5))
                    else:
                        _browser.move(key, msg.get("u", 0.5), msg.get("v", 0.5))
                elif msg.get("op") == "unsubscribe" and msg.get("key"):
                    c.subs.discard(msg["key"])
                    if not any(msg["key"] in o.subs for o in _clients if o.alive and o is not c):
                        headset_release(msg["key"])
                elif msg.get("op") == "resync" and msg.get("key"):
                    try:
                        full = mirror_for(msg["key"]).full()
                        if full:
                            c.send(c.view(msg["key"], full))
                    except Exception:
                        pass
                elif msg.get("op") == "keys" and msg.get("key"):
                    key = msg["key"]
                    # ⛔ A client may only type into a pane it is already
                    # watching. Without this check any authed client could send
                    # keystrokes to every agent session on the host, including
                    # ones it cannot see.
                    if key not in c.subs:
                        c.send({"type": "error", "key": key,
                                "error": "not subscribed"})
                    else:
                        try:
                            if _browsermod.is_web(key):
                                if _browser is None:
                                    raise _keys.Rejected("browser not running")
                                try:
                                    n = _browser.send_keys(key, msg.get("seq", []))
                                except ValueError as e:
                                    raise _keys.Rejected(str(e))
                            else:
                                _follow.claim(key)      # typing here = headset-sized
                                n = _keys.send(key, msg.get("seq", []))
                            # Typing into a panel is an acknowledgement: you are
                            # looking at it, so stop asking for attention.
                            if n:
                                upsert(key, unread=False)
                            c.send({"type": "keys-ack", "key": key, "n": n,
                                    "t": msg.get("t", 0)})
                        except _keys.Rejected as e:
                            # A rejection is a client bug worth seeing in the
                            # headset, not a reason to drop the connection.
                            print("[keys] rejected for %s: %s" % (key, e), flush=True)
                            c.send({"type": "error", "key": key,
                                    "error": "keys rejected: %s" % e})
                elif msg.get("op") == "scroll" and msg.get("key"):
                    key = msg["key"]
                    # Same rule as typing: only into a pane this client watches.
                    if key not in c.subs:
                        c.send({"type": "error", "key": key,
                                "error": "not subscribed"})
                    else:
                        try:
                            if _browsermod.is_web(key):
                                if _browser is not None:
                                    _browser.wheel(key, msg.get("u", 0.5), msg.get("v", 0.5),
                                                   int(msg.get("lines", 0)))
                                c.send({"type": "scroll-ack", "key": key, "via": "web"})
                                continue
                            _follow.claim(key)
                            r = _keys.scroll(key, msg.get("lines", 0),
                                             msg.get("col", 1), msg.get("row", 1))
                            r.update({"type": "scroll-ack", "key": key})
                            c.send(r)
                        except _keys.Rejected as e:
                            print("[scroll] rejected for %s: %s" % (key, e), flush=True)
                            c.send({"type": "error", "key": key,
                                    "error": "scroll rejected: %s" % e})
                elif msg.get("op") == "new_session":
                    # What runs comes from the HOST's config, never the message.
                    spec = (_current_config().get("sessions") or {}).get("new") or {}
                    if not spec.get("enabled", True):
                        c.send({"type": "error", "error": "new sessions are disabled (sessions.new.enabled)"})
                        continue
                    try:
                        name = _spawn.new_session(spec)
                        print("[spawn] %s started (%s)" % (name, spec.get("command")), flush=True)
                        upsert(name, source="spawn")
                        c.send({"type": "session-created", "key": name})
                    except Exception as e:
                        c.send({"type": "error", "error": "new session failed: %s" % e})
                elif msg.get("op") == "close_session" and msg.get("key"):
                    key = msg["key"]
                    # Same rule as typing: only a pane this client is watching.
                    if key not in c.subs:
                        c.send({"type": "error", "key": key, "error": "not subscribed"})
                        continue
                    if _browsermod.is_web(key):
                        c.send({"type": "error", "key": key,
                                "error": "web apps come from browser.apps in the config"})
                        continue
                    try:
                        c.subs.discard(key)
                        headset_release(key)
                        _spawn.close_session(key)
                        print("[spawn] %s closed from the headset" % key, flush=True)
                        drop(key, "closed")
                        c.send({"type": "session-closed", "key": key})
                    except Exception as e:
                        c.send({"type": "error", "key": key, "error": "close failed: %s" % e})
                elif msg.get("op") in ("set_settings", "reset_settings"):
                    # The ⚙ panel. Only paths the panel schema lists, only the
                    # values it lists; config.lua itself is never written.
                    w = cfgwatch()
                    sp = _settings.path_for(w.user_path)
                    try:
                        if msg["op"] == "set_settings":
                            _settings.update(sp, dict(msg.get("values") or {}))
                        else:
                            keys = msg.get("keys")
                            _settings.reset(sp, None if keys is None else [str(k) for k in keys])
                    except (ValueError, TypeError, OSError) as e:
                        c.send({"type": "error", "error": "settings: %s" % e})
                        continue
                    print("[settings] %s %s" % (msg["op"], msg.get("values") or msg.get("keys")), flush=True)
                    if w.poll():
                        _broadcast(w.frame())
                        browser_sync(w.config)
                elif msg.get("op") == "ping":
                    for k in c.subs:
                        if _browsermod.is_web(k):
                            continue
                        # ⚠️ A ping from a client the watchdog gave up on (the
                        # app was backgrounded > SILENCE_TIMEOUT, then resumed
                        # on the SAME socket) must re-pin, not just keep alive:
                        # otherwise the window stays desktop-wide and the
                        # headset shows a crop that never wraps (9/17).
                        if _pin.is_pinned(k):
                            _pin.keepalive(k)
                            continue
                        if _follow.is_attached(k):
                            continue
                        cols, rows = c.want.get(k, (0, 0))
                        if cols > 0 and rows > 0 and not pin_excluded(k) \
                                and tmux_session_exists(k) and headset_hold(k, cols, rows):
                            print("[pin] %s re-pinned on a live client's ping" % k, flush=True)
                    c.send({"type": "pong", "now": now()})
    except Exception:
        pass
    finally:
        c.alive = False
        try: _clients.remove(c)
        except ValueError: pass
        # ⛔ Never leave someone's window at VR geometry because a client died.
        for k in list(c.subs):
            if _browsermod.is_web(k):
                if _browser is not None:
                    _browser.unwatch(k)
            elif not any(k in o.subs for o in _clients if o.alive):
                headset_release(k)
        try: conn.close()
        except Exception: pass


def _recvn(conn, n):
    b = b""
    while len(b) < n:
        d = conn.recv(n - len(b))
        if not d: return b"" if len(b) < n else b
        b += d
    return b


def tcp_loop():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((BIND, PORT)); s.listen(32)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=serve_conn, args=(conn,), daemon=True).start()


# ---------------------------------------------------------------- tmux poller
TMUX_FMT = ("#{session_name}\t#{pane_id}\t#{pane_current_command}\t#{pane_pid}\t"
            "#{window_activity}\t#{pane_title}")


# ⛔ Provider-agnostic on purpose: the harness table lives in atriumd/agents.py
# and the user can extend it from config.lua (`agents.extra`). Nothing about
# Claude or Codex is special-cased here any more.


def tmux_session_exists(name):
    """⚠️ The `=` prefix forces an EXACT match. Without it tmux matches by
    prefix, so `has-session -t cc` happily succeeds against a session called
    `cc-vr` — and a reaper built on that would never reap anything."""
    try:
        p = subprocess.run(["tmux", "has-session", "-t", "=" + str(name)],
                           capture_output=True, text=True, timeout=5)
    except Exception:
        return True          # can't tell -> never reap on a failed probe
    return p.returncode == 0


def poll_loop():
    while True:
        try:
            out = subprocess.run(["tmux", "list-panes", "-a", "-F", TMUX_FMT],
                                 capture_output=True, text=True, timeout=5).stdout
            cfg = _current_config()
            table = _agents.table(cfg)
            procs = None                      # one `ps` per poll, only if needed
            seen = set()
            for line in out.strip().splitlines():
                p = line.split("\t")
                if len(p) < 6: continue
                sess, pane, cmd, pid, act, title = p[0], p[1], p[2], p[3], p[4], p[5]
                if not _agents.session_allowed(sess, cfg):
                    continue
                if procs is None:
                    procs = _agents.read_procs()
                agent = _agents.find_harness(int(pid), cmd, procs, table)
                if agent is None: continue
                key = sess
                seen.add(key)
                txt = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane, "-S", "-14"],
                                     capture_output=True, text=True, timeout=5).stdout
                st, why = _agents.classify(txt, agent, table)
                handle_poll({"src": "tmux-poll", "key": key, "agent": agent,
                             "tmux": sess, "pane": pane, "pid": int(pid),
                             "title": title or sess, "state": st})
            # ⛔ Reap by asking tmux whether the SESSION still exists, not by
            # absence from `seen`. Two traps here, both of which produced real
            # bugs:
            #  1. `seen` only holds panes whose current command is an agent, and
            #     that command changes to `bash`/`python3` while the agent runs a
            #     tool — so a live session drops out of `seen` constantly.
            #  2. Sessions created by a hook or a keystroke carry no `tmux`
            #     field, so the old `v.get("tmux") and ...` test skipped them
            #     entirely and they lived forever. That would have produced
            #     phantom entries the moment hooks were enabled.
            with _lock:
                known = list(_sessions.keys())
            for k in known:
                if _browsermod.is_web(k):
                    continue           # web apps live and die with browser.apps
                if not tmux_session_exists(k):
                    drop(k, "session-gone")
        except Exception:
            pass
        time.sleep(POLL_S)


def main():
    _pin.install_exit_hooks()
    _pin.recover()
    for fn in (udp_loop, tcp_loop, poll_loop, config_poll_loop, screen_loop,
               _pin.watchdog_loop, web_send_loop):
        threading.Thread(target=fn, daemon=True).start()
    try:
        w = cfgwatch()
        src = w.frame()["source"] or "defaults only"
        print(f"config: rev {w.rev} from {src}", flush=True)
        for n in w.warnings:
            print(f"config warning: {n}", flush=True)
    except Exception as e:
        print(f"config FAILED to load: {e}", flush=True)
    try:
        browser_sync(_current_config())
    except Exception as e:
        print(f"[browser] sync failed: {e}", flush=True)
    if TOKEN is None:
        print("⚠️  AUTH DISABLED (ATRIUM_AUTH=none) — loopback only, never expose this",
              flush=True)
    else:
        print(f"auth: token at {TOKEN_PATH}", flush=True)
    print(f"atriumd listening {BIND}:{PORT} (tcp) + udp/{PORT}", flush=True)
    while True: time.sleep(3600)


if __name__ == "__main__":
    main()

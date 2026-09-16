#!/usr/bin/env python3
"""glowd - XR workspace session-state daemon (stdlib only, Python 3.11).

UDP  :PORT  ingest of agent events (hooks, notify, tmux poller)
TCP  :PORT  clients:  GET /state  -> JSON snapshot
            (the /ws link is bidirectional: {"op":"keys"} types via tmux send-keys)
                      GET /ws     -> RFC6455 WebSocket (Godot WebSocketPeer)
                      GET /events -> SSE (browser debug)
"""
import base64, hashlib, json, os, selectors, socket, struct, subprocess, threading, time

PORT = int(os.environ.get("GLASSHOUSE_PORT", "7570"))
BIND = os.environ.get("GLASSHOUSE_BIND", "127.0.0.1")
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

TOKEN_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "glasshouse", "token")


def load_token():
    """32-hex shared secret, auto-created 0600.

    ⚠️ This service streams the full terminal contents, titles and cwds of every
    agent on the host. It must never be reachable without this token, and must
    never go behind a public proxy. `auth:none` is an explicit opt-out for a
    loopback-only dev loop, nothing else.
    """
    if os.environ.get("GLASSHOUSE_AUTH") == "none":
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

_cfgwatch = None


def cfgwatch():
    global _cfgwatch
    if _cfgwatch is None:
        _cfgwatch = _config.ConfigWatcher()
    return _cfgwatch


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
                try:
                    msg = mirror_for(key).poll()
                except Exception:
                    continue
                if not msg:
                    continue
                for c in list(_clients):
                    if c.alive and key in c.subs:
                        c.send(msg)
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
        except Exception:
            pass
        time.sleep(1.0)

_mirrors = {}
_mirrors_lock = threading.Lock()


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
    with _lock:
        return {"type": "snapshot", "proto": PROTO, "seq": _seq, "now": now(),
                "sessions": [dict(v) for v in _sessions.values()]}


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

    if hname == "agent-turn-complete":              # codex notify
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
            data, _ = s.recvfrom(65535)
            handle_event(json.loads(data.decode("utf-8", "replace")))
        except Exception:
            pass


class Client:
    def __init__(self, conn, kind):
        self.conn, self.kind, self.alive = conn, kind, True
        self.subs = set()          # tmux session names this client wants pixels for

    def send(self, obj):
        try:
            payload = json.dumps(obj, separators=(",", ":")).encode()
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
        head = req.split(b"\r\n\r\n", 1)[0].decode("latin1")
        lines = head.split("\r\n")
        path = lines[0].split(" ")[1] if " " in lines[0] else "/"
        hdrs = {}
        for l in lines[1:]:
            if ":" in l:
                k, v = l.split(":", 1)
                hdrs[k.strip().lower()] = v.strip()

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
                          "Server: glassd/0.1\r\n\r\n").encode())
            conn.settimeout(None)
            c = Client(conn, "ws")
            c.send(snapshot())
            try: c.send(cfgwatch().frame())
            except Exception: pass
            _clients.append(c)
            ws_reader(c)
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
                elif msg.get("op") == "subscribe" and msg.get("key"):
                    key = msg["key"]
                    c.subs.add(key)
                    cols = int(msg.get("cols", 0) or 0)
                    rows = int(msg.get("rows", 0) or 0)
                    if cols > 0 and rows > 0:
                        _pin.pin(key, cols, rows)
                    try:
                        m = mirror_for(key)
                        full = m.full()
                        if full:
                            c.send(full)
                    except Exception as e:
                        c.send({"type": "error", "key": key, "error": str(e)})
                elif msg.get("op") == "unsubscribe" and msg.get("key"):
                    c.subs.discard(msg["key"])
                    if not any(msg["key"] in o.subs for o in _clients if o.alive and o is not c):
                        _pin.unpin(msg["key"])
                elif msg.get("op") == "resync" and msg.get("key"):
                    try:
                        full = mirror_for(msg["key"]).full()
                        if full:
                            c.send(full)
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
                elif msg.get("op") == "ping":
                    for k in c.subs:
                        _pin.keepalive(k)
                    c.send({"type": "pong", "now": now()})
    except Exception:
        pass
    finally:
        c.alive = False
        try: _clients.remove(c)
        except ValueError: pass
        # ⛔ Never leave someone's window at VR geometry because a client died.
        for k in list(c.subs):
            if not any(k in o.subs for o in _clients if o.alive):
                _pin.unpin(k)
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


def classify(pane_text, cmd):
    tail = "\n".join(pane_text.splitlines()[-12:])
    if "Do you want to" in tail or "Would you like to proceed" in tail:
        return "needs-input", "prompt-scrape"
    if "esc to interrupt" in tail:
        return "working", "prompt-scrape"
    return "idle", "prompt-scrape"


def poll_loop():
    while True:
        try:
            out = subprocess.run(["tmux", "list-panes", "-a", "-F", TMUX_FMT],
                                 capture_output=True, text=True, timeout=5).stdout
            seen = set()
            for line in out.strip().splitlines():
                p = line.split("\t")
                if len(p) < 6: continue
                sess, pane, cmd, pid, act, title = p[0], p[1], p[2], p[3], p[4], p[5]
                agent = {"claude": "claude-code", "codex": "codex"}.get(cmd)
                if agent is None: continue
                key = sess
                seen.add(key)
                txt = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane, "-S", "-14"],
                                     capture_output=True, text=True, timeout=5).stdout
                st, why = classify(txt, cmd)
                handle_poll({"src": "tmux-poll", "key": key, "agent": agent,
                             "tmux": sess, "pane": pane, "pid": int(pid),
                             "title": title or sess, "state": st})
            with _lock:
                gone = [k for k, v in _sessions.items() if v.get("tmux") and k not in seen]
            for k in gone:
                drop(k, "pane-gone")
        except Exception:
            pass
        time.sleep(POLL_S)


def main():
    for fn in (udp_loop, tcp_loop, poll_loop, config_poll_loop, screen_loop,
               _pin.watchdog_loop):
        threading.Thread(target=fn, daemon=True).start()
    try:
        w = cfgwatch()
        src = w.frame()["source"] or "defaults only"
        print(f"config: rev {w.rev} from {src}", flush=True)
        for n in w.warnings:
            print(f"config warning: {n}", flush=True)
    except Exception as e:
        print(f"config FAILED to load: {e}", flush=True)
    if TOKEN is None:
        print("⚠️  AUTH DISABLED (GLASSHOUSE_AUTH=none) — loopback only, never expose this",
              flush=True)
    else:
        print(f"auth: token at {TOKEN_PATH}", flush=True)
    print(f"glassd listening {BIND}:{PORT} (tcp) + udp/{PORT}", flush=True)
    while True: time.sleep(3600)


if __name__ == "__main__":
    main()

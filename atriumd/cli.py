"""atrium — the host-side command.

    atrium notify <session|auto> <state> [--reason R] [--detail D]
        Tier-1 integration: tell the daemon what an agent is doing, from ANY
        tool, hook system or script. `auto` = the tmux session this shell is in.
        States: idle, working, needs-input, error, done, gone.

    atrium hooks status|install|uninstall [harness|all] [--dry-run] [--path FILE]
        Tier-2 integration: install the harness's own hook entries so the glow is
        exact. Backs up, merges, re-parses, idempotent.

    atrium init [--yes] [--no-hooks] [--autostart|--no-autostart] [--dry-run]
        First-time setup on this computer: checks, finds your agent harnesses,
        offers their hooks, writes the config and token, starts the daemon on
        the LAN, optionally registers it to start at login, prints the pairing
        card. Safe to re-run; every step skips what is already done.

    atrium start <harness> [dir] [--name NAME]
        Start an agent in a new named tmux session and attach to it. The one
        command a non-tmux user ever needs; Atrium finds the session by
        what is running in it.

    atrium config
        Open your config.lua in $EDITOR (created from the starter if missing).

    atrium pair
        Print a one-time 6-digit code (valid 10 minutes) to type into the
        headset's pairing card. The APK ships with no secret; this is how it
        gets the token.

    atrium doctor
        What is installed, what is hooked, whether the daemon answers.

    atrium up | daemon [--lan]
        Start the daemon detached (up) or in the foreground (daemon). A
        checkout can also use ./start.sh --lan.

Nothing here needs sudo, a model, or an API key.
"""

import argparse
import json
import os
import socket
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))       # atriumd/
ROOT = os.path.dirname(HERE)                               # the checkout, if any
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import agents  # noqa: E402
import hooks   # noqa: E402

HOST = os.environ.get("ATRIUM_HOST", "127.0.0.1")
PORT = int(os.environ.get("ATRIUM_PORT", "7570"))
STATES = ("idle", "working", "needs-input", "error", "done", "gone")


def tmux_session(pane=None):
    pane = pane or os.environ.get("TMUX_PANE")
    if not pane:
        return None
    try:
        out = subprocess.run(["tmux", "display-message", "-p", "-t", pane, "#{session_name}"],
                             capture_output=True, text=True, timeout=3).stdout.strip()
        return out or None
    except Exception:
        return None


def cmd_notify(a):
    key = tmux_session() if a.session == "auto" else a.session
    if not key:
        sys.exit("atrium notify: not inside tmux and no session given")
    if a.state not in STATES:
        sys.exit("atrium notify: state must be one of %s" % ", ".join(STATES))
    msg = {"src": "hook", "type": "notify", "key": key, "state": a.state,
           "agent": a.agent or "notify", "pane": os.environ.get("TMUX_PANE")}
    if a.reason:
        msg["reason"] = a.reason
    if a.detail:
        msg["notification_text"] = a.detail[:280]
    if a.title:
        msg["title"] = a.title
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(json.dumps(msg).encode(), (HOST, PORT))
    return 0


def _print(res):
    line = "  %-12s %-11s %s" % (res.harness, res.status, res.path or "")
    if res.changes:
        line += "  (" + ", ".join(res.changes) + ")"
    if res.note:
        line += "\n" + " " * 15 + res.note
    print(line)


def cmd_hooks(a):
    targets = list(hooks.INSTALLERS) if a.harness in (None, "all") else [a.harness]
    if a.action == "status":
        for r in hooks.statuses(targets):
            _print(r)
        return 0
    rc = 0
    for h in targets:
        inst = hooks.installer(h, a.path if len(targets) == 1 else None)
        if inst is None:
            _print(hooks.Result(h, "", "unsupported", note="no hooks system known; tier 3 only"))
            continue
        r = inst.apply(uninstall=(a.action == "uninstall"), dry_run=a.dry_run)
        if a.dry_run and r.changes:
            r.note = "--dry-run: nothing written"
        if not r.changes and r.status != "invalid":
            r.note = "nothing to do"
        _print(r)
        if r.status == "invalid":
            rc = 1
    return rc


def _lan_addresses():
    """Every non-loopback IPv4 this host has, best guess first."""
    addrs = []
    primary = None
    try:
        # The address the default route uses is almost always the LAN one.
        out = subprocess.run(["ip", "-4", "route", "get", "1.1.1.1"], capture_output=True,
                             text=True, timeout=3).stdout.split()
        if "src" in out:
            primary = out[out.index("src") + 1]
    except Exception:
        pass
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True,
                             timeout=3).stdout
        for line in out.splitlines():
            parts = line.split()
            if "inet" not in parts or len(parts) < 2:
                continue
            iface = parts[1]
            # Container bridges and tunnels are real addresses a headset can
            # never use; on a box with a few Docker stacks they are dozens.
            if iface.startswith(("docker", "br-", "veth", "virbr", "tailscale", "lo", "tun", "wg")):
                continue
            ip = parts[parts.index("inet") + 1].split("/")[0]
            if not ip.startswith("127."):
                addrs.append(ip)
    except Exception:
        pass
    if primary:
        addrs = [primary] + [a for a in addrs if a != primary]
    if not addrs:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("10.255.255.255", 1))
            addrs.append(s.getsockname()[0])
        except Exception:
            pass
    # Tailscale-style 100.x addresses are real but rarely what a headset on the
    # LAN wants; put private ranges first.
    addrs.sort(key=lambda a: 0 if a.startswith(("192.168.", "10.", "172.")) else 1)
    return addrs


def _token():
    p = os.environ.get("ATRIUM_TOKEN_FILE") or os.path.join(CONFIG_DIR, "token")
    try:
        with open(p) as f:
            return f.read().strip()
    except OSError:
        return ""


def cmd_pair(a):
    """Ask the daemon for a fresh pairing code and print the card."""
    import http.client
    tok = _token()
    if not tok:
        sys.exit("atrium pair: no token file yet — start the daemon once (./start.sh --lan)")
    try:
        c = http.client.HTTPConnection(HOST, PORT, timeout=3)
        c.request("POST", "/pair/new", body="{}",
                  headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
        r = c.getresponse()
        v = json.loads(r.read().decode() or "{}")
    except Exception as e:
        sys.exit("atrium pair: daemon not reachable on %s:%d (%s) — run ./start.sh --lan" % (HOST, PORT, e))
    if r.status != 200 or "code" not in v:
        sys.exit("atrium pair: daemon refused (%s %s)" % (r.status, v))
    code = v["code"]
    mins = int(v.get("ttl", 600)) // 60
    addrs = _lan_addresses()
    lan = v.get("bind") not in (None, "127.0.0.1", "localhost")
    print()
    print("  ┌──────────────────────────────────────────┐")
    print("  │  Atrium pairing                       │")
    print("  │                                          │")
    print("  │  code   %s   %s                        │" % (code[:3], code[3:]))
    print("  │  host   %-33s│" % ((addrs[0] + ":" + str(PORT)) if addrs else "(no LAN address found)"))
    print("  │                                          │")
    print("  │  Put the headset on, open Atrium and  │")
    print("  │  enter the code. Valid %2d minutes, once.  │" % mins)
    print("  └──────────────────────────────────────────┘")
    if len(addrs) > 1:
        print("  other addresses: " + ", ".join(addrs[1:]))
    if not lan:
        print("  ⚠️  the daemon is bound to loopback — the headset cannot reach it. Restart with ./start.sh --lan")
    print()
    return 0


CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "atrium")
USER_CONFIG = os.path.join(CONFIG_DIR, "config.lua")
STARTER = os.path.join(HERE, "config", "starter.lua") if os.path.exists(os.path.join(HERE, "config", "starter.lua")) \
    else os.path.join(ROOT, "config", "starter.lua")
START_SH = os.path.join(ROOT, "start.sh")                  # checkout only
LOG_PATH = os.path.join(CONFIG_DIR, "atriumd.log")


def _ok(msg): print("  ✓ " + msg)
def _warn(msg): print("  ! " + msg)
def _step(msg): print("\n" + msg)


def _ask(q, default_yes=True, auto=None):
    if auto is not None:
        return auto
    try:
        r = input("  %s [%s] " % (q, "Y/n" if default_yes else "y/N")).strip().lower()
    except EOFError:
        return default_yes
    if r == "":
        return default_yes
    return r.startswith("y")


def _version_ok(text, want):
    import re
    m = re.search(r"(\d+)\.(\d+)", text or "")
    if not m:
        return False
    return (int(m.group(1)), int(m.group(2))) >= want


def ensure_config():
    """Write the starter config once; never overwrite the user's file."""
    if os.path.exists(USER_CONFIG):
        return False
    os.makedirs(CONFIG_DIR, exist_ok=True)
    import shutil
    shutil.copy(STARTER, USER_CONFIG)
    return True


def daemon_up():
    try:
        with socket.create_connection((HOST, PORT), timeout=1):
            return True
    except OSError:
        return False


def start_daemon(lan=True):
    """Start atriumd detached. A checkout has start.sh (port-guarded, logs under
    the repo); an installed package runs `atrium daemon` under nohup."""
    if daemon_up():
        return "daemon already listening on %d" % PORT
    if os.path.exists(START_SH):
        r = subprocess.run([START_SH] + (["--lan"] if lan else []), capture_output=True, text=True)
        return (r.stdout.strip() or r.stderr.strip())
    os.makedirs(CONFIG_DIR, exist_ok=True)
    env = dict(os.environ, ATRIUM_BIND="0.0.0.0" if lan else "127.0.0.1")
    with open(LOG_PATH, "ab") as log:
        subprocess.Popen([sys.executable, "-m", "atriumd.cli", "daemon"] + (["--lan"] if lan else []),
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True, env=env)
    import time
    for _ in range(20):
        if daemon_up():
            return "atriumd started on %s:%d" % ("0.0.0.0" if lan else "127.0.0.1", PORT)
        time.sleep(0.25)
    return "atriumd did not answer — see " + LOG_PATH


def cmd_daemon(a):
    """Run the daemon in the foreground (what autostart and start_daemon use)."""
    if a.lan:
        os.environ["ATRIUM_BIND"] = "0.0.0.0"
    # ⚠️ `import atriumd` here would give the PACKAGE (this directory), not the
    # daemon module atriumd/atriumd.py that shares its name. Load the file itself.
    import importlib.util
    spec = importlib.util.spec_from_file_location("atriumd_daemon", os.path.join(HERE, "atriumd.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.main()


def _autostart_installed():
    try:
        out = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return False
    return "# atrium" in out


def install_autostart(dry_run=False):
    """Start at login without sudo: a systemd user unit where the bus exists,
    otherwise cron (@reboot + a 5-minute keeper; start.sh is idempotent)."""
    unit_dir = os.path.expanduser("~/.config/systemd/user")
    have_user_bus = subprocess.run(["systemctl", "--user", "is-system-running"],
                                   capture_output=True, text=True).returncode in (0, 1) and \
        "No medium" not in subprocess.run(["systemctl", "--user", "is-system-running"],
                                          capture_output=True, text=True).stderr
    if have_user_bus:
        unit = os.path.join(unit_dir, "atrium.service")
        text = ("[Unit]\nDescription=Atrium daemon\nAfter=network-online.target\n\n"
                "[Service]\nExecStart=%s -m atriumd.cli daemon --lan\nRestart=on-failure\n\n"
                "[Install]\nWantedBy=default.target\n" % sys.executable)
        if dry_run:
            return "would write %s and enable it" % unit
        os.makedirs(unit_dir, exist_ok=True)
        with open(unit, "w") as f:
            f.write(text)
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", "atrium.service"], capture_output=True)
        return "systemd user unit %s enabled" % unit
    if _autostart_installed():
        return "cron entries already present"
    starter = ("%s --lan" % START_SH) if os.path.exists(START_SH) else \
        ("%s -m atriumd.cli up" % sys.executable)
    lines = ["@reboot sleep 20 && %s # atrium" % starter,
             "*/5 * * * * %s >/dev/null 2>&1 # atrium keeper" % starter]
    if dry_run:
        return "would add to crontab: " + " | ".join(lines)
    cur = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    new = cur.rstrip("\n") + ("\n" if cur.strip() else "") + "\n".join(lines) + "\n"
    subprocess.run(["crontab", "-"], input=new, text=True, check=True)
    return "cron: @reboot + 5-minute keeper added"


def cmd_init(a):
    auto = True if a.yes else None
    print("Atrium setup — every step skips what is already done.")

    _step("1. Checks")
    tm = subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout if _which("tmux") else ""
    if _version_ok(tm, (3, 2)):
        _ok(tm.strip())
    else:
        _warn("tmux 3.2+ is required (found: %s). Install it: apt install tmux / brew install tmux"
              % (tm.strip() or "none"))
        return 1
    if sys.version_info >= (3, 9):
        _ok("python %d.%d" % sys.version_info[:2])
    else:
        _warn("python 3.9+ is required"); return 1
    import config as _config
    ev = _config.evaluator()
    build_sh = os.path.join(ROOT, "tools", "build-lua.sh")
    if ev is not None:
        _ok("config evaluator: %s" % ("lupa" if ev[0] == sys.executable else "vendored lua"))
    elif a.dry_run:
        _warn("no config evaluator — would `pip install lupa`%s" % (" or run tools/build-lua.sh" if os.path.exists(build_sh) else ""))
    else:
        _warn("no config evaluator — installing lupa")
        r = subprocess.run([sys.executable, "-m", "pip", "install", "-q", "lupa"], capture_output=True, text=True)
        if _config.evaluator() is None and os.path.exists(build_sh):
            _warn("pip failed; building the vendored interpreter (needs make + a C compiler)")
            subprocess.run([build_sh], capture_output=True, text=True)
        if _config.evaluator() is None:
            _warn("still no evaluator: `pip install lupa` by hand, then re-run"); return 1
        _ok("ready")

    _step("2. Agent harnesses on this computer")
    found = agents.installed()
    if not found:
        _warn("none found on $PATH. Install one (claude, codex, gemini, aider, opencode…) and re-run;")
        _warn("Atrium still shows any of them the moment they run inside tmux.")
    for h, path in sorted(found.items()):
        tier = "exact (hooks available)" if h in hooks.INSTALLERS else "heuristic (no hooks system)"
        _ok("%-12s %s — %s" % (h, path, tier))

    _step("3. Hooks — let each harness report its own state")
    if a.no_hooks:
        print("  skipped (--no-hooks)")
    else:
        for h in sorted(found):
            inst = hooks.installer(h)
            if inst is None:
                continue
            st = inst.status()
            if st.status == "installed":
                _ok("%s already hooked" % h); continue
            if st.status == "invalid":
                _warn("%s: %s is not valid JSON — fix it, then `atrium hooks install %s`" % (h, st.path, h)); continue
            if _ask("Install hooks for %s (%s)?" % (h, st.path), True, auto):
                r = inst.apply(dry_run=a.dry_run)
                _ok("%s: %s%s" % (h, ", ".join(r.changes) or "nothing to do",
                                  " (dry run)" if a.dry_run else ""))
                if h == "codex" and inst.feature_enabled() is False:
                    _warn("Codex loads hooks only with `[features] hooks = true` in ~/.codex/config.toml")

    _step("4. Config and token")
    if a.dry_run:
        _ok("%s %s" % (USER_CONFIG, "exists" if os.path.exists(USER_CONFIG) else "would be created from the starter"))
    elif ensure_config():
        _ok("wrote %s (all defaults, commented) — `atrium config` opens it" % USER_CONFIG)
    else:
        _ok("%s exists, left alone" % USER_CONFIG)

    _step("5. Daemon")
    if daemon_up():
        _ok("already running on port %d" % PORT)
    elif a.dry_run:
        _ok("would start the daemon on the LAN")
    else:
        print("  " + start_daemon(lan=True))
        if not daemon_up():
            _warn("daemon did not come up — see %s" % LOG_PATH); return 1
    tokpath = os.path.join(CONFIG_DIR, "token")
    _ok("token at %s" % tokpath) if os.path.exists(tokpath) else _warn("no token yet")

    _step("6. Start at login")
    want = a.autostart if a.autostart is not None else \
        _ask("Start the daemon automatically at login (no sudo needed)?", True, auto)
    if want:
        _ok(install_autostart(dry_run=a.dry_run))
    else:
        print("  skipped — run `%s --lan` when you want it" % START_SH)

    _step("7. Pair the headset")
    if a.dry_run or not daemon_up():
        print("  (run `atrium pair` when the daemon is up)")
    else:
        cmd_pair(a)
    print("Next: open Atrium in the headset and enter the code. Then `atrium start claude` "
          "(or any harness) on this computer.")
    return 0


def _which(name):
    from shutil import which
    return which(name)


def cmd_start(a):
    t = agents.table()
    row = t.get(a.harness)
    if row is None:
        # Allow a raw command too: `atrium start ./my-agent.sh`
        if _which(a.harness) or os.path.exists(a.harness):
            row = {"match": [a.harness]}
        else:
            sys.exit("atrium start: unknown harness %r — one of: %s" % (a.harness, ", ".join(sorted(t))))
    exe = next((m for m in row["match"] if _which(m)), None)
    if exe is None:
        sys.exit("atrium start: %s is not on $PATH" % " / ".join(row["match"]))
    d = os.path.abspath(os.path.expanduser(a.dir or "."))
    base = os.path.basename(d.rstrip("/")) or "home"
    name = a.name or ("%s-%s" % (a.harness if a.harness in t else base, base) if a.harness in t else base)
    # tmux forbids '.' and ':' in session names
    name = name.replace(".", "-").replace(":", "-")
    existing = subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"],
                              capture_output=True, text=True).stdout.split()
    n, cand = 2, name
    while cand in existing:
        cand = "%s-%d" % (name, n); n += 1
    name = cand
    cmd = [exe] + list(getattr(a, "args", []) or [])
    r = subprocess.run(["tmux", "new-session", "-d", "-s", name, "-c", d] + cmd,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("atrium start: tmux failed: " + (r.stderr.strip() or r.stdout.strip()))
    print("started %s in %s (tmux session %r)" % (" ".join(cmd), d, name))
    if a.detach:
        return 0
    if os.environ.get("TMUX"):
        os.execvp("tmux", ["tmux", "switch-client", "-t", name])
    os.execvp("tmux", ["tmux", "attach-session", "-t", name])


def cmd_config(a):
    if ensure_config():
        print("created %s" % USER_CONFIG)
    editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "vi"
    os.execvp(editor, [editor, USER_CONFIG])


def _tmux(*args):
    try:
        p = subprocess.run(["tmux"] + list(args), capture_output=True, text=True, timeout=5)
    except Exception:
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def cmd_pin(a):
    """Per-session opt-out of headset geometry.

    The headset asks the daemon to resize a watched tmux window to its own
    cols x rows, and tmux windows have ONE size shared by every attached
    client — so the same window shrinks on your desktop. `pin off` marks the
    window so it is never resized; the headset gets a crop of it instead."""
    import pin as _pin
    if a.action == "status":
        names = _tmux("list-sessions", "-F", "#{session_name}") or ""
        if not names:
            print("no tmux sessions")
            return 0
        print("%-20s %-9s %-8s %-6s %s" % ("session", "size", "window-size", "pin", "restore record"))
        for k in names.split("\n"):
            geo = _tmux("display-message", "-p", "-t", k, "#{window_width}x#{window_height}") or "?"
            ws = _tmux("show-options", "-w", "-v", "-t", k, "window-size") or "(unset)"
            state = "off" if _pin.opted_out(k) else "on"
            rec = _tmux("show-options", "-w", "-v", "-t", k, _pin.PREV_OPT) or "-"
            print("%-20s %-9s %-11s %-6s %s" % (k, geo, ws, state, rec))
        return 0
    key = a.session
    if not key:
        if not os.environ.get("TMUX"):
            print("not inside tmux — name the session: atrium pin %s <session>" % a.action,
                  file=sys.stderr)
            return 2
        key = _tmux("display-message", "-p", "#S")
        if not key:
            print("could not read the current tmux session", file=sys.stderr)
            return 2
    if _tmux("has-session", "-t", key) is None:
        print("no tmux session named %r" % key, file=sys.stderr)
        return 2
    if a.action == "off":
        if _tmux("set-option", "-w", "-t", key, _pin.PIN_OPT, "off") is None:
            print("tmux refused to set %s on %s" % (_pin.PIN_OPT, key), file=sys.stderr)
            return 1
        # If it is pinned right now, put it back immediately.
        rec = _tmux("show-options", "-w", "-v", "-t", key, _pin.PREV_OPT)
        if rec and "|" in rec:
            size, cols, rows = rec.split("|")[:3]
            _tmux("resize-window", "-t", key, "-x", cols, "-y", rows)
            if size == "-":
                _tmux("set-option", "-w", "-u", "-t", key, "window-size")
            else:
                _tmux("set-option", "-w", "-t", key, "window-size", size)
            _tmux("set-option", "-w", "-u", "-t", key, _pin.PREV_OPT)
            print("%s: restored to %sx%s" % (key, cols, rows))
        print("%s: the headset will never resize this session (shows a crop instead)" % key)
        print("   undo with: atrium pin on %s" % key)
    else:
        _tmux("set-option", "-w", "-u", "-t", key, _pin.PIN_OPT)
        print("%s: the headset may resize this session while watching it" % key)
    return 0


PRESETS = {
    "cafe": "the shipped coffee shop, baked lighting and slow loops",
    "nebula": "the procedural sky that shipped first",
    "void": "flat dark, nothing to look at",
    "passthrough": "your real room, through the headset's cameras",
}


def _backdrop_dir():
    return os.path.join(CONFIG_DIR, "backdrops")


def _read_config_text():
    ensure_config()
    with open(USER_CONFIG) as f:
        return f.read()


def _write_config_text(text):
    """Write the config back, keeping a single .bak of what was there before.

    ⚠️ This is the user's hand-edited file. One backup, overwritten each time,
    is the difference between "undo my mistake" and "clean up 40 .bak files".
    """
    import shutil
    if os.path.exists(USER_CONFIG):
        shutil.copy(USER_CONFIG, USER_CONFIG + ".bak")
    with open(USER_CONFIG, "w") as f:
        f.write(text)


def _current_backdrop():
    """(mode, preset) as the daemon would resolve them, or (None, None)."""
    try:
        import config as _config
        cfg, _ = _config.evaluate(USER_CONFIG if os.path.exists(USER_CONFIG) else "")
        _config.validate(cfg)
        bd = cfg.get("backdrop") or {}
        return str(bd.get("mode", "")), str((bd.get("default") or {}).get("preset", ""))
    except Exception:
        return None, None


def cmd_preset(a):
    """Pick what is behind the windows, without opening an editor."""
    import confedit
    mode, preset = _current_backdrop()
    if a.action == "list":
        live = preset if mode == "default" else mode
        for name, what in PRESETS.items():
            print("%s %-12s %s" % ("*" if name == live else " ", name, what))
        if mode == "custom":
            print("* %-12s %s" % ("custom", "your own .glb — see `atrium pack`"))
        print("\nin use: %s   (%s)" % (live or "?", USER_CONFIG))
        return 0

    name = a.name
    if name not in PRESETS:
        print("unknown preset %r — try: %s" % (name, ", ".join(PRESETS)), file=sys.stderr)
        return 2
    text = _read_config_text()
    try:
        if name == "passthrough":
            text = confedit.set_backdrop(text, "passthrough")
        else:
            text = confedit.set_backdrop(text, "default", preset=name)
    except ValueError as e:
        print("could not edit %s: %s" % (USER_CONFIG, e), file=sys.stderr)
        return 1
    _write_config_text(text)
    print("%s: backdrop -> %s" % (USER_CONFIG, name))
    print("   the headset restyles live on save; no rebuild, no reinstall")
    return 0


def cmd_pack(a):
    """Put a .glb where the daemon can serve it, and point the config at it.

    ⛔ The file is COPIED into the config directory rather than referenced where
    it sits. A backdrop that disappears when you tidy your Downloads folder is a
    room that vanishes mid-session, and the daemon would be serving a path it
    does not own.
    """
    import confedit
    src = os.path.expanduser(a.glb)
    if not os.path.isfile(src):
        print("no such file: %s" % src, file=sys.stderr)
        return 2
    if not src.lower().endswith(".glb"):
        print("backdrops must be .glb (self-contained glTF) — %s is not" % src,
              file=sys.stderr)
        print("   a .gltf with sidecar textures needs its whole folder; export as .glb",
              file=sys.stderr)
        return 2
    name = a.name or os.path.splitext(os.path.basename(src))[0]
    dest_dir = _backdrop_dir()
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, name + ".glb")
    import shutil
    shutil.copy(src, dest)
    size = os.path.getsize(dest) / 1048576.0
    text = confedit.set_backdrop(_read_config_text(), "custom", glb=dest)
    _write_config_text(text)
    print("packed %s (%.1f MB) -> %s" % (os.path.basename(src), size, dest))
    print("%s: backdrop -> custom" % USER_CONFIG)
    if size > 40:
        print("\n⚠\ufe0f  %.0f MB goes over the headset's Wi-Fi once, then it is cached on the"
              % size)
        print("   device. The first load after a change will take a moment.")
    print("\nThe room needs a clear cylinder ~2 m across in front of you: composition")
    print("layers do not depth-sort, so anything between your eyes and a panel cuts")
    print("through it. Unlit or baked materials only — the headset has no light budget.")
    return 0


def cmd_doctor(a):
    print("harnesses on $PATH:")
    found = agents.installed()
    for h, path in sorted(found.items()):
        print("  %-12s %s" % (h, path))
    if not found:
        print("  (none) — install one: claude, codex, gemini, aider, opencode …")
    print("hooks (tier 2):")
    for r in hooks.statuses(sorted(found) if found else None):
        _print(r)
    print("daemon:")
    try:
        with socket.create_connection((HOST, PORT), timeout=2):
            print("  answering on %s:%d" % (HOST, PORT))
    except OSError as e:
        print("  NOT reachable on %s:%d (%s) — run ./start.sh --lan" % (HOST, PORT, e))
    return 0


def main(argv=None):
    """Entry point for `atrium` (installed) and bin/atrium (checkout)."""
    ap = argparse.ArgumentParser(prog="atrium", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    n = sub.add_parser("notify", help="report an agent state (tier 1)")
    n.add_argument("session", help="tmux session name, or 'auto'")
    n.add_argument("state", choices=STATES)
    n.add_argument("--reason")
    n.add_argument("--detail")
    n.add_argument("--title")
    n.add_argument("--agent")
    n.set_defaults(fn=cmd_notify)

    h = sub.add_parser("hooks", help="harness hook installers (tier 2)")
    h.add_argument("action", choices=["status", "install", "uninstall"])
    h.add_argument("harness", nargs="?", help="claude-code | codex | gemini-cli | qwen-code | all")
    h.add_argument("--dry-run", action="store_true")
    h.add_argument("--path", help="settings file to edit instead of the default")
    h.set_defaults(fn=cmd_hooks)

    i = sub.add_parser("init", help="first-time setup on this computer")
    i.add_argument("--yes", "-y", action="store_true", help="answer yes to every prompt")
    i.add_argument("--no-hooks", action="store_true")
    i.add_argument("--autostart", dest="autostart", action="store_true", default=None)
    i.add_argument("--no-autostart", dest="autostart", action="store_false")
    i.add_argument("--dry-run", action="store_true", help="show the plan, change nothing")
    i.set_defaults(fn=cmd_init)

    st = sub.add_parser("start", help="start an agent in a new tmux session")
    st.add_argument("harness", help="claude-code | codex | gemini-cli | aider | … or a command")
    st.add_argument("dir", nargs="?", help="working directory (default: here)")
    st.add_argument("--name", help="tmux session name")
    st.add_argument("--detach", "-d", action="store_true", help="do not attach")
    st.epilog = "Arguments for the harness itself go after `--`."

    st.set_defaults(fn=cmd_start)

    c = sub.add_parser("config", help="open your config.lua")
    c.set_defaults(fn=cmd_config)

    pn = sub.add_parser("pin", help="stop the headset shrinking a session on your desktop")
    pn.add_argument("action", choices=("off", "on", "status"),
                    help="off = never resize this session (headset shows a crop); "
                         "on = allow again; status = every session's geometry")
    pn.add_argument("session", nargs="?", help="tmux session (default: the one you are in)")
    pn.set_defaults(fn=cmd_pin)

    pr = sub.add_parser("preset", help="pick what is behind the windows")
    pr.add_argument("action", choices=("list", "use"))
    pr.add_argument("name", nargs="?", help="cafe | nebula | void | passthrough")
    pr.set_defaults(fn=cmd_preset)

    pk = sub.add_parser("pack", help="use your own .glb as the room")
    pk.add_argument("glb", help="path to a self-contained .glb")
    pk.add_argument("--name", help="what to call it (default: the file's name)")
    pk.set_defaults(fn=cmd_pack)

    dm = sub.add_parser("daemon", help="run the daemon in the foreground")
    dm.add_argument("--lan", action="store_true", help="bind 0.0.0.0 (the headset needs this)")
    dm.set_defaults(fn=cmd_daemon)

    up = sub.add_parser("up", help="start the daemon detached on the LAN if it is not running")
    up.set_defaults(fn=lambda a: print(start_daemon(lan=True)) or 0)

    pr = sub.add_parser("pair", help="print a one-time pairing code for the headset")
    pr.set_defaults(fn=cmd_pair)

    d = sub.add_parser("doctor", help="what is installed and reachable")
    d.set_defaults(fn=cmd_doctor)

    argv = list(sys.argv[1:] if argv is None else argv)
    # `start … -- <harness args>`: everything after `--` belongs to the harness,
    # and must not be parsed here (REMAINDER would also eat our own options).
    extra = []
    if argv and argv[0] == "start" and "--" in argv:
        i = argv.index("--")
        extra, argv = argv[i + 1:], argv[:i]
    a = ap.parse_args(argv)
    if a.cmd == "start":
        a.args = extra
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())

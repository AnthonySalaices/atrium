"""glasshouse — the host-side command.

    glasshouse notify <session|auto> <state> [--reason R] [--detail D]
        Tier-1 integration: tell the daemon what an agent is doing, from ANY
        tool, hook system or script. `auto` = the tmux session this shell is in.
        States: idle, working, needs-input, error, done, gone.

    glasshouse hooks status|install|uninstall [harness|all] [--dry-run] [--path FILE]
        Tier-2 integration: install the harness's own hook entries so the glow is
        exact. Backs up, merges, re-parses, idempotent.

    glasshouse init [--yes] [--no-hooks] [--autostart|--no-autostart] [--dry-run]
        First-time setup on this computer: checks, finds your agent harnesses,
        offers their hooks, writes the config and token, starts the daemon on
        the LAN, optionally registers it to start at login, prints the pairing
        card. Safe to re-run; every step skips what is already done.

    glasshouse start <harness> [dir] [--name NAME]
        Start an agent in a new named tmux session and attach to it. The one
        command a non-tmux user ever needs; Glasshouse finds the session by
        what is running in it.

    glasshouse config
        Open your config.lua in $EDITOR (created from the starter if missing).

    glasshouse pair
        Print a one-time 6-digit code (valid 10 minutes) to type into the
        headset's pairing card. The APK ships with no secret; this is how it
        gets the token.

    glasshouse doctor
        What is installed, what is hooked, whether the daemon answers.

    glasshouse up | daemon [--lan]
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

HERE = os.path.dirname(os.path.abspath(__file__))       # glassd/
ROOT = os.path.dirname(HERE)                               # the checkout, if any
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import agents  # noqa: E402
import hooks   # noqa: E402

HOST = os.environ.get("GLASSHOUSE_HOST", "127.0.0.1")
PORT = int(os.environ.get("GLASSHOUSE_PORT", "7570"))
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
        sys.exit("glasshouse notify: not inside tmux and no session given")
    if a.state not in STATES:
        sys.exit("glasshouse notify: state must be one of %s" % ", ".join(STATES))
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
    p = os.environ.get("GLASSHOUSE_TOKEN_FILE") or os.path.join(CONFIG_DIR, "token")
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
        sys.exit("glasshouse pair: no token file yet — start the daemon once (./start.sh --lan)")
    try:
        c = http.client.HTTPConnection(HOST, PORT, timeout=3)
        c.request("POST", "/pair/new", body="{}",
                  headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
        r = c.getresponse()
        v = json.loads(r.read().decode() or "{}")
    except Exception as e:
        sys.exit("glasshouse pair: daemon not reachable on %s:%d (%s) — run ./start.sh --lan" % (HOST, PORT, e))
    if r.status != 200 or "code" not in v:
        sys.exit("glasshouse pair: daemon refused (%s %s)" % (r.status, v))
    code = v["code"]
    mins = int(v.get("ttl", 600)) // 60
    addrs = _lan_addresses()
    lan = v.get("bind") not in (None, "127.0.0.1", "localhost")
    print()
    print("  ┌──────────────────────────────────────────┐")
    print("  │  Glasshouse pairing                       │")
    print("  │                                          │")
    print("  │  code   %s   %s                        │" % (code[:3], code[3:]))
    print("  │  host   %-33s│" % ((addrs[0] + ":" + str(PORT)) if addrs else "(no LAN address found)"))
    print("  │                                          │")
    print("  │  Put the headset on, open Glasshouse and  │")
    print("  │  enter the code. Valid %2d minutes, once.  │" % mins)
    print("  └──────────────────────────────────────────┘")
    if len(addrs) > 1:
        print("  other addresses: " + ", ".join(addrs[1:]))
    if not lan:
        print("  ⚠️  the daemon is bound to loopback — the headset cannot reach it. Restart with ./start.sh --lan")
    print()
    return 0


CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "glasshouse")
USER_CONFIG = os.path.join(CONFIG_DIR, "config.lua")
STARTER = os.path.join(HERE, "config", "starter.lua") if os.path.exists(os.path.join(HERE, "config", "starter.lua")) \
    else os.path.join(ROOT, "config", "starter.lua")
START_SH = os.path.join(ROOT, "start.sh")                  # checkout only
LOG_PATH = os.path.join(CONFIG_DIR, "glassd.log")


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
    """Start glassd detached. A checkout has start.sh (port-guarded, logs under
    the repo); an installed package runs `glasshouse daemon` under nohup."""
    if daemon_up():
        return "daemon already listening on %d" % PORT
    if os.path.exists(START_SH):
        r = subprocess.run([START_SH] + (["--lan"] if lan else []), capture_output=True, text=True)
        return (r.stdout.strip() or r.stderr.strip())
    os.makedirs(CONFIG_DIR, exist_ok=True)
    env = dict(os.environ, GLASSHOUSE_BIND="0.0.0.0" if lan else "127.0.0.1")
    with open(LOG_PATH, "ab") as log:
        subprocess.Popen([sys.executable, "-m", "glassd.cli", "daemon"] + (["--lan"] if lan else []),
                         stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                         start_new_session=True, env=env)
    import time
    for _ in range(20):
        if daemon_up():
            return "glassd started on %s:%d" % ("0.0.0.0" if lan else "127.0.0.1", PORT)
        time.sleep(0.25)
    return "glassd did not answer — see " + LOG_PATH


def cmd_daemon(a):
    """Run the daemon in the foreground (what autostart and start_daemon use)."""
    if a.lan:
        os.environ["GLASSHOUSE_BIND"] = "0.0.0.0"
    # ⚠️ `import glassd` here would give the PACKAGE (this directory), not the
    # daemon module glassd/glassd.py that shares its name. Load the file itself.
    import importlib.util
    spec = importlib.util.spec_from_file_location("glassd_daemon", os.path.join(HERE, "glassd.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.main()


def _autostart_installed():
    try:
        out = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return False
    return "# glasshouse" in out


def install_autostart(dry_run=False):
    """Start at login without sudo: a systemd user unit where the bus exists,
    otherwise cron (@reboot + a 5-minute keeper; start.sh is idempotent)."""
    unit_dir = os.path.expanduser("~/.config/systemd/user")
    have_user_bus = subprocess.run(["systemctl", "--user", "is-system-running"],
                                   capture_output=True, text=True).returncode in (0, 1) and \
        "No medium" not in subprocess.run(["systemctl", "--user", "is-system-running"],
                                          capture_output=True, text=True).stderr
    if have_user_bus:
        unit = os.path.join(unit_dir, "glasshouse.service")
        text = ("[Unit]\nDescription=Glasshouse daemon\nAfter=network-online.target\n\n"
                "[Service]\nExecStart=%s -m glassd.cli daemon --lan\nRestart=on-failure\n\n"
                "[Install]\nWantedBy=default.target\n" % sys.executable)
        if dry_run:
            return "would write %s and enable it" % unit
        os.makedirs(unit_dir, exist_ok=True)
        with open(unit, "w") as f:
            f.write(text)
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True)
        subprocess.run(["systemctl", "--user", "enable", "--now", "glasshouse.service"], capture_output=True)
        return "systemd user unit %s enabled" % unit
    if _autostart_installed():
        return "cron entries already present"
    starter = ("%s --lan" % START_SH) if os.path.exists(START_SH) else \
        ("%s -m glassd.cli up" % sys.executable)
    lines = ["@reboot sleep 20 && %s # glasshouse" % starter,
             "*/5 * * * * %s >/dev/null 2>&1 # glasshouse keeper" % starter]
    if dry_run:
        return "would add to crontab: " + " | ".join(lines)
    cur = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    new = cur.rstrip("\n") + ("\n" if cur.strip() else "") + "\n".join(lines) + "\n"
    subprocess.run(["crontab", "-"], input=new, text=True, check=True)
    return "cron: @reboot + 5-minute keeper added"


def cmd_init(a):
    auto = True if a.yes else None
    print("Glasshouse setup — every step skips what is already done.")

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
        _warn("Glasshouse still shows any of them the moment they run inside tmux.")
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
                _warn("%s: %s is not valid JSON — fix it, then `glasshouse hooks install %s`" % (h, st.path, h)); continue
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
        _ok("wrote %s (all defaults, commented) — `glasshouse config` opens it" % USER_CONFIG)
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
        print("  (run `glasshouse pair` when the daemon is up)")
    else:
        cmd_pair(a)
    print("Next: open Glasshouse in the headset and enter the code. Then `glasshouse start claude` "
          "(or any harness) on this computer.")
    return 0


def _which(name):
    from shutil import which
    return which(name)


def cmd_start(a):
    t = agents.table()
    row = t.get(a.harness)
    if row is None:
        # Allow a raw command too: `glasshouse start ./my-agent.sh`
        if _which(a.harness) or os.path.exists(a.harness):
            row = {"match": [a.harness]}
        else:
            sys.exit("glasshouse start: unknown harness %r — one of: %s" % (a.harness, ", ".join(sorted(t))))
    exe = next((m for m in row["match"] if _which(m)), None)
    if exe is None:
        sys.exit("glasshouse start: %s is not on $PATH" % " / ".join(row["match"]))
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
        sys.exit("glasshouse start: tmux failed: " + (r.stderr.strip() or r.stdout.strip()))
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
            print("not inside tmux — name the session: glasshouse pin %s <session>" % a.action,
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
        print("   undo with: glasshouse pin on %s" % key)
    else:
        _tmux("set-option", "-w", "-u", "-t", key, _pin.PIN_OPT)
        print("%s: the headset may resize this session while watching it" % key)
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
    """Entry point for `glasshouse` (installed) and bin/glasshouse (checkout)."""
    ap = argparse.ArgumentParser(prog="glasshouse", description=__doc__,
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

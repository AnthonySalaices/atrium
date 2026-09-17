"""Which terminal programs count as agents, and how to guess their state.

⭐ "Provider" is the wrong axis; "harness" is the right one. DeepSeek, GPT, Claude
and Qwen are models. What sits in a tmux pane is a *harness* (Claude Code, Codex
CLI, Gemini CLI, aider, OpenCode…) and one harness can front several models.
Glasshouse recognises harnesses and never touches a model or an API key, so
"DeepSeek support" is a row in this table, not an integration.

Three tiers of knowing when an agent needs you:

  3  universal   the pane's process tree contains a known harness, and the last
                 lines of the pane are scraped for that harness's prompt phrases
                 (heuristic — the daemon marks it so the glow renders dimmer)
  2  hooks       the harness itself reports events (Claude Code hooks, Codex
                 `notify`) — exact; handled in glassd.handle_event
  1  user shim   any tool calls `glasshouse notify` — exact; not built yet

Everything here is tier 3. Users extend the table from config.lua:

    agents = { extra = { mytool = { name = "My Tool",
                                    needs_input = {"Proceed?"}, working = {"…"} } } }

⚠️ Phrases marked "unverified" were written from documentation and memory, not
from a captured pane. A wrong phrase costs a dim glow and nothing else: the
scraper can never type into a pane.
"""

import os
import re
import subprocess

# command name -> harness. `match` is what the process is called (comm, or the
# basename of its first argv tokens, which is what catches `node …/gemini.js`).
HARNESSES = {
    "claude-code": {
        "name": "Claude Code",
        "match": ["claude"],
        "needs_input": ["Do you want to", "Would you like to proceed", "Allow once",
                        "(y/n)", "Esc to cancel"],
        "working": ["esc to interrupt"],
        "hooks": "claude-code",          # tools/install-hooks.py
    },
    "codex": {
        "name": "Codex CLI",
        "match": ["codex"],
        "needs_input": ["Allow command", "Approve", "Yes, proceed", "(y/n)"],   # unverified
        "working": ["Esc to interrupt", "esc to interrupt", "Working"],          # unverified
        "hooks": "codex-notify",         # `notify = [...]` in config.toml — installer pending
    },
    "gemini-cli": {
        "name": "Gemini CLI",
        "match": ["gemini"],
        "needs_input": ["Allow execution", "Yes, allow once", "(y/n)"],          # unverified
        "working": ["esc to cancel", "Esc to cancel"],                           # unverified
        "hooks": None,
    },
    "qwen-code": {
        "name": "Qwen Code",
        "match": ["qwen"],
        "needs_input": ["Allow execution", "Yes, allow once", "(y/n)"],          # unverified (Gemini fork)
        "working": ["esc to cancel", "Esc to cancel"],
        "hooks": None,
    },
    "opencode": {
        "name": "OpenCode",
        "match": ["opencode"],
        "needs_input": ["Permission", "permission", "Allow"],                    # unverified
        "working": ["esc interrupt", "working"],                                  # unverified
        "hooks": None,
    },
    "aider": {
        "name": "aider",
        "match": ["aider"],
        "needs_input": ["(Y)es/(N)o", "[Y/n]", "[y/N]", "Add them to the chat?"], # unverified
        "working": [],
        "hooks": None,
    },
    "crush": {"name": "Crush", "match": ["crush"], "needs_input": ["Allow", "(y/n)"],
              "working": [], "hooks": None},
    "goose": {"name": "Goose", "match": ["goose"], "needs_input": ["Allow", "(y/n)"],
              "working": [], "hooks": None},
    "amp": {"name": "Amp", "match": ["amp"], "needs_input": ["Allow", "(y/n)"],
            "working": [], "hooks": None},
    "copilot": {"name": "Copilot CLI", "match": ["copilot"], "needs_input": ["Allow", "(y/n)"],
                "working": [], "hooks": None},
    "kiro": {"name": "Kiro CLI", "match": ["kiro-cli", "kiro"], "needs_input": ["Allow", "(y/n)"],
             "working": [], "hooks": None},
    "cursor-agent": {"name": "Cursor Agent", "match": ["cursor-agent"],
                     "needs_input": ["Allow", "(y/n)"], "working": [], "hooks": None},
}

# Processes that are never a harness on their own, so a pane running one of
# these is still worth walking into.
SHELLS = {"bash", "zsh", "fish", "sh", "dash", "tmux", "script", "ssh", "sudo",
          "node", "python", "python3", "bun", "deno", "uv", "uvx", "npx", "pnpm"}


def table(cfg=None):
    """The built-in table with the user's `agents.extra` merged over it."""
    t = {k: dict(v) for k, v in HARNESSES.items()}
    extra = ((cfg or {}).get("agents") or {}).get("extra") or {}
    if isinstance(extra, dict):
        for key, spec in extra.items():
            if not isinstance(spec, dict):
                continue
            row = t.get(key, {"name": key, "match": [key], "needs_input": [],
                              "working": [], "hooks": None})
            row = dict(row)
            for f in ("name", "hooks"):
                if f in spec:
                    row[f] = spec[f]
            for f in ("match", "needs_input", "working"):
                if f in spec and isinstance(spec[f], list):
                    row[f] = [str(x) for x in spec[f]]
            t[key] = row
    return t


def _index(t):
    """match-name -> harness id"""
    idx = {}
    for hid, row in t.items():
        for m in row.get("match", []):
            idx[m] = hid
    return idx


def _names_of(comm, args):
    """Candidate names for a process: its comm plus the basenames of its first
    two argv tokens (catches `node /…/gemini.js` and `python -m aider`)."""
    out = [comm]
    toks = (args or "").split()
    for tok in toks[:3]:
        out.append(os.path.basename(tok))
        # `aider.py`, `gemini.js` → `aider`, `gemini`
        out.append(re.sub(r"\.(py|js|mjs|cjs|sh)$", "", os.path.basename(tok)))
    return out


def read_procs():
    """pid -> (ppid, comm, args) for every process. One `ps` per poll."""
    try:
        out = subprocess.run(["ps", "-e", "-o", "pid=,ppid=,comm=,args="],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return {}
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 3:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = (ppid, parts[2], parts[3] if len(parts) > 3 else "")
    return procs


def find_harness(pane_pid, pane_cmd, procs, t=None):
    """Which harness (if any) lives in this pane.

    ⚠️ tmux's `pane_current_command` flips to `bash`/`python3` while the agent runs
    a tool, so a single field is not enough: walk the pane's process tree
    breadth-first and return the first known harness. The pane's own command is
    checked first because it is free."""
    t = t or HARNESSES
    idx = _index(t)
    if pane_cmd in idx:
        return idx[pane_cmd]
    children = {}
    for pid, (ppid, comm, args) in procs.items():
        children.setdefault(ppid, []).append(pid)
    queue = [pane_pid]
    seen = set()
    depth = 0
    while queue and depth < 6:
        nxt = []
        for pid in queue:
            if pid in seen:
                continue
            seen.add(pid)
            if pid in procs:
                _, comm, args = procs[pid]
                for n in _names_of(comm, args):
                    if n in idx:
                        return idx[n]
            nxt.extend(children.get(pid, []))
        queue = nxt
        depth += 1
    return None


def classify(pane_text, harness, t=None):
    """Guess a state from the last lines of the pane. Returns (state, reason)."""
    t = t or HARNESSES
    row = t.get(harness) or {}
    tail = "\n".join(pane_text.splitlines()[-12:])
    for phrase in row.get("needs_input", []):
        if phrase and phrase in tail:
            return "needs-input", "prompt-scrape"
    for phrase in row.get("working", []):
        if phrase and phrase in tail:
            return "working", "prompt-scrape"
    return "idle", "prompt-scrape"


def session_allowed(name, cfg):
    """`sessions.include` / `sessions.exclude`: regex lists over the session
    name. An empty include means everything (an empty Lua table is a cleared
    list). A bad pattern is ignored rather than hiding every session."""
    sess = (cfg or {}).get("sessions") or {}
    inc = sess.get("include") or []
    exc = sess.get("exclude") or []

    def hit(patterns):
        for p in patterns:
            try:
                if re.search(str(p), name):
                    return True
            except re.error:
                continue
        return False

    if inc and not hit(inc):
        return False
    if exc and hit(exc):
        return False
    return True


def installed(t=None):
    """Which harnesses are on $PATH — for `glasshouse init` and `doctor`."""
    t = t or HARNESSES
    found = {}
    path = os.environ.get("PATH", "").split(os.pathsep)
    for hid, row in t.items():
        for m in row.get("match", []):
            for d in path:
                fp = os.path.join(d, m)
                if os.path.isfile(fp) and os.access(fp, os.X_OK):
                    found[hid] = fp
                    break
            if hid in found:
                break
    return found

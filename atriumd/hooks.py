"""Tier-2 integrations: make a harness report its own state.

One installer per harness, all behind the same interface, registered in
INSTALLERS and looked up by the harness id from agents.py. Adding a harness
that has a hooks system is: subclass, set the file path, the event list and
the entry shape. Nothing else in Atrium changes.

Every installer follows the rules that keep an edit to somebody's live agent
config safe:

- the previous file is copied to <file>.bak-<timestamp> first
- the file is MERGED, never rewritten: every other key survives
- the result is re-parsed before it replaces the original (a settings file that
  fails to parse silently disables *all* settings in it)
- re-running is a no-op, and uninstall removes only our own entries
- a file that does not parse is left alone and reported, never "fixed"

The hook command is always `glow-emit.sh <harness>`: stdout-silent, exit 0,
fire-and-forget UDP to the daemon. See glow-emit.sh for why that matters.
"""

import json
import os
import shutil
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EMIT = os.path.join(HERE, "glow-emit.sh")


class Result:
    def __init__(self, harness, path, status, changes=None, note=None):
        self.harness = harness
        self.path = path
        self.status = status          # installed | partial | absent | invalid | unsupported
        self.changes = changes or []
        self.note = note

    def __repr__(self):
        return "<%s %s %s %s>" % (self.harness, self.status, self.path, self.changes)


class JsonHooks:
    """settings.json-style hooks: {"hooks": {Event: [ {matcher?, hooks:[{type,command,..}]} ]}}

    Claude Code, Gemini CLI, Qwen Code and Codex (hooks.json) all share this
    shape; they differ in path, event list, timeout units and a few entry fields.
    """

    harness = ""
    default_path = ""
    events = []
    timeout = 5                      # seconds unless timeout_ms
    timeout_ms = False
    entry_name = None                # Gemini wants a friendly "name"
    matcher = None                   # add "matcher": value to each group when set
    top_key = "hooks"

    def __init__(self, path=None):
        self.path = os.path.expanduser(path or self.default_path)

    # ── shape ────────────────────────────────────────────────────────────
    def command(self):
        return "%s %s" % (EMIT, self.harness)

    def hook_entry(self):
        e = {"type": "command", "command": self.command(),
             "timeout": self.timeout * 1000 if self.timeout_ms else self.timeout}
        if self.entry_name:
            e["name"] = self.entry_name
        return e

    def group(self):
        g = {"hooks": [self.hook_entry()]}
        if self.matcher is not None:
            g["matcher"] = self.matcher
        return g

    @staticmethod
    def is_ours(group):
        for h in (group or {}).get("hooks", []) or []:
            if isinstance(h, dict) and h.get("type") == "command" \
                    and "glow-emit.sh" in str(h.get("command", "")):
                return True
        return False

    # ── io ───────────────────────────────────────────────────────────────
    def load(self):
        """Returns (settings dict or None if invalid, error string or None)."""
        if not os.path.exists(self.path):
            return {}, None
        try:
            with open(self.path) as f:
                text = f.read().strip()
        except OSError as e:
            return None, str(e)
        if not text:
            return {}, None
        try:
            v = json.loads(text)
        except json.JSONDecodeError as e:
            return None, "not valid JSON: %s" % e
        if not isinstance(v, dict):
            return None, "top level is not an object"
        return v, None

    def status(self):
        settings, err = self.load()
        if settings is None:
            return Result(self.harness, self.path, "invalid", note=err)
        hooks = settings.get(self.top_key) or {}
        have = [ev for ev in self.events if any(self.is_ours(g) for g in (hooks.get(ev) or []))]
        if not have:
            return Result(self.harness, self.path, "absent")
        if len(have) == len(self.events):
            return Result(self.harness, self.path, "installed")
        return Result(self.harness, self.path, "partial",
                      note="missing: " + ", ".join(ev for ev in self.events if ev not in have))

    def plan(self, uninstall=False):
        settings, err = self.load()
        if settings is None:
            return None, Result(self.harness, self.path, "invalid", note=err)
        hooks = settings.get(self.top_key) or {}
        if not isinstance(hooks, dict):
            return None, Result(self.harness, self.path, "invalid",
                                note="%r is not an object" % self.top_key)
        changes = []
        if uninstall:
            for ev in list(hooks):
                groups = hooks[ev] if isinstance(hooks[ev], list) else []
                kept = [g for g in groups if not self.is_ours(g)]
                if len(kept) != len(groups):
                    changes.append("remove %s" % ev)
                    if kept:
                        hooks[ev] = kept
                    else:
                        del hooks[ev]
        else:
            for ev in self.events:
                groups = hooks.setdefault(ev, [])
                if not isinstance(groups, list):
                    return None, Result(self.harness, self.path, "invalid",
                                        note="%s.%s is not a list" % (self.top_key, ev))
                if any(self.is_ours(g) for g in groups):
                    continue
                groups.append(self.group())
                changes.append("add %s" % ev)
        if hooks:
            settings[self.top_key] = hooks
        else:
            settings.pop(self.top_key, None)
        return settings, Result(self.harness, self.path,
                                "absent" if uninstall else "installed", changes)

    def apply(self, uninstall=False, dry_run=False):
        if not os.path.exists(EMIT) or not os.access(EMIT, os.X_OK):
            return Result(self.harness, self.path, "invalid",
                          note="hook script missing or not executable: %s" % EMIT)
        settings, res = self.plan(uninstall)
        if settings is None or not res.changes or dry_run:
            return res
        rendered = json.dumps(settings, indent=2) + "\n"
        json.loads(rendered)                     # never write what we cannot read back
        if os.path.exists(self.path):
            backup = "%s.bak-%s" % (self.path, time.strftime("%Y%m%d-%H%M%S"))
            shutil.copy2(self.path, backup)
            res.note = "backup: " + backup
        else:
            os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = self.path + ".atrium-tmp"
        with open(tmp, "w") as f:
            f.write(rendered)
        os.replace(tmp, self.path)
        return res


class ClaudeCode(JsonHooks):
    harness = "claude-code"
    default_path = "~/.claude/settings.json"
    # ⛔ PreToolUse / PostToolUse deliberately NOT hooked: they fire on every tool
    # call in every session, and PreToolUse's stdout is a permission DECISION.
    events = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification",
              "Stop", "StopFailure", "SubagentStop", "SessionEnd"]
    timeout = 5


class GeminiCli(JsonHooks):
    """Gemini CLI: ~/.gemini/settings.json, timeouts in ms, entries carry a name.
    Events verified against the hooks reference 2026-09-17; stdin carries
    hook_event_name / session_id / cwd, and Notification has
    notification_type = "ToolPermission"."""
    harness = "gemini-cli"
    default_path = "~/.gemini/settings.json"
    events = ["SessionStart", "BeforeAgent", "AfterAgent", "Notification", "SessionEnd"]
    timeout = 5
    timeout_ms = True
    entry_name = "atrium"
    matcher = "*"


class QwenCode(GeminiCli):
    """Qwen Code is a Gemini CLI fork; same shape, own settings path. ⚠️ Unverified
    that the fork carries the hooks system — status reports it as experimental."""
    harness = "qwen-code"
    default_path = "~/.qwen/settings.json"


class Codex(JsonHooks):
    """Codex CLI lifecycle hooks: ~/.codex/hooks.json, Claude-compatible event
    names, gated by `[features] hooks = true` in config.toml (checked and
    reported by status(), never edited here — TOML is the user's to flip)."""
    harness = "codex"
    default_path = "~/.codex/hooks.json"
    events = ["SessionStart", "UserPromptSubmit", "PermissionRequest",
              "Stop", "SessionEnd", "Interrupt"]
    timeout = 5
    config_toml = "~/.codex/config.toml"

    def feature_enabled(self):
        p = os.path.expanduser(self.config_toml)
        if not os.path.exists(p):
            return None
        try:
            import tomllib
            with open(p, "rb") as f:
                cfg = tomllib.load(f)
            return bool((cfg.get("features") or {}).get("hooks"))
        except Exception:
            return None

    def status(self):
        r = super().status()
        if self.feature_enabled() is False and r.status in ("installed", "partial"):
            r.note = ((r.note + "; ") if r.note else "") + \
                "installed, but Codex will not load them until config.toml has " \
                "[features] hooks = true"
        return r


INSTALLERS = {
    "claude-code": ClaudeCode,
    "codex": Codex,
    "gemini-cli": GeminiCli,
    "qwen-code": QwenCode,
}


def installer(harness, path=None):
    cls = INSTALLERS.get(harness)
    return cls(path) if cls else None


def statuses(harnesses=None):
    out = []
    for h in (harnesses or INSTALLERS):
        inst = installer(h)
        if inst is None:
            out.append(Result(h, "", "unsupported",
                              note="no hooks system known; tier 3 scrape only"))
        else:
            out.append(inst.status())
    return out

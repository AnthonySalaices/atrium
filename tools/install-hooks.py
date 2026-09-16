#!/usr/bin/env python3
"""Install (or remove) the Glasshouse hooks in Claude Code's settings.

    tools/install-hooks.py              # show what would change, then apply
    tools/install-hooks.py --dry-run    # show only
    tools/install-hooks.py --uninstall  # remove only our entries
    tools/install-hooks.py --settings /path/to/settings.json

Hooks are what make the glow *exact* rather than guessed. Without them the
daemon falls back to scraping the pane for prompt text, which is a heuristic;
with them, "this agent is waiting for you" is a fact reported by the agent.

⚠️ This edits a file that every running Claude Code session reads, so:

- the previous file is copied to settings.json.bak-<timestamp> first,
- every other setting is preserved (the file is merged, never rewritten),
- the result is re-parsed before it replaces the original — a settings file
  that fails to parse silently disables *all* settings in it,
- re-running is a no-op, and --uninstall touches only our own entries.

⛔ **`PreToolUse` and `PostToolUse` are deliberately NOT hooked.** They fire on
every tool call in every session, which is a lot of subprocess churn for a
signal the tmux poller already provides as a heartbeat — and `PreToolUse` is the
one event whose stdout is a *permission decision*, so a buggy hook there could
allow or deny tool calls. That is not a risk worth taking for a glow.
"""

import argparse
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EMIT = os.path.join(os.path.dirname(HERE), "glassd", "glow-emit.sh")
COMMAND = "%s claude-code" % EMIT

EVENTS = [
    "SessionStart",       # -> idle
    "UserPromptSubmit",   # -> working
    "PermissionRequest",  # -> needs-input   ⭐ the glow that matters
    "Notification",       # -> needs-input, refined by notification_type
    "Stop",               # -> idle, turn finished
    "StopFailure",        # -> error
    "SubagentStop",       # -> still working
    "SessionEnd",         # -> gone
]

DEFAULT_SETTINGS = os.path.expanduser("~/.claude/settings.json")


def entry():
    return {"hooks": [{"type": "command", "command": COMMAND, "timeout": 5}]}


def is_ours(group):
    for h in group.get("hooks", []):
        if h.get("type") == "command" and "glow-emit.sh" in str(h.get("command", "")):
            return True
    return False


def load(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        text = f.read().strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.exit("⛔ %s is not valid JSON (%s).\n"
                 "   Fix it first — a settings file that fails to parse disables\n"
                 "   every setting in it." % (path, e))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--settings", default=DEFAULT_SETTINGS)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--uninstall", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(EMIT):
        sys.exit("⛔ hook script not found: %s" % EMIT)
    if not os.access(EMIT, os.X_OK):
        sys.exit("⛔ hook script is not executable: chmod +x %s" % EMIT)

    path = os.path.expanduser(args.settings)
    settings = load(path)
    hooks = settings.get("hooks") or {}
    changes = []

    if args.uninstall:
        for event in list(hooks):
            kept = [g for g in hooks[event] if not is_ours(g)]
            if len(kept) != len(hooks[event]):
                changes.append("remove %s" % event)
                if kept:
                    hooks[event] = kept
                else:
                    del hooks[event]
    else:
        for event in EVENTS:
            groups = hooks.setdefault(event, [])
            if any(is_ours(g) for g in groups):
                continue
            groups.append(entry())
            changes.append("add %s" % event)

    if hooks:
        settings["hooks"] = hooks
    else:
        settings.pop("hooks", None)

    if not changes:
        print("Nothing to do — already %s." % ("removed" if args.uninstall else "installed"))
        return 0

    print("%s:\n  %s" % (path, "\n  ".join(changes)))
    print("\ncommand: %s" % COMMAND)
    other = sorted(k for k in settings if k != "hooks")
    print("preserved settings: %s" % (", ".join(other) or "(none)"))

    if args.dry_run:
        print("\n--dry-run: nothing written.")
        return 0

    rendered = json.dumps(settings, indent=2) + "\n"
    json.loads(rendered)          # never write something we cannot read back

    if os.path.exists(path):
        backup = "%s.bak-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("\nbackup: %s" % backup)
    else:
        os.makedirs(os.path.dirname(path), exist_ok=True)

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(rendered)
    os.replace(tmp, path)         # atomic: a reader never sees a half-written file
    print("written.")

    print("\nRunning sessions load settings at startup, so open /hooks once (that\n"
          "re-reads the config) or start a new session for this to take effect.\n"
          "Check it landed:  glassd's /state should show `source` naming a hook\n"
          "event, e.g. Stop or Notification, instead of tmux-poll.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

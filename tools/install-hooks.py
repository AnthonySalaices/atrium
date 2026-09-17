#!/usr/bin/env python3
"""Install (or remove) the Glasshouse hooks in Claude Code's settings.

Kept for the commands in older notes; it is now a thin wrapper over

    bin/glasshouse hooks install|uninstall|status [harness] [--dry-run] [--path FILE]

which knows every harness with a hooks system (Claude Code, Codex, Gemini CLI,
Qwen Code). The safety rules live in glassd/hooks.py: backup first, merge never
rewrite, re-parse before replacing, idempotent, uninstall touches only ours.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(os.path.dirname(HERE), "bin", "glasshouse")

args = sys.argv[1:]
action = "uninstall" if "--uninstall" in args else "install"
rest = []
i = 0
while i < len(args):
    a = args[i]
    if a == "--uninstall":
        pass
    elif a == "--settings":
        rest += ["--path", args[i + 1]]
        i += 1
    else:
        rest.append(a)
    i += 1
sys.exit(subprocess.call([sys.executable, CLI, "hooks", action, "claude-code"] + rest))

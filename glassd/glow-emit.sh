#!/bin/bash
# glow-emit.sh — fire-and-forget hook shim for glowd.
# Claude Code / Codex hook: reads the event JSON on stdin.
# Codex `notify`: pass the payload as $1 (argv), we detect and use it.
# NEVER writes to stdout (a PermissionRequest hook's stdout is a DECISION).
# NEVER fails: exits 0 even if glowd is down.
GLOW_HOST=${GLOW_HOST:-127.0.0.1}; GLOW_PORT=${GLOW_PORT:-7570}
AGENT=${1:-claude-code}
PAYLOAD=${2:-}
{
  [ -n "$PAYLOAD" ] || PAYLOAD=$(timeout 1 cat)
  [ -n "$PAYLOAD" ] || exit 0
  # Only report real interactive top-level sessions living in tmux.
  # sdk-cli = a nested `claude -p` subagent: its Stop must NOT clear the parent panel.
  [ "${CLAUDE_CODE_ENTRYPOINT:-cli}" = "cli" ] || exit 0
  [ -n "$TMUX_PANE" ] || exit 0
  KEY=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
  [ -n "$KEY" ] || exit 0
  TITLE=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_title}' 2>/dev/null)
  MSG=$(printf '%s' "$PAYLOAD" | jq -c --arg k "$KEY" --arg a "$AGENT" --arg p "$TMUX_PANE" \
        --arg t "$TITLE" --arg pid "${CLAUDE_PID:-$PPID}" \
        '. + {src:"hook", key:$k, agent:$a, pane:$p, title:$t, pid:($pid|tonumber?)}' 2>/dev/null) || exit 0
  exec 3<>"/dev/udp/$GLOW_HOST/$GLOW_PORT" && printf '%s' "$MSG" >&3 && exec 3>&-
} >/dev/null 2>&1
exit 0

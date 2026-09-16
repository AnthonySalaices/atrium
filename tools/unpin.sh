#!/usr/bin/env bash
# Manual escape hatch: put every pinned tmux window back to normal.
# Use if a headset died mid-session and left a window at VR geometry.
set -u
for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
  cur=$(tmux show-options -w -v -t "$s" window-size 2>/dev/null)
  if [ "$cur" = "manual" ]; then
    tmux set-option -w -t "$s" window-size latest
    tmux resize-window -t "$s" -A 2>/dev/null
    echo "restored $s (was manual)"
  fi
done
echo "done"

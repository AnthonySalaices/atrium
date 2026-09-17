#!/usr/bin/env bash
# Manual escape hatch: put every pinned tmux window back to normal.
# Use if a headset died mid-session and left a window at VR geometry.
# Prefers the restore record glassd leaves on the window (@glasshouse_prev);
# falls back to "unset the manual size" when there is none.
set -u
for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
  rec=$(tmux show-options -w -v -t "$s" @glasshouse_prev 2>/dev/null)
  if [ -n "$rec" ]; then
    IFS='|' read -r size cols rows <<<"$rec"
    tmux resize-window -t "$s" -x "$cols" -y "$rows" 2>/dev/null
    if [ "$size" = "-" ]; then
      tmux set-option -w -u -t "$s" window-size
    else
      tmux set-option -w -t "$s" window-size "$size"
    fi
    tmux set-option -w -u -t "$s" @glasshouse_prev
    echo "restored $s to ${cols}x${rows} (window-size ${size/-/unset})"
    continue
  fi
  cur=$(tmux show-options -w -v -t "$s" window-size 2>/dev/null)
  if [ "$cur" = "manual" ]; then
    tmux set-option -w -t "$s" window-size latest
    tmux resize-window -t "$s" -A 2>/dev/null
    echo "restored $s (was manual)"
  fi
done
echo "done"

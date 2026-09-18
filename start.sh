#!/usr/bin/env bash
# Idempotent start for atriumd. Port-guarded, modelled on vr-gallery/start.sh.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${ATRIUM_PORT:-7570}"
BIND="${ATRIUM_BIND:-127.0.0.1}"

# ⚠️ The headset cannot reach a loopback bind, so a headset session needs:
#     ./start.sh --lan
# Loopback stays the default on purpose: this streams the full terminal
# contents, titles and cwds of every agent on this host.
if [ "${1:-}" = "--lan" ]; then
  BIND=0.0.0.0
fi

if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "atriumd already listening on ${PORT}"
  exit 0
fi

mkdir -p "$DIR/logs"
cd "$DIR/atriumd" || exit 1
ATRIUM_PORT="$PORT" ATRIUM_BIND="$BIND" \
  nohup /usr/bin/python3 "$DIR/atriumd/atriumd.py" >> "$DIR/logs/atriumd.log" 2>&1 &
sleep 1
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "atriumd started on ${BIND}:${PORT}"
  [ "$BIND" = "0.0.0.0" ] || echo "   (loopback only — the Quest needs ./start.sh --lan)"
else
  echo "atriumd FAILED to start — see $DIR/logs/atriumd.log" >&2
  exit 1
fi

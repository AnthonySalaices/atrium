#!/usr/bin/env bash
# Idempotent start for glassd. Port-guarded, modelled on vr-gallery/start.sh.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${GLASSHOUSE_PORT:-7570}"
BIND="${GLASSHOUSE_BIND:-127.0.0.1}"

# ⚠️ The headset cannot reach a loopback bind, so a headset session needs:
#     ./start.sh --lan
# Loopback stays the default on purpose: this streams the full terminal
# contents, titles and cwds of every agent on this host.
if [ "${1:-}" = "--lan" ]; then
  BIND=0.0.0.0
fi

if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "glassd already listening on ${PORT}"
  exit 0
fi

mkdir -p "$DIR/logs"
cd "$DIR/glassd" || exit 1
GLASSHOUSE_PORT="$PORT" GLASSHOUSE_BIND="$BIND" \
  nohup /usr/bin/python3 "$DIR/glassd/glassd.py" >> "$DIR/logs/glassd.log" 2>&1 &
sleep 1
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo "glassd started on ${BIND}:${PORT}"
  [ "$BIND" = "0.0.0.0" ] || echo "   (loopback only — the Quest needs ./start.sh --lan)"
else
  echo "glassd FAILED to start — see $DIR/logs/glassd.log" >&2
  exit 1
fi

#!/usr/bin/env bash
# Install + launch the spike APK on the Quest, and tee logcat to logs/.
#
#   tools/deploy-quest.sh
#
# ⛔ The headset leaves the network the moment it sleeps, so this only works
# while it is actually being worn. Everything is staged in advance so the
# window is short.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${1:-$ROOT/godot/build/atrium.apk}"
PKG="io.github.anthonysalaices.atrium"
# Your headset's address. Set QUEST_ADDR, or leave it and the first device adb
# already knows about is used.
QUEST="${QUEST_ADDR:-$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')}"
if [ -z "$QUEST" ]; then
  echo "no headset: set QUEST_ADDR=<ip>:5555, or 'adb connect <ip>:5555' first" >&2
  exit 1
fi
ADB="${ADB:-$HOME/bin/adb}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

[ -f "$APK" ] || { echo "no APK at $APK — run tools/build-apk.sh" >&2; exit 1; }

echo "── connecting to $QUEST"
"$ADB" connect "$QUEST" >/dev/null 2>&1
state="$("$ADB" -s "$QUEST" get-state 2>/dev/null)"
if [ "$state" != "device" ]; then
  echo "FAIL: headset not reachable (state: ${state:-offline})." >&2
  echo "      It drops off the network the instant it sleeps — put it on first." >&2
  exit 1
fi

echo "── battery: $("$ADB" -s "$QUEST" shell dumpsys battery 2>/dev/null | awk '/level/{print $2}')%"
echo "── installing $(du -h "$APK" | cut -f1)"
"$ADB" -s "$QUEST" install -r -g "$APK" 2>&1 | tail -3

echo "── starting probe receiver on this host"
if ! ss -ltn 2>/dev/null | grep -q ":7572 "; then
  (PROBE_PORT=7572 nohup python3 "$ROOT/tools/probe-receiver.py" >> "$ROOT/logs/probe-receiver.log" 2>&1 &)
  sleep 1
fi
ss -ltn 2>/dev/null | grep -q ":7572 " && echo "   receiver up on 7572" || echo "   WARN receiver not listening"

echo "── launching"
"$ADB" -s "$QUEST" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
"$ADB" -s "$QUEST" logcat -c 2>/dev/null
LOGF="$ROOT/logs/logcat-$STAMP.txt"
echo "── logcat → $LOGF   (ctrl-c when he takes the headset off)"
"$ADB" -s "$QUEST" logcat -v time godot:V GodotOpenXR:V "*:S" 2>/dev/null | tee "$LOGF"

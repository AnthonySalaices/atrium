#!/usr/bin/env bash
# Headless Quest APK build + verification. No GUI, no sudo.
#
#   tools/build-apk.sh [preset] [outfile]
#
# Asserts the things that silently go wrong: signature, arm64 payload, the
# OpenXR loader, and (once enabled) the Meta hand-tracking manifest entry.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESET="${1:-Quest}"
OUT="${2:-build/atrium.apk}"
BT="36.1.0"

# shellcheck source=/dev/null
source "$ROOT/toolchain/env.sh"
cd "$ROOT/godot" || exit 1

APKSIGNER="$ANDROID_HOME/build-tools/$BT/apksigner"
AAPT="$ANDROID_HOME/build-tools/$BT/aapt2"

# ⚠️ Never set GODOT_ANDROID_KEYSTORE_DEBUG* here. Godot reads *_DEBUG_PATH; the
# shorter name leaves user+password set with no path and every export dies with
# "Either Debug Keystore, Debug User AND Debug Password ... OR none of them".
unset GODOT_ANDROID_KEYSTORE_DEBUG GODOT_ANDROID_KEYSTORE_DEBUG_USER GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD

INSTALL_TEMPLATE=""
# ⚠️ --install-android-build-template HANGS forever when run on its own; it is
# only meaningful alongside an --export-* flag. Pass it once, then never again.
[ -d android/build ] || INSTALL_TEMPLATE="--install-android-build-template"

echo "── exporting preset '$PRESET' → $OUT"
# shellcheck disable=SC2086
"$GODOT" --headless --path . $INSTALL_TEMPLATE --export-debug "$PRESET" "$OUT" 2>&1 \
  | grep -viE "^\[ *[0-9]+%|DONE|^\s*$|cannot connect to daemon|adb" | tail -8

[ -f "$OUT" ] || { echo "FAIL: no APK produced" >&2; exit 1; }

echo "── verifying"
fail=0
check() { if [ "$1" = "1" ]; then echo "  ok   $2"; else echo "  FAIL $2" >&2; fail=1; fi }

"$APKSIGNER" verify "$OUT" >/dev/null 2>&1 && check 1 "signature verifies" || check 0 "signature verifies"

# ⚠️ Capture ONCE into variables. Piping straight into `grep -q` makes grep exit
# on the first match, which SIGPIPEs unzip/aapt2 — and under `set -o pipefail`
# that reads as a failed check on a perfectly good APK. (Cost one debugging
# round; it is the same trap as `yes | sdkmanager` in bootstrap-toolchain.sh.)
listing="$(unzip -l "$OUT" 2>/dev/null)"
badging="$("$AAPT" dump badging "$OUT" 2>/dev/null)"

arches=$(printf '%s' "$listing" | grep -oE 'lib/[a-z0-9_-]+' | sort -u | sed 's|lib/||' | tr '\n' ' ')
[ "$(printf '%s' "$arches" | tr -d ' ')" = "arm64-v8a" ] \
  && check 1 "arm64-v8a only" || check 0 "expected arm64-v8a only, got: $arches"

case "$listing" in *libopenxr_loader.so*) check 1 "OpenXR loader present";;
                   *) check 0 "OpenXR loader MISSING";; esac

case "$badging" in *org.khronos.openxr.permission.OPENXR*) check 1 "OpenXR permission in manifest";;
                   *) check 0 "OpenXR permission MISSING";; esac

# Hand tracking comes from the godot_openxr_vendors plugin's Meta export
# section. Core Godot has no such option, so this stays a warning until the
# plugin is enabled and its Meta features are switched on in the preset.
case "$badging" in
  *oculus.software.handtracking*) echo "  ok   Meta hand-tracking feature declared";;
  *) echo "  note hand-tracking not declared yet (enable godotopenxrvendors + its Meta export options)";;
esac

echo "── $(du -h "$OUT" | cut -f1)  $(printf '%s' "$badging" | sed -n '1p')"
exit $fail

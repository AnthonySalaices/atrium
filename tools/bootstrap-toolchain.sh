#!/usr/bin/env bash
# Godot 4.7.2 + Android SDK + OpenXR vendors plugin, entirely under $HOME.
# No sudo, no system packages. Resumable: every step skips if already done.
#
#   tools/bootstrap-toolchain.sh          # ~10 GB, 1-2 h unattended
#
# Versions are pinned deliberately — see AGENTS.md. Godot 4.7.2's Android build
# template declares javaVersion 17, so we use the SYSTEM OpenJDK 17, not the
# Temurin 21 in ~/tools.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="$ROOT/toolchain"
LOG="$ROOT/logs/bootstrap.log"
mkdir -p "$TC" "$ROOT/logs"

GODOT_VER=4.7.2-stable
GODOT_TPL_DIR="$HOME/.local/share/godot/export_templates/4.7.2.stable"
CMDLINE_BUILD=15859902
SDK="$TC/android-sdk"
JAVA_HOME_17=/usr/lib/jvm/java-17-openjdk-amd64
VENDORS_TAG=5.1.0-stable

# Pinned Android packages (recon-verified against Godot 4.7.2's config.gradle)
SDK_PKGS=(
  "platform-tools"
  "build-tools;36.1.0"
  "platforms;android-36"
  "cmake;3.22.1"
  "ndk;29.0.14206865"
)

log()  { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }

log "=== bootstrap start — target $TC ==="
df -h "$ROOT" | tail -1 | tee -a "$LOG"

# ── 1. Godot editor ─────────────────────────────────────────────────────────
if [ -x "$TC/godot/godot" ]; then
  log "godot: already installed ($("$TC/godot/godot" --headless --version 2>/dev/null | head -1))"
else
  log "godot: downloading $GODOT_VER editor"
  mkdir -p "$TC/godot"
  curl -fsSL --retry 3 --retry-delay 5 \
    -o "$TC/godot.zip" \
    "https://github.com/godotengine/godot/releases/download/$GODOT_VER/Godot_v${GODOT_VER}_linux.x86_64.zip" \
    || fail "godot editor download"
  unzip -oq "$TC/godot.zip" -d "$TC/godot" || fail "godot unzip"
  mv "$TC/godot/Godot_v${GODOT_VER}_linux.x86_64" "$TC/godot/godot"
  chmod +x "$TC/godot/godot"
  rm -f "$TC/godot.zip"
  log "godot: $("$TC/godot/godot" --headless --version 2>/dev/null | head -1)"
fi

# ── 2. Export templates ─────────────────────────────────────────────────────
if [ -f "$GODOT_TPL_DIR/android_source.zip" ]; then
  log "templates: already installed"
else
  log "templates: downloading .tpz (~1 GB)"
  curl -fsSL --retry 3 --retry-delay 5 \
    -o "$TC/templates.tpz" \
    "https://github.com/godotengine/godot/releases/download/$GODOT_VER/Godot_v${GODOT_VER}_export_templates.tpz" \
    || fail "templates download"
  mkdir -p "$GODOT_TPL_DIR"
  # .tpz is a zip whose entries live under templates/
  unzip -oq "$TC/templates.tpz" -d "$TC/tpl" || fail "templates unzip"
  mv "$TC/tpl/templates/"* "$GODOT_TPL_DIR/" || fail "templates move"
  rm -rf "$TC/tpl" "$TC/templates.tpz"
  log "templates: $(ls "$GODOT_TPL_DIR" | wc -l) files in $GODOT_TPL_DIR"
fi

# ── 3. Android SDK ──────────────────────────────────────────────────────────
[ -d "$JAVA_HOME_17" ] || fail "OpenJDK 17 not found at $JAVA_HOME_17"
export JAVA_HOME="$JAVA_HOME_17"
export PATH="$JAVA_HOME/bin:$PATH"

SDKMGR="$SDK/cmdline-tools/latest/bin/sdkmanager"
if [ -x "$SDKMGR" ]; then
  log "cmdline-tools: already installed"
else
  log "cmdline-tools: downloading"
  mkdir -p "$SDK/cmdline-tools"
  curl -fsSL --retry 3 --retry-delay 5 \
    -o "$TC/cmdline.zip" \
    "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_BUILD}_latest.zip" \
    || fail "cmdline-tools download"
  unzip -oq "$TC/cmdline.zip" -d "$SDK/cmdline-tools" || fail "cmdline-tools unzip"
  # sdkmanager insists on living at cmdline-tools/latest/
  mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  rm -f "$TC/cmdline.zip"
  log "cmdline-tools: installed"
fi

log "licenses: accepting"
yes 2>/dev/null | "$SDKMGR" --sdk_root="$SDK" --licenses >/dev/null 2>&1
log "licenses: done"

# ⚠️ `yes | sdkmanager` under `set -o pipefail` reports 141: when sdkmanager
# closes the pipe, `yes` takes SIGPIPE and pipefail surfaces THAT, not
# sdkmanager's own status. Read PIPESTATUS instead — this cost one run.
SDKOUT="$TC/.sdkmgr.out"
for pkg in "${SDK_PKGS[@]}"; do
  log "sdk: installing $pkg"
  yes 2>/dev/null | "$SDKMGR" --sdk_root="$SDK" "$pkg" >"$SDKOUT" 2>&1
  rc=${PIPESTATUS[1]}
  # progress bars are carriage-return spam; keep only real lines
  tr '\r' '\n' < "$SDKOUT" \
    | grep -vaE '^[[:space:]]*$|^\[|Loading |Fetch remote|Computing updates|Unzipping|Downloading |Installing ' \
    | tail -4 >> "$LOG"
  if [ "$rc" -ne 0 ]; then
    tr '\r' '\n' < "$SDKOUT" | tail -20 >> "$LOG"
    fail "sdk package $pkg (sdkmanager exit $rc)"
  fi
  log "sdk: $pkg ok"
done
rm -f "$SDKOUT"
log "sdk: all packages installed"

# ── 4. OpenXR vendors plugin (required for Quest hand tracking) ─────────────
ADDON="$ROOT/godot/addons/godotopenxrvendors"
if [ -d "$ADDON" ]; then
  log "vendors plugin: already installed"
else
  log "vendors plugin: downloading $VENDORS_TAG (48 MB)"
  mkdir -p "$ROOT/godot/addons"
  curl -fsSL --retry 3 --retry-delay 5 \
    -o "$TC/vendors.zip" \
    "https://github.com/GodotVR/godot_openxr_vendors/releases/download/$VENDORS_TAG/godotopenxrvendorsaddon.zip" \
    || fail "vendors download"
  unzip -oq "$TC/vendors.zip" -d "$TC/vendors" || fail "vendors unzip"
  SRC="$(find "$TC/vendors" -maxdepth 3 -type d -name godotopenxrvendors | head -1)"
  [ -n "$SRC" ] || fail "vendors: addon dir not found in zip"
  cp -r "$SRC" "$ADDON" || fail "vendors copy"
  rm -rf "$TC/vendors" "$TC/vendors.zip"
  log "vendors plugin: installed to $ADDON"
fi

# Reference sample — our sharp-text plan rests on this node, so keep a working
# implementation to read rather than guessing from docs.
if [ ! -d "$TC/samples/meta-composition-layers" ]; then
  log "samples: fetching meta-composition-layers reference"
  mkdir -p "$TC/samples"
  curl -fsSL --retry 2 -o "$TC/cl.zip" \
    "https://github.com/GodotVR/godot_openxr_vendors/releases/download/$VENDORS_TAG/meta-composition-layers-sample.zip" \
    && unzip -oq "$TC/cl.zip" -d "$TC/samples/meta-composition-layers" \
    && rm -f "$TC/cl.zip" && log "samples: composition-layers sample ready" \
    || log "samples: composition-layers fetch failed (non-fatal)"
fi

# ── 5. Debug keystore ───────────────────────────────────────────────────────
# Created manually: Godot's auto-create path fires on an editor-settings
# notification that a --headless one-shot export may never raise.
KS="$TC/debug.keystore"
if [ -f "$KS" ]; then
  log "keystore: already exists"
else
  log "keystore: creating debug keystore"
  "$JAVA_HOME/bin/keytool" -keyalg RSA -genkeypair -alias androiddebugkey \
    -keypass android -keystore "$KS" -storepass android \
    -dname "CN=Android Debug,O=Android,C=US" -validity 9999 -deststoretype pkcs12 \
    >>"$LOG" 2>&1 || fail "keystore creation"
  log "keystore: created at $KS"
fi

# ── 6. Environment file for later steps ─────────────────────────────────────
cat > "$TC/env.sh" <<ENVEOF
# source this before any Godot/Android work
export JAVA_HOME="$JAVA_HOME_17"
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
export GODOT="$TC/godot/godot"
# ⚠️ Deliberately NOT exporting GODOT_ANDROID_KEYSTORE_DEBUG*: Godot reads
# *_DEBUG_PATH, so the shorter name leaves user+password set with no path and
# every export fails with "Either Debug Keystore, Debug User AND Debug Password
# must be configured OR none of them". Keystore goes in editor settings.
# keystore: $KS (user androiddebugkey, pass android)
export PATH="\$JAVA_HOME/bin:$SDK/platform-tools:\$PATH"
ENVEOF
log "wrote $TC/env.sh"

# ── 7. Verify ───────────────────────────────────────────────────────────────
log "=== verification ==="
"$TC/godot/godot" --headless --version 2>/dev/null | head -1 | tee -a "$LOG"
"$JAVA_HOME/bin/java" -version 2>&1 | head -1 | tee -a "$LOG"
for p in "platform-tools" "build-tools/36.1.0" "platforms/android-36" "ndk/29.0.14206865" "cmake/3.22.1"; do
  if [ -e "$SDK/$p" ]; then log "  ok   $p"; else log "  MISS $p"; fi
done
[ -f "$GODOT_TPL_DIR/android_source.zip" ] && log "  ok   android_source.zip" || log "  MISS android_source.zip"
[ -d "$ADDON" ] && log "  ok   vendors addon" || log "  MISS vendors addon"
[ -f "$KS" ] && log "  ok   debug.keystore" || log "  MISS debug.keystore"
log "toolchain size: $(du -sh "$TC" 2>/dev/null | cut -f1)"
log "=== bootstrap complete ==="

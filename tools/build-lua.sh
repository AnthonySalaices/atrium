#!/usr/bin/env bash
# Build the vendored Lua 5.4 interpreter used to evaluate user config.
# ~300 KB of MIT-licensed ANSI C, needs only gcc + make. No sudo, no packages.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER=5.4.7
SHA=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
OUT="$DIR/vendor/lua/bin/lua"

if [ -x "$OUT" ]; then echo "lua already built: $("$OUT" -v)"; exit 0; fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -sSL -o "$TMP/lua.tar.gz" "https://www.lua.org/ftp/lua-$VER.tar.gz"
echo "$SHA  $TMP/lua.tar.gz" | sha256sum -c - || { echo "checksum mismatch" >&2; exit 1; }
tar xzf "$TMP/lua.tar.gz" -C "$TMP"
make -C "$TMP/lua-$VER" posix >/dev/null    # posix, not linux: no readline dependency
mkdir -p "$(dirname "$OUT")"
cp "$TMP/lua-$VER/src/lua" "$OUT"
echo "built $("$OUT" -v)"

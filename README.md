# Glasshouse

**Your terminal agents, as floating panels in a Quest 3 — each one glowing when it needs you.**

Glasshouse renders a live terminal session inside a Meta Quest 3 as a sharp, readable panel on
an OpenXR composition layer, streamed from the machine the session actually runs on. It is built
for people who run several coding agents at once (Claude Code, Codex, anything that lives in
tmux) and want to *see* which one is waiting on them without alt-tabbing through panes.

Native Godot 4. No browser, no native extensions, no VT parser of its own.

> **Status: early, and honest about it.** One readable panel works on real hardware. Typing
> works end to end on the host and has not yet been confirmed in the headset. The glow — the
> part that makes this worth building — is designed and not yet drawn. Versions before 1.0 will
> break things. See [Status](#status).

## The idea that makes it tractable

**tmux is already the terminal emulator.**

`tmux capture-pane -p -e -N` hands you an already-rendered cell grid whose only escape codes are
SGR colour codes — no cursor motion, no scroll regions, no alternate-screen bookkeeping — and it
works straight through a full-screen TUI. So the host parses, diffs and streams cells, and the
headset is dumb glass that paints them and sends keystrokes back.

That one decision removes libvterm, a GDExtension, the Android NDK and a patched terminal fork
from the critical path. The Godot client is **pure GDScript with zero native dependencies**.

## What works today

| | |
|---|---|
| Host daemon streaming a live cell grid over WebSocket | ✅ |
| Sharp text on an `OpenXRCompositionLayerQuad` | ✅ on device — visibly sharper than a textured mesh |
| Typing back into the session (`tmux send-keys`) | ✅ verified on the host, ⏳ not yet in the headset |
| Terminal window resized to the panel — and **restored** afterwards | ✅ |
| Lua config, hot-reloaded without a rebuild or reinstall | ✅ |
| Procedural animated backdrop + generated ambience | ✅ |
| Passthrough backdrop | ✅ runtime support confirmed |
| Per-session glow tiles (the actual point) | ⏳ designed, not drawn |
| Liquid-glass panel material | ⏳ not started |
| Hand tracking | ⏳ declared in the manifest, unused so far |

## How it fits together

```
   ┌─ your machine ──────────────────────┐        ┌─ Quest 3 ─────────────┐
   │  tmux session (claude, codex, …)    │        │                       │
   │     │ capture-pane -p -e -N         │        │   Godot 4 client      │
   │     ▼                               │        │     │                 │
   │  glassd ── cell grid + row diffs ───┼─ WS ───┼──▶ cell painter       │
   │     ▲                               │ token  │     │                 │
   │     │ tmux send-keys ◀──── keys ────┼────────┼──   composition layer │
   │  config.lua (evaluated here)        │        │                       │
   └─────────────────────────────────────┘        └───────────────────────┘
```

The Lua config is evaluated **on the host**, never in the headset — a Lua GDExtension would mean
an Android NDK build, which is the dependency class this design exists to avoid. It also means
saving `config.lua` restyles the live panel with no rebuild and no reinstall.

## Requirements

- A Meta Quest 3 (others untested), developer mode on
- A Linux host running `tmux` 3.2+ and Python 3.9+, reachable from the headset
- For building the APK yourself: ~4 GB of disk. No root, no GUI, no Android Studio.

## Install the host side

```bash
pipx install git+https://github.com/AnthonySalaices/glasshouse   # or: pip install .
glasshouse init
```

`init` checks tmux and Python, finds the agent harnesses on your PATH (Claude Code, Codex,
Gemini CLI, aider, OpenCode, …), offers to install each one's hooks so the glow is exact, writes
`~/.config/glasshouse/config.lua` and a token, starts the daemon on your LAN, can register it to
start at login (no sudo), and prints a pairing card. Re-running it skips whatever is done;
`--dry-run` only shows the plan.

Then, in the headset, open Glasshouse and type the code from the card. That is the whole
pairing: the APK carries no host and no secret. `glasshouse pair` prints a fresh code any time;
ctrl+alt+P in the headset opens the card again.

```bash
glasshouse start claude-code ~/my-project   # an agent in a named tmux session (any harness)
glasshouse config                           # your config.lua, restyles the headset live on save
glasshouse doctor                           # what is installed, hooked and reachable
glasshouse notify auto needs-input          # tell the daemon yourself, from any hook or script
```

Config is evaluated by `lupa` (Lua 5.4 in a wheel) so nothing needs compiling. A checkout that
has run `tools/build-lua.sh` uses the vendored interpreter instead; the output is identical.

## Build the headset app

```bash
# 1. Toolchain: Godot 4.7.2 + Android SDK/NDK + the OpenXR vendors plugin.
#    ~3.2 GB, resumable, everything under $HOME. No sudo.
tools/bootstrap-toolchain.sh

# 2. Build and install. The APK pairs with the host on first run, so it needs
#    nothing baked in. (A dev build may still drop a host.txt/token.txt into
#    godot/data/ to skip pairing — see the .example files.)
tools/build-apk.sh
tools/deploy-quest.sh
```

From a checkout the daemon can also be run with `./start.sh --lan` (`./start.sh` alone binds
loopback, which the headset cannot reach).

Check it without a headset at all:

```bash
curl -s "localhost:7570/screen/<session>.txt?token=$(cat ~/.config/glasshouse/token)"
python3 -m unittest discover -s tests     # 105 tests
python3 tools/keys-smoke.py               # typing, end to end, no headset
```

## Hooks — what makes the glow exact

Without hooks, the daemon guesses at agent state by scraping the pane for prompt text. With
them, "this agent is waiting for you" is a fact the agent reports.

```bash
tools/install-hooks.py --dry-run     # show what would change
tools/install-hooks.py               # merge, after backing the file up
tools/install-hooks.py --uninstall   # remove only these entries
```

It edits `~/.claude/settings.json`, which every running session reads, so it backs the file up
first, merges rather than rewrites, re-parses the result before replacing the original, and is a
no-op when re-run. Open `/hooks` once afterwards (that re-reads the config) or start a new
session.

⛔ `PreToolUse` and `PostToolUse` are deliberately **not** hooked: they fire on every tool call
for a signal the poller already covers, and `PreToolUse` stdout is a *permission decision* — the
one place a buggy hook could allow or deny tool calls.

## Configuration

WezTerm's model: an opinionated baseline you override only where you disagree, reloaded on save.
Every key is documented in [`config/default.lua`](config/default.lua); your overrides go in
`~/.config/glasshouse/config.lua`.

```lua
return {
  backdrop = { mode = "passthrough" },   -- passthrough | default | custom .glb
  font     = { size_dmm = 22.3 },        -- angular size; 18 is the readability floor
  glass    = { opacity = 0.38 },         -- the window material, never the backdrop
}
```

A broken config is treated as data, not a crash: the evaluator always emits JSON, the daemon
keeps the last good config, and the error is sent to the headset to display.

## Read this before you point it at anything you care about

- ⚠️ **The daemon streams terminal contents, window titles and working directories for every
  agent session on the host.** It is the most revealing service you will run on that machine.
  It is token-gated and binds loopback unless you pass `--lan`. **Do not put it behind a public
  proxy.**
- ⚠️ **Watching a session resizes it.** The client pins the tmux window to the panel's geometry
  and restores the previous size on unsubscribe, on disconnect, after a 90-second silence
  watchdog, and via `tools/unpin.sh`. If you hack on this, keep the restore path.
- ⚠️ **The token currently ships inside the APK.** Fine on a private network you own; a
  first-run pairing flow is what should replace it, and it is not written yet.

## Why not a browser, or Immersed, or a mesh?

- **WebXR** cannot reliably get key events in an immersive session, and text on a textured mesh
  is visibly soft. Composition layers exist precisely because of that second problem.
- **Screen mirroring** (Immersed, Virtual Desktop) is excellent at being a monitor. It has no
  idea what your agents are doing, so it cannot glow when one needs you.
- The interesting part was never the pixels; it is the **ambient awareness of parallel agents**,
  which is the one thing a flat desk genuinely cannot do.

## A number worth knowing before you plan a layout

At the Quest 3's ~25 pixels per degree you get about **1.56 comfortably readable columns per
degree**. The full ~104° field of view therefore holds roughly **162 columns, total**, and a
single 80-column terminal eats about 51° of it.

"Five readable terminals floating around me" is not a design decision, it is physically
unavailable on this hardware. Glasshouse is built around that: **one** readable focus panel,
plus small glanceable tiles that carry a name, a state and a glow — never prose.

## Status

Pre-alpha, developed against one Quest 3 and one Linux host. Interfaces will change. The
protocol is versioned (`proto`) but not yet stable. Issues and patches welcome, especially from
anyone with different hardware; see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design
and the hard-won gotchas, which are the most useful thing in this repo.

## Licence

MIT — see [LICENSE](LICENSE).

The bundled font is **Iosevka Term Medium** by Renzhi Li, under the SIL Open Font License 1.1;
its licence text is in [`godot/fonts/LICENSE-Iosevka-OFL.md`](godot/fonts/LICENSE-Iosevka-OFL.md).
`godotopenxrvendors` (downloaded by the bootstrap script, not vendored here) is MIT.

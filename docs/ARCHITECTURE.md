# Architecture, and the things that cost real time

This is the document worth reading before changing anything. The design section explains why the
pieces are where they are; the rest is a list of behaviours that are genuinely surprising, each
of which was paid for in debugging.

## Design

### The host does the terminal emulation

`tmux capture-pane -p -e -N` returns a rendered cell grid containing only SGR colour escapes. No
cursor motion, no scroll regions, no alternate-screen state to track — and it works through a
full-screen TUI, which is the case that breaks naive scrapers.

So the split is:

- **host (`glassd/`)** — captures panes, parses SGR into styled cells, diffs row by row, runs the
  session state machine, evaluates the Lua config, validates and forwards keystrokes.
- **headset (`godot/`)** — paints cells into a `SubViewport`, hands that viewport to an
  `OpenXRCompositionLayerQuad`, and sends key events back.

⛔ **Do not add libvterm, a GDExtension or the Android NDK to the critical path.** Deleting them
was the point of this design. The client is pure GDScript, which is also why it can be built
headless on a server with no GPU and no X display.

### Composition layers, not meshes

A composition layer is submitted to the compositor separately from the eye buffers, so it is
sampled at full display resolution instead of through the scene's render target. For a terminal —
which is nothing but fine detail — the difference is visible to the naked eye. Confirmed on a
Quest 3 by putting identical text on a cylinder layer, a quad layer and a textured `QuadMesh` at
the same distance: the mesh was the only blurry one.

⛔ **Never paint terminal text on a mesh.** Always route it through a layer.

Two consequences to design around:

- **Layers do not depth-sort with the 3D scene.** Nothing in the scene can appear in front of a
  layer, so any environment must keep a clear volume between the viewer and the panels.
- **Layers cannot be backdrop-blurred by the scene**, which is the central tension with a
  frosted-glass look. The working hypothesis is a hybrid: glass frame, edge highlight and shadow
  as in-scene geometry, with the text on a layer inset inside the frame. Unproven.

### Legibility sets the layout, not taste

At ~25 pixels per degree, comfortable reading works out to **1.56 columns per degree**. A ~104°
field of view holds ~162 columns *in total*; one 80-column terminal is ~51°.

Font size is specified in **dmm** (1 dmm = 1 milliradian), because angular size is what the eye
cares about — a bigger panel further away is the same to read. The floor is 18 dmm; the default,
**22.3 dmm**, was chosen by eye from a five-rung ladder in the headset and independently matches
the figure derived from the PPD. Treat 22.3 as settled and 18 as a floor rather than a target.

⚠️ **dmm is the size of the FONT, not of a cell.** Dividing by the cell advance instead of the
font pixel size makes every panel exactly 2× too large, and the result looks plausible enough
that you will not notice until you measure it.

This is why the model is two-tier: **one** readable focus panel, plus up to seven glanceable
tiles carrying a name, a state colour and a glow. Tiles are not for reading prose.

## Wire protocol

One WebSocket, JSON frames both ways, token in the query string or an `Authorization: Bearer`
header. Client → host operations:

| op | meaning |
|---|---|
| `subscribe` | start streaming a session; optionally pin it to `cols` × `rows` |
| `unsubscribe` | stop, and restore the window's previous geometry |
| `resync` | ask for a full frame instead of a diff (after a local rebuild) |
| `keys` | type — see below |
| `ack` | mark a session as read, clearing its glow |
| `ping` | keepalive; also the pin watchdog's heartbeat |

Host → client frame types: `snapshot`, `session`, `removed`, `screen`, `config`, `keys-ack`,
`pong`, `error`. A `screen` frame with `base == 0` is a full frame; otherwise it carries only
changed rows.

### Typing

```json
{"op":"keys","key":"my-session","seq":[{"l":"ls -la"},{"k":"Enter"}],"t":12345}
```

`l` is literal text; `k` is a **tmux key name**. The client never builds escape sequences itself,
because only tmux knows whether the pane currently wants `ESC [ A` or `ESC O A` for Up. `t` is
echoed back in `keys-ack` so the client can measure round-trip time without a shared clock.

Two safety properties, both deliberate:

- A client may only type into a session it has **subscribed** to. Otherwise one authorised client
  could type into every agent on the host, including ones it cannot see.
- Names are validated against a **whitelist** on the host, and every call is argv — never a shell
  string.

## Surprises, each one paid for

### tmux types unknown key names instead of rejecting them

⛔ **This is the one that will bite you.** `tmux send-keys -t s -- S-Tab` does not fail. It puts
the literal text `S-Tab` into the pane. `Backspace` types the word "Backspace". The real names
are `BTab` and `BSpace`.

So a typo in a key table does not raise an error, it types garbage into a live session. The host
whitelist is not defence in depth, it is the only defence. Verified byte-for-byte against a real
pane; `tests/test_keys.py` has a test named after it.

### A pane in canonical mode eats the bytes you are testing

If you verify key bytes by piping a pane into a file, the tty line discipline gets there first:
`0x12` (`C-r`) is REPRINT, `0x7f` (`BSpace`) is ERASE, `C-c` sends a signal, and nothing is
delivered until a newline. Correct keys therefore look like they vanished.

Put the pane in raw mode (`stty raw -echo`) before drawing any conclusion. Reference table,
captured that way:

```
C-a 01   C-r 12   C-c 03   C-d 04   C-l 0c   BSpace 7f   Escape 1b   Tab 09
Enter 0d   Up 1b5b41   BTab 1b5b5a   DC 1b5b337e   S-Up 1b5b313b3241
C-Space 00   M-b 1b62   C-M-x 1b18        (modifier order is irrelevant to tmux)
```

### Ctrl chords carry no unicode

`InputEventKey.unicode == 0` for Ctrl combinations, which is correct — control characters have no
printable code point. The chord must be rebuilt from keycode plus modifier state. Passing
`unicode` through sends nothing at all, and looks like "ctrl doesn't work in XR".

Autorepeat (`echo`) is passed through on purpose: holding Backspace should delete repeatedly.

### Vendor features fail silently without a matching project setting

`godot_openxr_vendors` reads its export options and, if a corresponding *project setting* is
missing, injects nothing into the manifest at all — no error, no warning beyond an easily missed
`Property not found`. Both of these are required:

```ini
xr/openxr/extensions/hand_tracking=true
xr/openxr/extensions/meta/passthrough=true
```

Without the second one the runtime offers only the opaque blend mode, so passthrough silently
cannot work. The diagnostic that cracks this class of bug: flip `quest_3_support` and watch
`com.oculus.supportedDevices` appear and vanish in the manifest, which proves the options *are*
being read and moves the search to the gate.

Vendor option names are effectively undocumented; extract them from the plugin binary with
`strings … | grep -E '^meta_xr_features'`.

### Other build traps

- ⛔ **`export_filter="all_resources"` does not export plain `.txt` files.** The preset needs
  `include_filter="*.txt"`, or data files silently come back empty — which presents as an
  authentication failure with no clue attached.
- ⛔ **`android.permission.INTERNET` is not included by default.** Without
  `permissions/internet=true` every request dies at `_inet_open`.
- ⛔ **`set -o pipefail` plus a consumer that exits early produces fake failures.** `yes |
  sdkmanager` reports 141 on a *successful* install, and `unzip -l … | grep -q` SIGPIPEs unzip so
  a perfectly good APK reads as broken. Capture into a variable, or check `PIPESTATUS`.
- ⛔ **`--install-android-build-template` hangs forever on its own.** It is only meaningful
  alongside an `--export-*` flag.
- ⛔ **Never set `GODOT_ANDROID_KEYSTORE_DEBUG`** (no `_PATH`): it leaves user and password set
  with no path, and every export fails with a message about needing all three or none.
- ⚠️ `.ttf` and `.png` need an explicit `--headless --import` pass before the first `load()`.
- ⚠️ **GDScript lambdas capture locals by value**, so a builder closure cannot hand a node back
  to its caller — it silently stays null. Build UI with plain functions.

### Runtime and comfort

- ⛔ **An automatic recentre must check head height first.** A headset sitting on a desk while the
  app launches — which is what happens on every install — will otherwise anchor every panel at
  desk height behind the user. Automatic triggers defer below ~0.9 m and retry; explicit ones (a
  key, or the system recentre gesture) always fire.
- ⛔ **A cylinder layer's position is the centre of the cylinder**, and `radius` is the distance
  out to the curved surface. Placing the node at the panel distance *and* setting `radius` to the
  same value puts the surface twice as far away as intended.
- ⚠️ **Cylinder layers do not follow a moving rig** between rooms in our testing, while quad
  layers do. Cause unknown; the focus panel uses a quad because of it.
- ⚠️ Foveation blurs off-centre text, which is all a terminal has. It is set to 0 deliberately.
- ⚠️ Reading back a display refresh rate in the same instant you request it returns the old
  value. Re-read it a second later before believing either number.

### tmux integration

- ⚠️ **`-N`, never `-J`** on `capture-pane`. `-J` joins wrapped lines and destroys a fixed grid;
  `-N` pads rows to the pane width and keeps trailing spaces.
- ⚠️ **`display-message -p -t <bad-target>` exits 0 with empty output.** A zero return code is not
  proof the target exists; validate the fields.
- ⚠️ **`resize-window` sets `window-size` to `manual`.** Restoring geometry must resize *first*
  and unset the option *last*, or the resize re-creates the override you are removing.
- ⚠️ **Never pin a window without a restore path.** A detached session has no client to re-derive
  its size from, so a client that dies without unsubscribing would leave someone's daily terminal
  reflowed. Hence: restore on unsubscribe, on disconnect, on a silence watchdog, and manually via
  `tools/unpin.sh`.
- ⚠️ `pkill -f <pattern>` matches the command line of the shell that invoked it, so it kills its
  own caller. Find the pid from the listening socket instead.

## Config evaluation

`config/eval.lua` loads `config/default.lua`, deep-merges the user's table over it, and prints
JSON. `glassd/config.py` runs that, validates and clamps, and watches for changes.

⚠️ **An empty Lua table is both an empty list and an empty map.** Over a map it must mean "change
nothing" — a config with every line commented out evaluates to `{}` and must not wipe the
defaults. Over a list it means "clear it". Both directions are regression-tested.

⚠️ **The watcher hashes file contents rather than comparing mtimes**, because two saves inside one
filesystem clock tick are indistinguishable by mtime.

Validation is enforced, not advisory: font floor 18 dmm, focus distance 1.2–2.5 m, at most 7
tiles, a minimum clear radius, known backdrop modes only, and a missing custom `.glb` falls back
to the shipped backdrop.

## Testing without a headset

Most of this is verifiable on the host, and should be:

```bash
python3 -m unittest discover -s tests   # parser, diffing, config, key validation
python3 tools/keys-smoke.py             # drives the real WebSocket: subscribe, type,
                                        # read the text back out of a throwaway pane,
                                        # confirm a bad key name is refused, confirm
                                        # the window geometry is restored
```

What genuinely requires the device: sharpness, comfort, layout at distance, latency as felt, and
anything involving the compositor. Everything else has a way to be checked on the host — and a
lesson from this project's own history is worth repeating here: **when instrumentation and a
human disagree about what is on screen, believe the human.** A scripted edit that silently
matched nothing once produced telemetry that reported success while nothing was parented to the
rig at all.

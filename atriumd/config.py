"""User config: evaluate Lua on the host, validate, serve as JSON.

WezTerm's model. We ship an opinionated baseline (config/default.lua) and the
user overrides only what they want in ~/.config/atrium/config.lua.

⚠️ The Lua runs HERE, on the host — never in the headset. That keeps the Godot
client free of native dependencies (a Lua GDExtension would mean an Android NDK
build, which is exactly what this architecture removed), and it means saving the
file restyles the live panels without a rebuild or a reinstall.
"""

import hashlib
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LUA = os.path.join(ROOT, "vendor", "lua", "bin", "lua")
# In a checkout the Lua files live in <repo>/config; in an installed wheel they
# are packaged next to this module (pyproject force-includes them).
CONFIG_DIR = os.path.join(HERE, "config") if os.path.isdir(os.path.join(HERE, "config")) \
    else os.path.join(ROOT, "config")
LUAEVAL = os.path.join(HERE, "luaeval.py")


def _has_lupa():
    try:
        import lupa  # noqa: F401
        return True
    except ImportError:
        return False


def evaluator():
    """The command that evaluates config: the vendored binary when it was
    built (a checkout), otherwise lupa (a pip install). Same script, same JSON."""
    if os.path.exists(LUA):
        return [LUA, EVAL]
    if _has_lupa():
        import sys
        return [sys.executable, LUAEVAL]
    return None
EVAL = os.path.join(CONFIG_DIR, "eval.lua")

USER_CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "atrium", "config.lua",
)

BACKDROP_MODES = ("passthrough", "default", "custom")
MUSIC_MODES = ("procedural", "folder", "off")
REFRESH_RATES = (72, 90, 120)

# The legibility floor is a real limit, not a preference: below ~18 dmm text
# stops being comfortable to read for hours on a 25-PPD display.
FONT_DMM_MIN, FONT_DMM_MAX = 18.0, 60.0


def _clamp(v, lo, hi, default):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return default, True
    if v < lo:
        return lo, True
    if v > hi:
        return hi, True
    return v, False


class ConfigError(Exception):
    pass


def evaluate(user_path=None):
    """Run the Lua evaluator. Returns (config, warnings). Raises ConfigError."""
    if user_path is None:
        user_path = USER_CONFIG
    cmd = evaluator()
    if cmd is None:
        raise ConfigError("no Lua evaluator: pip install lupa, or run tools/build-lua.sh")

    arg = user_path if (user_path and os.path.exists(user_path)) else ""
    try:
        p = subprocess.run(
            cmd + [CONFIG_DIR, arg],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired:
        raise ConfigError("config evaluation timed out (infinite loop in config.lua?)")

    if p.returncode != 0:
        raise ConfigError((p.stderr or "lua exited %d" % p.returncode).strip())
    try:
        out = json.loads(p.stdout)
    except ValueError:
        raise ConfigError("config evaluator produced invalid JSON: %r" % p.stdout[:200])

    if not out.get("ok"):
        raise ConfigError(out.get("error", "unknown config error"))
    return out["config"], list(out.get("warnings", []))


def validate(cfg):
    """Clamp to physically sane values. Mutates cfg, returns a list of notes.

    The defaults file promises these limits are enforced rather than advisory,
    so this is where that promise is kept.
    """
    notes = []

    def note(msg):
        notes.append(msg)

    # ── font ────────────────────────────────────────────────────────────────
    font = cfg.setdefault("font", {})
    v, changed = _clamp(font.get("size_dmm"), FONT_DMM_MIN, FONT_DMM_MAX, 22.3)
    if changed:
        note("font.size_dmm clamped to %g (legible range is %g-%g dmm)"
             % (v, FONT_DMM_MIN, FONT_DMM_MAX))
    font["size_dmm"] = v

    # ── panels ──────────────────────────────────────────────────────────────
    panels = cfg.setdefault("panels", {})
    focus = panels.setdefault("focus", {})
    v, changed = _clamp(focus.get("distance_m"), 1.2, 2.5, 1.5)
    if changed:
        note("panels.focus.distance_m clamped to %g m (Quest 3 focal plane is ~1.3-1.5 m)" % v)
    focus["distance_m"] = v

    tile = panels.setdefault("tile", {})
    v, changed = _clamp(tile.get("distance_m"), 1.2, 4.0, 1.8)
    if changed:
        note("panels.tile.distance_m clamped to %g m" % v)
    tile["distance_m"] = v

    v, changed = _clamp(tile.get("max"), 0, 7, 7)
    if changed:
        note("panels.tile.max clamped to %d — 1 focus + 7 tiles is the layer budget" % int(v))
    tile["max"] = int(v)

    # Angular reality check: warn rather than clamp, since the user may
    # deliberately trade font size for columns.
    cols = focus.get("cols", 80)
    dmm = font["size_dmm"]
    deg_per_col = (dmm * 0.5) / 1000.0 * 180.0 / 3.141592653589793
    width_deg = cols * deg_per_col
    if width_deg > 70:
        note("panels.focus is %.0f deg wide at this font size — over ~70 deg you will be "
             "turning your head to read one line" % width_deg)

    # ── backdrop ────────────────────────────────────────────────────────────
    bd = cfg.setdefault("backdrop", {})
    mode = bd.get("mode")
    if mode not in BACKDROP_MODES:
        note("backdrop.mode %r is not one of %s — using 'passthrough'"
             % (mode, ", ".join(BACKDROP_MODES)))
        bd["mode"] = "passthrough"
    if bd.get("mode") == "custom":
        glb = (bd.get("custom") or {}).get("glb")
        if not glb:
            note("backdrop.mode is 'custom' but backdrop.custom.glb is unset — using 'default'")
            bd["mode"] = "default"
        elif not os.path.exists(glb):
            note("backdrop.custom.glb not found: %s — using 'default'" % glb)
            bd["mode"] = "default"

    custom = bd.setdefault("custom", {})
    v, changed = _clamp(custom.get("clear_radius_m"), 2.0, 10.0, 2.0)
    if changed:
        note("backdrop.custom.clear_radius_m raised to %g m — composition layers do not "
             "depth-sort, so closer geometry punches through your panels" % v)
    custom["clear_radius_m"] = v

    # ── glass ───────────────────────────────────────────────────────────────
    glass = cfg.setdefault("glass", {})
    for key, lo, hi, dflt in (("opacity", 0.0, 1.0, 0.38),
                              ("blur", 0.0, 1.0, 0.55),
                              ("saturation", 0.0, 3.0, 1.12),
                              ("inner_shadow", 0.0, 1.0, 0.25)):
        v, changed = _clamp(glass.get(key), lo, hi, dflt)
        if changed:
            note("glass.%s clamped to %g" % (key, v))
        glass[key] = v

    # ── comfort ─────────────────────────────────────────────────────────────
    comfort = cfg.setdefault("comfort", {})
    hz = comfort.get("refresh_hz")
    if hz not in REFRESH_RATES:
        note("comfort.refresh_hz %r unsupported — using 72 (valid: %s)"
             % (hz, ", ".join(str(r) for r in REFRESH_RATES)))
        comfort["refresh_hz"] = 72
    v, changed = _clamp(comfort.get("foveation"), 0, 4, 2)
    if changed:
        note("comfort.foveation clamped to %d" % int(v))
    comfort["foveation"] = int(v)

    # ── ambience ────────────────────────────────────────────────────
    amb = cfg.setdefault("ambience", {})
    v, changed = _clamp(amb.get("volume"), 0.0, 1.0, 0.10)
    if changed:
        note("ambience.volume clamped to %g" % v)
    amb["volume"] = v

    for layer, dflt in (("typing", 0.35), ("steam", 0.50), ("music", 0.50)):
        block = amb.setdefault(layer, {})
        if not isinstance(block, dict):
            note("ambience.%s must be a table — ignored" % layer)
            block = {}
            amb[layer] = block
        v, changed = _clamp(block.get("volume"), 0.0, 1.0, dflt)
        if changed:
            note("ambience.%s.volume clamped to %g" % (layer, v))
        block["volume"] = v

    steam = amb["steam"]
    lo, _ = _clamp(steam.get("every_min_s"), 5.0, 1800.0, 60.0)
    hi, _ = _clamp(steam.get("every_max_s"), 5.0, 1800.0, 180.0)
    if lo > hi:
        note("ambience.steam.every_min_s > every_max_s — swapped")
        lo, hi = hi, lo
    steam["every_min_s"], steam["every_max_s"] = lo, hi

    lo, _ = _clamp(steam.get("length_min_s"), 0.5, 15.0, 2.0)
    hi, _ = _clamp(steam.get("length_max_s"), 0.5, 15.0, 4.0)
    if lo > hi:
        note("ambience.steam.length_min_s > length_max_s — swapped")
        lo, hi = hi, lo
    steam["length_min_s"], steam["length_max_s"] = lo, hi

    music = amb["music"]
    if music.get("mode") not in MUSIC_MODES:
        note("ambience.music.mode %r is not one of %s — using 'procedural'"
             % (music.get("mode"), ", ".join(MUSIC_MODES)))
        music["mode"] = "procedural"
    # ⚠️ music.dir is a path on the DEVICE running the client, not on this host,
    # so there is nothing here to check it against — only its type.
    if not isinstance(music.get("dir"), str):
        music["dir"] = ""
    if music["mode"] == "folder" and not music["dir"]:
        note("ambience.music.mode is 'folder' but ambience.music.dir is unset — "
             "using 'procedural'")
        music["mode"] = "procedural"

    # ── sessions ────────────────────────────────────────────────────────────
    sess = cfg.setdefault("sessions", {})
    v, changed = _clamp(sess.get("max_panels"), 1, 8, 8)
    if changed:
        note("sessions.max_panels clamped to %d (Meta's layer budget)" % int(v))
    sess["max_panels"] = int(v)
    pe = sess.get("pin_exclude")
    if pe is None or isinstance(pe, dict) and not pe:
        pe = []
    if not isinstance(pe, list):
        note("sessions.pin_exclude must be a list of patterns — ignored")
        pe = []
    bad = [x for x in pe if not isinstance(x, str)]
    if bad:
        note("sessions.pin_exclude: %d non-string entries ignored" % len(bad))
    sess["pin_exclude"] = [x for x in pe if isinstance(x, str)]

    return notes


class ConfigWatcher:
    """Holds the current config and reloads it when a file changes on disk."""

    def __init__(self, user_path=None):
        self.user_path = user_path or USER_CONFIG
        self.watch = [os.path.join(CONFIG_DIR, "default.lua"),
                      os.path.join(CONFIG_DIR, "xr.lua"),
                      self.user_path]
        self._stamps = None
        self.config = None
        self.warnings = []
        self.error = None
        self.rev = 0
        self.reload()

    def _stamp(self):
        """Content hashes, not mtimes.

        ⚠️ mtime alone is not enough: two edits inside one filesystem clock tick
        report an identical mtime, so a save can be silently missed. The files
        are a few KB and we poll once a second, so hashing is free and exact.
        """
        out = []
        for p in self.watch:
            try:
                with open(p, "rb") as f:
                    out.append(hashlib.sha256(f.read()).hexdigest())
            except OSError:
                out.append("")
        return tuple(out)

    def reload(self):
        """Re-evaluate. On failure keep the last good config and record why."""
        self._stamps = self._stamp()
        try:
            cfg, warnings = evaluate(self.user_path)
        except ConfigError as e:
            self.error = str(e)
            if self.config is None:
                # Cannot even load defaults — the caller decides what to do.
                raise
            return False
        warnings.extend(validate(cfg))
        self.config = cfg
        self.warnings = warnings
        self.error = None
        self.rev += 1
        return True

    def poll(self):
        """Reload if any watched file changed. Returns True if config changed."""
        if self._stamp() != self._stamps:
            return self.reload()
        return False

    def frame(self):
        return {
            "type": "config",
            "rev": self.rev,
            "source": self.user_path if os.path.exists(self.user_path) else None,
            "warnings": self.warnings,
            "error": self.error,
            "config": self.config,
        }

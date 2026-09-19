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
import re
import subprocess

import schemes
import settings as _settings

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
    fam = font.get("family")
    if not isinstance(fam, str) or not fam.strip():
        fam = "Iosevka Term Medium"
    key = fam.lower().replace(" ", "")
    if "jetbrains" not in key and "iosevka" not in key:
        note("font.family %r is not bundled (Iosevka Term, JetBrainsMono Nerd Font) — "
             "using Iosevka Term" % fam)
        fam = "Iosevka Term Medium"
    font["family"] = fam
    v, changed = _clamp(font.get("line_height"), 1.0, 2.0, 1.25)
    if changed:
        note("font.line_height clamped to %g" % v)
    font["line_height"] = v

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

    pt = bd.setdefault("passthrough", {})
    pt["desk_window"] = bool(pt.get("desk_window", False))
    sz = pt.get("desk_window_size_m")
    if not (isinstance(sz, list) and len(sz) == 2
            and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in sz)):
        sz = [1.2, 0.6]
    pt["desk_window_size_m"] = [min(max(float(sz[0]), 0.3), 2.0), min(max(float(sz[1]), 0.2), 1.2)]
    for key, lo, hi, dflt in (("desk_window_pitch_deg", -90.0, 0.0, -35.0),
                              ("desk_window_forward_m", 0.2, 1.0, 0.45),
                              ("desk_window_below_eye_m", 0.1, 0.9, 0.40)):
        v, changed = _clamp(pt.get(key), lo, hi, dflt)
        if changed:
            note("backdrop.passthrough.%s clamped to %g" % (key, v))
        pt[key] = v

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
        comfort["refresh_hz"] = 120
    v, changed = _clamp(comfort.get("foveation"), 0, 4, 0)
    if changed:
        note("comfort.foveation clamped to %d" % int(v))
    comfort["foveation"] = int(v)

    # ── pointer ─────────────────────────────────────────────────────────────
    ptr = cfg.setdefault("pointer", {})
    if not isinstance(ptr, dict):
        note("pointer must be a table — using defaults")
        ptr = {}
        cfg["pointer"] = ptr
    for key in ("enabled", "select", "drag", "scroll", "show_ray", "hands"):
        v = ptr.get(key, True)
        if not isinstance(v, bool):
            note("pointer.%s must be true/false — using true" % key)
            v = True
        ptr[key] = v
    if ptr.get("hand") not in ("right", "left", "both"):
        note("pointer.hand %r is not right/left/both — using 'right'" % ptr.get("hand"))
        ptr["hand"] = "right"
    v, changed = _clamp(ptr.get("scroll_lines_per_s"), 2.0, 60.0, 14.0)
    if changed:
        note("pointer.scroll_lines_per_s clamped to %g" % v)
    ptr["scroll_lines_per_s"] = v
    v, changed = _clamp(comfort.get("typing_lockout_ms"), 0, 5000, 1500)
    if changed:
        note("comfort.typing_lockout_ms clamped to %d" % int(v))
    comfort["typing_lockout_ms"] = int(v)

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

    # ── browser ─────────────────────────────────────────────────────────────
    br = cfg.get("browser")
    if not isinstance(br, dict):
        note("browser must be a table — using defaults")
        br = {}
    cfg["browser"] = br
    br["enabled"] = br.get("enabled", True) is not False
    for layout, (dw, dh, ds) in (("desktop", (1280, 800, 1.0)), ("mobile", (430, 860, 2.0))):
        lay = br.get(layout)
        if not isinstance(lay, dict):
            lay = {}
        w, _ = _clamp(lay.get("width"), 320, 3840, dw)
        h, _ = _clamp(lay.get("height"), 320, 3840, dh)
        sc, changed = _clamp(lay.get("scale"), 1.0, 3.0, ds)
        if changed:
            note("browser.%s.scale clamped to %g" % (layout, sc))
        br[layout] = {"width": int(w), "height": int(h), "scale": sc}
    v, _ = _clamp(br.get("fps"), 1, 30, 15)
    br["fps"] = int(v)
    v, _ = _clamp(br.get("quality"), 30, 95, 70)
    br["quality"] = int(v)
    if not isinstance(br.get("profile_dir"), str) or not br["profile_dir"].strip():
        br["profile_dir"] = "~/.local/share/atrium/browser"
    apps, names = [], set()
    raw = br.get("apps")
    if isinstance(raw, dict) and not raw:
        raw = []
    if not isinstance(raw, list):
        note("browser.apps must be a list — ignored")
        raw = []
    for i, a in enumerate(raw, 1):
        if not isinstance(a, dict):
            note("browser.apps[%d] must be a table — ignored" % i)
            continue
        name, url = a.get("name"), a.get("url")
        if not isinstance(name, str) or not re.match(r"^[A-Za-z0-9_.-]{1,40}$", name):
            note("browser.apps[%d].name %r must be letters/digits/._- — ignored" % (i, name))
            continue
        if name in names:
            note("browser.apps: duplicate name %r — ignored" % name)
            continue
        if not isinstance(url, str) or not re.match(r"^https?://", url):
            note("browser.apps[%d] (%s): url must start with http:// or https:// — ignored"
                 % (i, name))
            continue
        layout = a.get("layout", "desktop")
        if layout not in ("desktop", "mobile"):
            note("browser.apps[%d] (%s): layout %r is not desktop/mobile — using desktop"
                 % (i, name, layout))
            layout = "desktop"
        names.add(name)
        app = {"name": name, "url": url, "layout": layout}
        if isinstance(a.get("title"), str):
            app["title"] = a["title"]
        apps.append(app)
    br["apps"] = apps

    # ── colours (WezTerm-shaped: color_scheme + colors) ─────────────────────
    notes.extend(schemes.resolve(cfg))

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
    if sess.get("pin_mode") not in ("resize", "follow"):
        note("sessions.pin_mode %r is not 'resize' or 'follow' — using 'resize'"
             % sess.get("pin_mode"))
        sess["pin_mode"] = "resize"
    new = sess.get("new")
    if not isinstance(new, dict):
        note("sessions.new must be a table — using defaults")
        new = {}
    new["enabled"] = new.get("enabled", True) is not False
    for key, dflt in (("command", "claude"), ("prefix", "cc"), ("cwd", "~")):
        if not isinstance(new.get(key), str) or not new.get(key).strip():
            new[key] = dflt
    if not re.match(r"^[A-Za-z0-9_.-]{1,40}$", new["prefix"]):
        note("sessions.new.prefix %r is not a valid tmux session name — using 'cc'" % new["prefix"])
        new["prefix"] = "cc"
    sess["new"] = new

    return notes


class ConfigWatcher:
    """Holds the current config and reloads it when a file changes on disk."""

    def __init__(self, user_path=None):
        self.user_path = user_path or USER_CONFIG
        self.watch = [os.path.join(CONFIG_DIR, "default.lua"),
                      os.path.join(CONFIG_DIR, "xr.lua"),
                      self.user_path,
                      _settings.path_for(self.user_path)]
        self._stamps = None
        self.overrides = {}
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
            self.overrides = _settings.apply(cfg, _settings.load(_settings.path_for(self.user_path)))
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
            # The ⚙ panel: what it can set, and which of those the panel owns.
            "settings": {"schema": _settings.schema(), "overrides": self.overrides},
        }

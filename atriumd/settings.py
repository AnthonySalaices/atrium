"""Settings changed from inside the headset.

The headset's ⚙ panel never touches config.lua — that file belongs to the user
(see confedit.py). Changes land in `settings.json` next to it, and the daemon
lays them over the evaluated Lua before validation, so:

    shipped defaults  <  config.lua  <  settings.json (the panel)

A "reset" on a row deletes its key here and the Lua value shows through again.
The file is plain JSON, one dotted path per key, so a person can read it and
delete a line by hand.

The panel itself is drawn from SCHEMA, which the daemon sends with every config
frame. The headset knows nothing about individual settings: a row is a label, a
config path and the values it may take. Adding a setting is a host-side edit.
"""

import json
import os
import tempfile

import schemes

# Scene presets that need a room GLB in the APK. The headset hides a scene whose
# GLB is not in its build, so a scene can be listed here before it ships.
SCENES = (
    ("Café · day", {"backdrop.mode": "default", "backdrop.default.preset": "cafe"}),
    ("Café · night", {"backdrop.mode": "default", "backdrop.default.preset": "cafe-night"}),
    ("Lookout cabin", {"backdrop.mode": "default", "backdrop.default.preset": "cabin"}),
    ("Library", {"backdrop.mode": "default", "backdrop.default.preset": "library"}),
    ("Palace · lawn", {"backdrop.mode": "default", "backdrop.default.preset": "palace-lawn"}),
    ("Palace · rotunda", {"backdrop.mode": "default", "backdrop.default.preset": "palace-rotunda"}),
    ("Golden Gate · fog", {"backdrop.mode": "default", "backdrop.default.preset": "golden-gate"}),
    ("Twin Peaks · night", {"backdrop.mode": "default", "backdrop.default.preset": "twin-peaks"}),
    ("Painted Ladies", {"backdrop.mode": "default", "backdrop.default.preset": "painted-ladies"}),
    ("Night sky", {"backdrop.mode": "default", "backdrop.default.preset": "nebula"}),
    ("Void", {"backdrop.mode": "default", "backdrop.default.preset": "void"}),
    ("Passthrough", {"backdrop.mode": "passthrough"}),
)

_ON_OFF = [{"label": "on", "set": True}, {"label": "off", "set": False}]


def _choice(key, label, path, options):
    return {"id": key, "label": label, "kind": "choice",
            "options": [{"label": o["label"], "set": {path: o["set"]}} for o in options]}


def _step(key, label, path, lo, hi, step, unit=""):
    """unit "%" = shown as a percentage of 1.0; anything else is appended."""
    return {"id": key, "label": label, "kind": "step", "path": path,
            "min": lo, "max": hi, "step": step, "unit": unit}


def schema():
    """The rows of the ⚙ panel, grouped (one tab each). Built per call so new
    colour schemes show up without a daemon restart.

    ⛔ Only keys something actually READS. A switch that does nothing is worse
    than no switch — check the client/daemon before adding a row."""
    return [
        {"group": "Scene", "rows": [
            {"id": "scene", "label": "Scene", "kind": "choice",
             "options": [{"label": lbl, "set": dict(s),
                          "preset": s.get("backdrop.default.preset", "")}
                         for lbl, s in SCENES]},
            _step("dim", "Dim", "backdrop.default.dim", 0.0, 0.8, 0.1, "%"),
        ]},
        {"group": "Keyboard", "rows": [
            _choice("kbd", "Keyboard view", "backdrop.passthrough.desk_window", _ON_OFF),
            _choice("kbd_size", "Size", "backdrop.passthrough.desk_window_size_m",
                    [{"label": "keyboard", "set": [0.45, 0.18]},
                     {"label": "small", "set": [0.55, 0.24]},
                     {"label": "medium", "set": [0.7, 0.3]},
                     {"label": "large", "set": [0.95, 0.42]}]),
            _step("kbd_fwd", "Distance", "backdrop.passthrough.desk_window_forward_m",
                  0.2, 1.0, 0.05, " m"),
            _step("kbd_below", "Height", "backdrop.passthrough.desk_window_below_eye_m",
                  0.1, 0.9, 0.05, " m below eyes"),
            _step("kbd_pitch", "Tilt", "backdrop.passthrough.desk_window_pitch_deg",
                  -90.0, 0.0, 5.0, "°"),
        ]},
        {"group": "Look", "rows": [
            _choice("scheme", "Colours", "color_scheme",
                    [{"label": n, "set": n} for n in schemes.SCHEMES]),
            _choice("font", "Font", "font.family",
                    [{"label": "JetBrains Mono", "set": "JetBrainsMono Nerd Font"},
                     {"label": "Iosevka Term", "set": "Iosevka Term Medium"}]),
            _step("text", "Text size", "font.size_dmm", 18.0, 40.0, 1.0, " dmm"),
            _step("lh", "Line spacing", "font.line_height", 1.0, 2.0, 0.05, "×"),
            _choice("cursor", "Cursor", "default_cursor_style",
                    [{"label": lbl, "set": v} for lbl, v in (
                        ("block", "SteadyBlock"), ("block, blinking", "BlinkingBlock"),
                        ("bar", "SteadyBar"), ("bar, blinking", "BlinkingBar"),
                        ("underline", "SteadyUnderline"),
                        ("underline, blinking", "BlinkingUnderline"))]),
            _choice("pulse", "Attention pulse", "glow.states.needs_input.pulse",
                    [{"label": "breathe", "set": "breathe"}, {"label": "steady", "set": "none"}]),
        ]},
        {"group": "Window", "rows": [
            _step("dist", "Distance", "panels.focus.distance_m", 1.2, 2.5, 0.1, " m"),
            _step("pitch", "Tilt", "panels.focus.pitch_deg", -30.0, 10.0, 2.0, "°"),
            _step("cols", "Columns", "panels.focus.cols", 60, 200, 10, ""),
            _step("rows", "Rows", "panels.focus.rows", 16, 60, 2, ""),
            _choice("pin", "Pane size", "sessions.pin_mode",
                    [{"label": "follow", "set": "follow"}, {"label": "resize", "set": "resize"}]),
        ]},
        {"group": "Input", "rows": [
            _choice("hands", "Hand tracking", "pointer.hands", _ON_OFF),
            _choice("hand", "Pointing hand", "pointer.hand",
                    [{"label": v, "set": v} for v in ("right", "left", "both")]),
            _choice("ray", "Show ray", "pointer.show_ray", _ON_OFF),
            _choice("drag", "Grab windows", "pointer.drag", _ON_OFF),
            _step("scroll", "Scroll speed", "pointer.scroll_lines_per_s", 2, 60, 2, " lines/s"),
            _step("lock", "Typing lockout", "comfort.typing_lockout_ms", 0, 5000, 250, " ms"),
        ]},
        {"group": "Sound", "rows": [
            _choice("ambience", "Room sound", "ambience.enabled", _ON_OFF),
            _step("volume", "Volume", "ambience.volume", 0.0, 1.0, 0.05, "%"),
            _choice("clicks", "Typing clicks", "ambience.typing.enabled", _ON_OFF),
            _choice("steam", "Steam wand", "ambience.steam.enabled", _ON_OFF),
            _choice("music", "Music", "ambience.music.mode",
                    [{"label": "pad", "set": "procedural"}, {"label": "off", "set": "off"}]),
            _step("mvol", "Music volume", "ambience.music.volume", 0.0, 1.0, 0.05, "%"),
        ]},
        {"group": "More", "rows": [
            _choice("hz", "Refresh rate", "comfort.refresh_hz",
                    [{"label": "%d Hz" % v, "set": v} for v in (72, 90, 120)]),
            _step("fov", "Foveation", "comfort.foveation", 0, 4, 1, ""),
            _step("wfps", "Web fps", "browser.fps", 5, 30, 5, ""),
            _step("wq", "Web quality", "browser.quality", 30, 95, 5, ""),
        ]},
    ]


def _allowed(sch):
    """{path: ("choice", [values]) | ("step", lo, hi)} for every settable path."""
    out = {}
    for g in sch:
        for r in g["rows"]:
            if r["kind"] == "step":
                ints = all(isinstance(r[k], int) for k in ("min", "max", "step"))
                out[r["path"]] = ("step", r["min"], r["max"], ints)
            else:
                for o in r["options"]:
                    for p, v in o["set"].items():
                        out.setdefault(p, ("choice", []))[1].append(v)
    return out


def path_for(user_config):
    return os.path.join(os.path.dirname(user_config), "settings.json")


def load(path):
    """The saved overrides, {dotted.path: value}. A broken file is ignored
    (never fatal — the Lua config still loads)."""
    try:
        with open(path) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in d.items() if isinstance(k, str)} if isinstance(d, dict) else {}


def _save(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.")
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def check(values, sch=None):
    """Validate {path: value}. Returns the cleaned dict, or raises ValueError."""
    allowed = _allowed(sch or schema())
    out = {}
    for p, v in values.items():
        rule = allowed.get(p)
        if rule is None:
            raise ValueError("%s is not a panel setting" % p)
        if rule[0] == "step":
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                raise ValueError("%s wants a number" % p)
            v = round(min(max(float(v), rule[1]), rule[2]), 4)
            if rule[3]:
                v = int(round(v))      # columns, rows, ms, fps: never 90.0
        elif v not in rule[1]:
            raise ValueError("%s cannot be %r" % (p, v))
        out[p] = v
    return out


def update(path, values):
    """Merge validated {dotted.path: value} into the file. Returns the new dict."""
    d = load(path)
    d.update(check(values))
    _save(path, d)
    return d


def reset(path, keys=None):
    """Drop some keys (or all of them) so config.lua shows through again."""
    d = load(path)
    if keys is None:
        d = {}
    else:
        for k in keys:
            d.pop(k, None)
    _save(path, d)
    return d


def apply(cfg, overrides):
    """Lay the overrides over an evaluated config, in place. Unknown paths are
    skipped, so a stale settings.json cannot inject arbitrary keys."""
    try:
        good = check(overrides)
    except ValueError:
        good = {}
        for p, v in overrides.items():
            try:
                good.update(check({p: v}))
            except ValueError:
                pass
    for p, v in good.items():
        node = cfg
        parts = p.split(".")
        for k in parts[:-1]:
            nxt = node.get(k)
            if not isinstance(nxt, dict):
                nxt = node[k] = {}
            node = nxt
        node[parts[-1]] = v
        if p == "color_scheme":
            # A scheme picked in the panel beats any `colors` table in the Lua,
            # or picking one would appear to do nothing.
            cfg.pop("colors", None)
    return good

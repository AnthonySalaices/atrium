"""Terminal colours, WezTerm-shaped.

A WezTerm `colors = {...}` table pastes straight into an Atrium config, and
`color_scheme = "name"` picks one of the built-ins below. Both resolve HERE, on
the host, into one flat table the headset paints with — the client never learns
what a scheme is.

⚠️ Only the palette-indexed colours change. A program that emits truecolor
(38;2;r;g;b) paints exactly what it asked for, same as in WezTerm.
"""

import re

# 16 ANSI colours are ansi[0..7] + brights[0..7], as in WezTerm.
SCHEMES = {
    # The look Atrium shipped with: the frame's own body colour behind the text.
    "atrium": {
        "foreground": "#e0e5ec", "background": "#101922",
        "cursor_bg": "#e0e5ec", "cursor_fg": "#101922", "cursor_border": "#e0e5ec",
        "ansi": ["#000000", "#cd3131", "#0dbc79", "#e5e510",
                 "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5"],
        "brights": ["#666666", "#f14c4c", "#23d18b", "#f5f543",
                    "#3b8eea", "#d670d6", "#29b8db", "#ffffff"],
    },
    "rose-pine-moon": {
        "foreground": "#e0def4", "background": "#232136",
        "cursor_bg": "#59546d", "cursor_fg": "#e0def4", "cursor_border": "#59546d",
        "ansi": ["#393552", "#eb6f92", "#3e8fb0", "#f6c177",
                 "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4"],
        "brights": ["#6e6a86", "#eb6f92", "#3e8fb0", "#f6c177",
                    "#9ccfd8", "#c4a7e7", "#ea9a97", "#e0def4"],
    },
    "Catppuccin Mocha": {
        "foreground": "#cdd6f4", "background": "#1e1e2e",
        "cursor_bg": "#f5e0dc", "cursor_fg": "#11111b", "cursor_border": "#f5e0dc",
        "ansi": ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af",
                 "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de"],
        "brights": ["#585b70", "#f38ba8", "#a6e3a1", "#f9e2af",
                    "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"],
    },
    "Dracula": {
        "foreground": "#f8f8f2", "background": "#282a36",
        "cursor_bg": "#f8f8f2", "cursor_fg": "#282a36", "cursor_border": "#f8f8f2",
        "ansi": ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                 "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2"],
        "brights": ["#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                    "#d6acff", "#ff92df", "#a4ffff", "#ffffff"],
    },
    "Tokyo Night": {
        "foreground": "#c0caf5", "background": "#1a1b26",
        "cursor_bg": "#c0caf5", "cursor_fg": "#1a1b26", "cursor_border": "#c0caf5",
        "ansi": ["#15161e", "#f7768e", "#9ece6a", "#e0af68",
                 "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6"],
        "brights": ["#414868", "#f7768e", "#9ece6a", "#e0af68",
                    "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"],
    },
}

SINGLE_KEYS = ("foreground", "background", "cursor_bg", "cursor_fg", "cursor_border")
# Real WezTerm keys Atrium has no surface for. Accepted silently so a table
# copied out of a .wezterm.lua does not drown the user in warnings.
WEZTERM_ONLY = {"tab_bar", "selection_fg", "selection_bg", "scrollbar_thumb", "split",
                "compose_cursor", "visual_bell", "copy_mode_active_highlight_bg",
                "copy_mode_active_highlight_fg", "copy_mode_inactive_highlight_bg",
                "copy_mode_inactive_highlight_fg", "quick_select_label_bg",
                "quick_select_label_fg", "quick_select_match_bg", "quick_select_match_fg",
                "input_selector_label_bg", "input_selector_label_fg", "launcher_label_bg",
                "launcher_label_fg"}

CURSOR_STYLES = ("SteadyBlock", "BlinkingBlock", "SteadyUnderline", "BlinkingUnderline",
                 "SteadyBar", "BlinkingBar")

_HEX = re.compile(r"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")


def _lookup(name):
    """Scheme names match case-insensitively, the way people type them."""
    if name in SCHEMES:
        return SCHEMES[name]
    low = str(name).lower()
    for k, v in SCHEMES.items():
        if k.lower() == low:
            return v
    return None


def color(v):
    """"#rgb" / "#rrggbb" / "#rrggbbaa" or an xr.hex / {r,g,b} list -> "#rrggbb",
    or None if it is not a colour. Alpha is dropped: a terminal cell is opaque."""
    if isinstance(v, str):
        m = _HEX.match(v.strip())
        if not m:
            return None
        h = m.group(1)
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        return "#" + h[:6].lower()
    if isinstance(v, (list, tuple)) and len(v) in (3, 4) \
            and all(isinstance(x, (int, float)) for x in v):
        return "#" + "".join("%02x" % int(round(max(0.0, min(1.0, float(x))) * 255))
                             for x in v[:3])
    return None


def resolve(cfg):
    """Replace cfg["colors"] with the full resolved table. Returns notes."""
    notes = []
    name = cfg.get("color_scheme") or "atrium"
    base = _lookup(name)
    if base is None:
        notes.append("color_scheme %r is not built in (have: %s) — using 'atrium'"
                     % (name, ", ".join(SCHEMES)))
        base = SCHEMES["atrium"]
        name = "atrium"
    cfg["color_scheme"] = name

    out = {k: base[k] for k in SINGLE_KEYS}
    out["ansi"] = list(base["ansi"])
    out["brights"] = list(base["brights"])
    out["indexed"] = {}

    over = cfg.get("colors")
    if over is None or over == [] or over == {}:
        over = {}
    if not isinstance(over, dict):
        notes.append("colors must be a table — ignored")
        over = {}

    for k, v in over.items():
        if k in SINGLE_KEYS:
            c = color(v)
            if c is None:
                notes.append("colors.%s: %r is not a colour — ignored" % (k, v))
            else:
                out[k] = c
        elif k in ("ansi", "brights"):
            if not isinstance(v, list):
                notes.append("colors.%s must be a list of 8 colours — ignored" % k)
                continue
            for i, x in enumerate(v[:8]):
                c = color(x)
                if c is None:
                    notes.append("colors.%s[%d]: %r is not a colour — ignored" % (k, i + 1, x))
                else:
                    out[k][i] = c
        elif k == "indexed":
            # Lua { [16] = "#..." } arrives as a JSON object with string keys, or
            # as a list when the indices happen to start at 1.
            items = v.items() if isinstance(v, dict) else \
                enumerate(v, 1) if isinstance(v, list) else []
            for idx, x in items:
                try:
                    n = int(idx)
                except (TypeError, ValueError):
                    n = -1
                c = color(x)
                if not 0 <= n <= 255 or c is None:
                    notes.append("colors.indexed[%s] ignored (index 0-255, colour value)" % idx)
                else:
                    out["indexed"][str(n)] = c
        elif k in WEZTERM_ONLY:
            pass
        else:
            notes.append("unknown config key: colors.%s" % k)
    cfg["colors"] = out

    style = cfg.get("default_cursor_style") or "SteadyBlock"
    if style not in CURSOR_STYLES:
        notes.append("default_cursor_style %r is not one of %s — using 'SteadyBlock'"
                     % (style, ", ".join(CURSOR_STYLES)))
        style = "SteadyBlock"
    cfg["default_cursor_style"] = style
    try:
        rate = int(cfg.get("cursor_blink_rate", 800))
    except (TypeError, ValueError):
        rate = 800
    cfg["cursor_blink_rate"] = max(0, min(rate, 5000))   # WezTerm: 0 = never blink
    return notes

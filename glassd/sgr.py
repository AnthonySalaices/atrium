"""SGR escape parser.

NOT a VT parser. tmux already did that — `capture-pane -p -e -N` hands us an
already-rendered cell grid whose only escapes are SGR (colour/attribute) ones.
This module turns one such line into styled runs.

A run is [fg, bg, attrs, text] where fg/bg are -1 for "terminal default",
0..255 for palette colours, or 0x1000000|rgb for truecolor.
"""

import unicodedata

# attribute bits
BOLD = 1
DIM = 2
ITALIC = 4
UNDERLINE = 8
REVERSE = 16
STRIKE = 32

DEFAULT = -1
RGB_FLAG = 0x1000000


def char_width(ch):
    """Display cells occupied by ch. Zero-width marks -> 0, wide CJK/emoji -> 2."""
    if unicodedata.combining(ch):
        return 0
    cat = unicodedata.category(ch)
    if cat in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def str_width(s):
    return sum(char_width(c) for c in s)


class Style:
    __slots__ = ("fg", "bg", "attrs")

    def __init__(self, fg=DEFAULT, bg=DEFAULT, attrs=0):
        self.fg = fg
        self.bg = bg
        self.attrs = attrs

    def copy(self):
        return Style(self.fg, self.bg, self.attrs)

    def key(self):
        return (self.fg, self.bg, self.attrs)

    def reset(self):
        self.fg = DEFAULT
        self.bg = DEFAULT
        self.attrs = 0


def _apply_params(style, params):
    """Apply one SGR parameter list to style, in place."""
    i = 0
    n = len(params)
    while i < n:
        p = params[i]
        if p == 0:
            style.reset()
        elif p == 1:
            style.attrs |= BOLD
        elif p == 2:
            style.attrs |= DIM
        elif p == 3:
            style.attrs |= ITALIC
        elif p == 4:
            style.attrs |= UNDERLINE
        elif p == 7:
            style.attrs |= REVERSE
        elif p == 9:
            style.attrs |= STRIKE
        elif p == 21 or p == 22:
            style.attrs &= ~(BOLD | DIM)
        elif p == 23:
            style.attrs &= ~ITALIC
        elif p == 24:
            style.attrs &= ~UNDERLINE
        elif p == 27:
            style.attrs &= ~REVERSE
        elif p == 29:
            style.attrs &= ~STRIKE
        elif 30 <= p <= 37:
            style.fg = p - 30
        elif p == 38 or p == 48:
            # extended colour: 5;N (palette) or 2;r;g;b (truecolor)
            if i + 1 < n and params[i + 1] == 5:
                if i + 2 < n:
                    col = params[i + 2]
                    if style_is_fg(p):
                        style.fg = col
                    else:
                        style.bg = col
                i += 2
            elif i + 1 < n and params[i + 1] == 2:
                if i + 4 < n:
                    r, g, b = params[i + 2], params[i + 3], params[i + 4]
                    col = RGB_FLAG | ((r & 255) << 16) | ((g & 255) << 8) | (b & 255)
                    if style_is_fg(p):
                        style.fg = col
                    else:
                        style.bg = col
                i += 4
        elif p == 39:
            style.fg = DEFAULT
        elif 40 <= p <= 47:
            style.bg = p - 40
        elif p == 49:
            style.bg = DEFAULT
        elif 90 <= p <= 97:
            style.fg = p - 90 + 8
        elif 100 <= p <= 107:
            style.bg = p - 100 + 8
        # anything else (fonts, framing, ideogram attrs) is ignored on purpose
        i += 1


def style_is_fg(p):
    return p == 38


def parse_line(line, cols, style=None):
    """Parse one capture-pane line into (runs, end_style).

    runs is a list of [fg, bg, attrs, text]. The run widths always sum to
    exactly `cols`: tmux -N pads with spaces, but a line carrying wide glyphs
    or a trailing escape can still come up short or long, so we enforce it.
    end_style carries SGR state into the next line (tmux does not re-emit it).
    """
    st = style.copy() if style else Style()
    runs = []
    cur = st.key()
    buf = []
    width = 0

    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        if ch == "\x1b":
            # only CSI ... m is expected; skip any other CSI cleanly
            if i + 1 < n and line[i + 1] == "[":
                j = i + 2
                while j < n and not ("@" <= line[j] <= "~"):
                    j += 1
                if j < n:
                    body = line[i + 2:j]
                    final = line[j]
                    if final == "m":
                        params = []
                        for part in body.split(";"):
                            if part == "":
                                params.append(0)
                            else:
                                try:
                                    params.append(int(part))
                                except ValueError:
                                    params.append(0)
                        if not params:
                            params = [0]
                        _apply_params(st, params)
                        newkey = st.key()
                        if newkey != cur:
                            if buf:
                                runs.append([cur[0], cur[1], cur[2], "".join(buf)])
                                buf = []
                            cur = newkey
                    i = j + 1
                    continue
                # unterminated escape: drop the rest of the line
                break
            i += 1
            continue

        w = char_width(ch)
        if width + w > cols:
            break
        buf.append(ch)
        width += w
        i += 1

    if buf:
        runs.append([cur[0], cur[1], cur[2], "".join(buf)])

    if width < cols:
        runs.append([DEFAULT, DEFAULT, 0, " " * (cols - width)])

    if not runs:
        runs = [[DEFAULT, DEFAULT, 0, " " * cols]]

    return runs, st


def runs_width(runs):
    return sum(str_width(r[3]) for r in runs)


def runs_to_text(runs):
    return "".join(r[3] for r in runs)

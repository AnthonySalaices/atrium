"""Small, surgical edits to the user's own config.lua.

⛔ **This file belongs to the user.** `atrium preset` and `atrium pack`
change exactly the keys they name and leave every comment, every other block and
all of the formatting alone. A config tool that reformats the file people
hand-edit is a config tool people stop using — and this one is optional sugar
over "open the file and type", which stays the primary path.

The Lua here is not parsed, it is *located*: a mask marks which characters are
real code (not inside a comment or a string), and every search and brace match
only ever looks at those. That is enough to find `backdrop = { ... }`, to find a
key at the top level of that block, and to leave everything else untouched.
"""

import re


def code_mask(text):
    """A bool per character: True where it is code, False in comments/strings.

    Handles `--` line comments, `--[[ ]]` block comments, and both quote styles
    with backslash escapes. Long strings (`[[ ]]`) outside a comment are not
    used by any config we ship and are treated as code — they would only matter
    if someone put a brace inside one.
    """
    mask = [True] * len(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "-" and text.startswith("--", i):
            if text.startswith("--[[", i):
                end = text.find("]]", i + 4)
                end = n if end < 0 else end + 2
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            for j in range(i, end):
                mask[j] = False
            i = end
            continue
        if c in "\"'":
            quote = c
            mask[i] = False
            i += 1
            while i < n:
                if text[i] == "\\":
                    mask[i] = False
                    if i + 1 < n:
                        mask[i + 1] = False
                    i += 2
                    continue
                if text[i] == quote:
                    mask[i] = False
                    i += 1
                    break
                mask[i] = False
                i += 1
            continue
        i += 1
    return mask


def find_block(text, key, span=None, mask=None):
    """(open_brace, close_brace) for `key = { ... }`, or None.

    `span` limits the search; `open_brace` is the index of `{` and
    `close_brace` the index of the matching `}`.
    """
    mask = code_mask(text) if mask is None else mask
    lo, hi = span or (0, len(text))
    for m in re.finditer(r"\b%s\s*=\s*\{" % re.escape(key), text):
        if m.start() < lo or m.end() > hi:
            continue
        if not all(mask[i] for i in range(m.start(), m.end())):
            continue          # the key is mentioned in a comment
        open_at = m.end() - 1
        depth = 0
        for i in range(open_at, hi):
            if not mask[i]:
                continue
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    return open_at, i
        return None
    return None


def _top_level_key(text, key, open_at, close_at, mask):
    """Match object for `key = <value>` directly inside a block, or None."""
    depth = 0
    for m in re.finditer(r"\b%s\s*=" % re.escape(key), text):
        if m.start() <= open_at or m.end() >= close_at:
            continue
        if not all(mask[i] for i in range(m.start(), m.end())):
            continue
        depth = 0
        for i in range(open_at + 1, m.start()):
            if not mask[i]:
                continue
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
        if depth == 0:
            return m
    return None


def _indent_of(text, open_at):
    line_start = text.rfind("\n", 0, open_at) + 1
    lead = re.match(r"[ \t]*", text[line_start:]).group(0)
    return lead + "  "


def set_string(text, key, value, block=None):
    """Set `key = "value"` inside `block` (or at the top level of the table).

    Replaces the existing assignment if there is one, otherwise inserts it just
    after the block's opening brace with the surrounding indentation.
    """
    mask = code_mask(text)
    if block is None:
        block = _root_table(text, mask)
        if block is None:
            raise ValueError("no `return {` table in this config")
    open_at, close_at = block
    m = _top_level_key(text, key, open_at, close_at, mask)
    lit = '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')
    if m:
        # Replace the value that follows, up to the next comma, closing brace
        # or end of line — whichever comes first in the code mask.
        i = m.end()
        while i < close_at and text[i] in " \t":
            i += 1
        j = i
        while j < close_at:
            if mask[j] and text[j] in ",}\n":
                break
            j += 1
        return text[:i] + lit + text[j:]
    ind = _indent_of(text, open_at)
    return text[:open_at + 1] + "\n" + ind + "%s = %s," % (key, lit) + text[open_at + 1:]


def ensure_block(text, key, block=None):
    """Make sure `key = { }` exists inside `block`; return (text, span)."""
    mask = code_mask(text)
    if block is None:
        block = _root_table(text, mask)
        if block is None:
            raise ValueError("no `return {` table in this config")
    found = find_block(text, key, span=(block[0], block[1]), mask=mask)
    if found:
        return text, found
    ind = _indent_of(text, block[0])
    ins = "\n%s%s = {\n%s},"  % (ind, key, ind)
    text = text[:block[0] + 1] + ins + text[block[0] + 1:]
    mask = code_mask(text)
    root = _root_table(text, mask)
    return text, find_block(text, key, span=root, mask=mask)


def _root_table(text, mask):
    m = re.search(r"\breturn\s*\{", text)
    while m and not all(mask[i] for i in range(m.start(), m.end())):
        m = re.search(r"\breturn\s*\{", text[m.end():])
    if not m:
        return None
    open_at = m.end() - 1
    depth = 0
    for i in range(open_at, len(text)):
        if not mask[i]:
            continue
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return open_at, i
    return None


def set_backdrop(text, mode, preset=None, glb=None):
    """Point `backdrop` at a preset, at passthrough, or at the user's own .glb.

    Everything else in the file — including other keys inside `backdrop` — is
    left exactly as it was.
    """
    text, bd = ensure_block(text, "backdrop")
    text = set_string(text, "mode", mode, block=bd)
    if preset is not None:
        text, bd = ensure_block(text, "backdrop")
        text, dflt = ensure_block(text, "default", block=bd)
        text = set_string(text, "preset", preset, block=dflt)
    if glb is not None:
        text, bd = ensure_block(text, "backdrop")
        text, cust = ensure_block(text, "custom", block=bd)
        text = set_string(text, "glb", glb, block=cust)
    return text

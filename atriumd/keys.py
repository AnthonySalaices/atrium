"""Keystrokes from the headset -> `tmux send-keys`.

⛔ **THE TRAP, verified against a real pane: tmux does NOT reject an unknown
key name — it TYPES it.** `tmux send-keys -t s -- S-Tab` put the literal text
"S-Tab" into the pane, and `-- Backspace` typed the word "Backspace" (the real
names are `BTab` and `BSpace`). So this whitelist is the only thing standing
between a client-side typo and garbage appearing in one of your live
agent sessions. **Never pass a name through unvalidated.**

Byte-level behaviour was confirmed against a pane with `stty raw -echo`, because
a pane in canonical mode silently eats several of the interesting bytes (0x12
C-r is REPRINT, 0x7f is ERASE) and makes correct keys look like they vanished:

    C-a 01   C-c 03   C-d 04   C-l 0c   BSpace 7f   Escape 1b   Tab 09
    Enter 0d   Up 1b5b41   BTab 1b5b5a   DC 1b5b337e   S-Up 1b5b313b3241
    C-Space 00   M-b 1b62   C-M-x 1b18  (modifier order is irrelevant to tmux)

Every call is argv. ⛔ Never `shell=True` — this input arrives over the network.
"""

import re
import subprocess
import threading
import time

TMUX = "/usr/bin/tmux"

# Verified names only. Anything not in here is refused rather than typed.
NAMED = frozenset({
    "Enter", "Escape", "Tab", "BTab", "BSpace", "Space",
    "DC", "IC", "Delete", "Insert",
    "Up", "Down", "Left", "Right", "Home", "End",
    "PageUp", "PageDown", "PPage", "NPage",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
})

# Shift only makes a distinct key for navigation/function keys. Shift+Tab is
# `BTab`, NOT `S-Tab` — that was the one that typed itself into the pane.
SHIFTABLE = frozenset({
    "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
})

MAX_ITEMS = 64            # one flushed frame of typing, generously
MAX_SCROLL = 200          # lines per scroll message; a flick, not a seek
MAX_LITERAL = 512         # a paste-sized chunk, not a file
MAX_NAME = 16

# Per-session token bucket. Real typing peaks around 20 keys/s; this only exists
# so a buggy or hostile client cannot spawn thousands of tmux processes.
RATE_BURST = 60.0
RATE_PER_S = 40.0

_MODS = re.compile(r"^((?:[CMS]-)+)?(.+)$")

_lock = threading.Lock()
_buckets = {}             # session -> [tokens, last_refill]


class Rejected(Exception):
    """Bad input from a client. Never raised for a tmux failure."""


def _bucket_take(session, n):
    with _lock:
        tok, last = _buckets.get(session, (RATE_BURST, time.time()))
        now = time.time()
        tok = min(RATE_BURST, tok + (now - last) * RATE_PER_S)
        if tok < n:
            _buckets[session] = (tok, now)
            return False
        _buckets[session] = (tok - n, now)
        return True


def validate_name(name):
    """Return `name` if it is a key tmux actually knows, else raise."""
    if not isinstance(name, str) or not name or len(name) > MAX_NAME:
        raise Rejected("bad key name")
    m = _MODS.match(name)
    if not m:
        raise Rejected("bad key name: %r" % name)
    mods, base = m.group(1) or "", m.group(2)
    if base in NAMED:
        if "S-" in mods and base not in SHIFTABLE:
            # Shift+Tab is BTab; shift+letter is just the uppercase literal.
            raise Rejected("S- is not valid with %s" % base)
        return name
    # A single printable ASCII char is a key only in combination with C- or M-
    # (`C-c`, `M-x`). Bare characters must come through as literal text.
    if len(base) == 1 and 0x21 <= ord(base) <= 0x7E:
        if "C-" not in mods and "M-" not in mods:
            raise Rejected("bare character %r must be sent as literal text" % base)
        return name
    raise Rejected("unknown key name: %r" % name)


def validate_literal(text):
    """Printable text only: control bytes have to be named keys."""
    if not isinstance(text, str):
        raise Rejected("literal must be a string")
    if not text:
        raise Rejected("empty literal")
    if len(text) > MAX_LITERAL:
        raise Rejected("literal too long (%d > %d)" % (len(text), MAX_LITERAL))
    for ch in text:
        if ord(ch) < 0x20 or ord(ch) == 0x7F:
            raise Rejected("control character in literal: %r" % ch)
    return text


def argv_for(session, item):
    """One `{"k": name}` or `{"l": text}` item -> a tmux argv list.

    `--` terminates options so a literal starting with `-` cannot be read as a
    flag, and the session name is positional to `-t`, never interpolated.
    """
    if not isinstance(item, dict):
        raise Rejected("item must be an object")
    if "k" in item:
        return [TMUX, "send-keys", "-t", session, "--", validate_name(item["k"])]
    if "l" in item:
        return [TMUX, "send-keys", "-t", session, "-l", "--", validate_literal(item["l"])]
    raise Rejected("item needs 'k' or 'l'")


def plan(session, seq):
    """Validate a whole batch up front. Nothing is sent if anything is bad."""
    if not isinstance(session, str) or not session or len(session) > 64:
        raise Rejected("bad session")
    if not re.match(r"^[A-Za-z0-9._@:+-]+$", session):
        raise Rejected("bad session name")
    if not isinstance(seq, list) or not seq:
        raise Rejected("seq must be a non-empty list")
    if len(seq) > MAX_ITEMS:
        raise Rejected("too many items (%d > %d)" % (len(seq), MAX_ITEMS))
    return [argv_for(session, it) for it in seq]


def send(session, seq, runner=None):
    """Validate then deliver. Returns the number of items sent.

    Raises Rejected for bad input (a client bug) and returns a partial count
    for a tmux failure (a real-world condition, e.g. the pane just died).
    """
    argvs = plan(session, seq)
    if not _bucket_take(session, len(argvs)):
        raise Rejected("rate limited")
    run = runner or subprocess.run
    sent = 0
    for argv in argvs:
        p = run(argv, capture_output=True, text=True, timeout=5)
        if getattr(p, "returncode", 1) != 0:
            break
        sent += 1
    return sent


# ── Scrolling ────────────────────────────────────────────────────────────────
#
# A pointer drag or a thumbstick flick on the focus panel becomes one of these.
# Three kinds of pane, three deliveries — and the choice is made HERE, per call,
# by asking tmux what the pane is doing right now:
#
#   1. The app asked for mouse reporting (Claude Code, Codex, anything TUI with
#      wheel support): write the SGR wheel sequence straight into the pane, at
#      the cell the pointer is over. The app scrolls itself, exactly as it would
#      under a real mouse wheel, and tmux copy-mode never gets involved.
#   2. A plain shell on the normal screen: `copy-mode -e` then `scroll-up`.
#      ⭐ `-e` is the exit design: the moment a scroll-down reaches the bottom,
#      copy-mode ends by itself and the pane is live again. Nothing is ever
#      left parked in copy-mode by a gesture.
#   3. An alternate-screen app WITHOUT mouse reporting (vim with no mouse, less):
#      nothing is safe to send — Up/Down would be keystrokes into an editor —
#      so it is skipped and the client is told why.
#
# ⛔ The SGR bytes are built here from validated integers and delivered with
# `send-keys -l`; they never pass through validate_literal (which rightly
# refuses control characters from a client).

def _pane_state(session, run):
    """(in_mode, alternate_on, mouse_any) for the session's active pane."""
    p = run([TMUX, "display-message", "-p", "-t", session,
             "#{pane_in_mode} #{alternate_on} #{mouse_any_flag}"],
            capture_output=True, text=True, timeout=5)
    if getattr(p, "returncode", 1) != 0:
        return None
    parts = (getattr(p, "stdout", "") or "").split()
    if len(parts) != 3:
        return None
    return tuple(x == "1" for x in parts)


def scroll(session, lines, col=1, row=1, runner=None):
    """Scroll `lines` (>0 = older/up, <0 = newer/down) in a session's pane.

    `col`/`row` are the 1-based cell under the pointer, used only for the
    mouse-wheel delivery. Returns a dict: {"sent": n, "via": how} or
    {"sent": 0, "skipped": why}. Raises Rejected for bad input.
    """
    plan(session, [{"k": "Enter"}])          # reuses the session-name checks
    if not isinstance(lines, int) or isinstance(lines, bool) or lines == 0:
        raise Rejected("lines must be a non-zero integer")
    if abs(lines) > MAX_SCROLL:
        raise Rejected("too many lines (%d > %d)" % (abs(lines), MAX_SCROLL))
    for v in (col, row):
        if not isinstance(v, int) or isinstance(v, bool) or v < 1 or v > 1000:
            raise Rejected("col/row out of range")
    if not _bucket_take(session, 1):
        raise Rejected("rate limited")
    run = runner or subprocess.run
    state = _pane_state(session, run)
    if state is None:
        return {"sent": 0, "skipped": "no such pane"}
    in_mode, alternate, mouse = state
    n = abs(lines)

    if mouse and not in_mode:
        # SGR 1006 wheel: button 64 = up, 65 = down, press ('M') only.
        button = 64 if lines > 0 else 65
        seq = "\x1b[<%d;%d;%dM" % (button, col, row)
        p = run([TMUX, "send-keys", "-t", session, "-l", "--", seq * n],
                capture_output=True, text=True, timeout=5)
        return {"sent": n if getattr(p, "returncode", 1) == 0 else 0, "via": "wheel"}

    if alternate and not in_mode:
        return {"sent": 0, "skipped": "alternate screen without mouse reporting"}

    if lines > 0 and not in_mode:
        p = run([TMUX, "copy-mode", "-e", "-t", session],
                capture_output=True, text=True, timeout=5)
        if getattr(p, "returncode", 1) != 0:
            return {"sent": 0, "skipped": "copy-mode refused"}
    elif lines < 0 and not in_mode:
        return {"sent": 0, "skipped": "already at the bottom"}
    cmd = "scroll-up" if lines > 0 else "scroll-down"
    p = run([TMUX, "send-keys", "-t", session, "-X", "-N", str(n), cmd],
            capture_output=True, text=True, timeout=5)
    return {"sent": n if getattr(p, "returncode", 1) == 0 else 0, "via": "copy-mode"}

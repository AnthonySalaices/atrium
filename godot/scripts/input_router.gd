extends Node
class_name InputRouter

## M4 — physical keyboard -> tmux, via the link that already carries the pixels.
##
## Godot key events become a small ordered list of items that atriumd/keys.py
## validates and hands to `tmux send-keys`:
##
##     [{"l": "ls -la"}, {"k": "Enter"}]
##
## `l` is literal text, `k` is a tmux key NAME. tmux owns the byte encoding, so
## this never builds escape sequences itself — the pane's own terminal mode
## decides whether Up is `ESC [ A` or `ESC O A`, and only tmux knows that.
##
## ⛔ **Ctrl chords arrive with `unicode == 0`** (correct — control characters
## have no printable code point). Verified on hardware 2026-09-15 with a Keychron
## V1 Max over BLE. Passing `unicode` through for those sends nothing at all;
## the chord has to be rebuilt from keycode + modifier, which is what
## `_ctrl_base()` does.
##
## ⛔ **Only names tmux actually knows.** `send-keys -- S-Tab` does not error, it
## TYPES "S-Tab" into the pane. Shift+Tab is `BTab`; Backspace is `BSpace`.
## The host re-validates every name for exactly this reason.

signal batch(seq: Array)

const MAX_BATCH := 48          # keys.py refuses more than 64 in one message

# Keys that have a tmux name. Everything else is literal text.
const NAMED := {
	KEY_ENTER: "Enter", KEY_KP_ENTER: "Enter",
	KEY_ESCAPE: "Escape", KEY_TAB: "Tab", KEY_BACKTAB: "BTab",
	KEY_BACKSPACE: "BSpace", KEY_DELETE: "DC", KEY_INSERT: "IC",
	KEY_UP: "Up", KEY_DOWN: "Down", KEY_LEFT: "Left", KEY_RIGHT: "Right",
	KEY_HOME: "Home", KEY_END: "End",
	KEY_PAGEUP: "PageUp", KEY_PAGEDOWN: "PageDown",
	KEY_F1: "F1", KEY_F2: "F2", KEY_F3: "F3", KEY_F4: "F4",
	KEY_F5: "F5", KEY_F6: "F6", KEY_F7: "F7", KEY_F8: "F8",
	KEY_F9: "F9", KEY_F10: "F10", KEY_F11: "F11", KEY_F12: "F12",
}

# Shift is only a distinct key for navigation and function keys.
const SHIFTABLE := ["Up", "Down", "Left", "Right", "Home", "End",
		"PageUp", "PageDown", "F1", "F2", "F3", "F4", "F5", "F6",
		"F7", "F8", "F9", "F10", "F11", "F12"]

# Ctrl chords that are not plain letters. C-[ is Escape, C-Space is NUL.
const CTRL_EXTRA := {
	KEY_SPACE: "Space", KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]",
	KEY_BACKSLASH: "\\",
}

var _pending: Array = []
var dropped := 0


## Returns true if the event was consumed (i.e. it is going to the terminal).
func feed(k: InputEventKey) -> bool:
	if not k.pressed:
		return false
	# ⭐ Autorepeat is PASSED THROUGH on purpose: holding Backspace should delete
	# repeatedly, which is what a terminal does. (The spike filtered echoes only
	# to keep its own log readable — that was a logging fix, not a typing rule.)
	var item := _item_for(k)
	if item.is_empty():
		return false
	_push(item)
	return true


func _item_for(k: InputEventKey) -> Dictionary:
	if NAMED.has(k.keycode):
		var name: String = NAMED[k.keycode]
		if k.keycode == KEY_TAB and k.shift_pressed:
			name = "BTab"                       # ⛔ never "S-Tab"
		elif k.shift_pressed and name in SHIFTABLE:
			name = "S-" + name
		if k.alt_pressed:
			name = "M-" + name
		if k.ctrl_pressed:
			name = "C-" + name
		return {"k": name}

	if k.ctrl_pressed:
		var base := _ctrl_base(k.keycode)
		if base == "":
			return {}
		return {"k": ("C-M-" if k.alt_pressed else "C-") + base}

	if k.alt_pressed and k.unicode > 0x20 and k.unicode < 0x7F:
		return {"k": "M-" + char(k.unicode)}

	# Printable text, including Space. Shift is already baked into `unicode`.
	if k.unicode >= 0x20 and k.unicode != 0x7F:
		return {"l": char(k.unicode)}

	return {}


## ⚠️ Built from the KEYCODE, never from `unicode` — see the header.
func _ctrl_base(keycode: int) -> String:
	if keycode >= KEY_A and keycode <= KEY_Z:
		return char(keycode + 32)               # KEY_A is 'A'; tmux wants "C-a"
	if CTRL_EXTRA.has(keycode):
		return CTRL_EXTRA[keycode]
	return ""


## Consecutive typed characters coalesce into one literal, so typing a word is
## one `send-keys -l` instead of one process per letter.
func _push(item: Dictionary) -> void:
	if item.has("l") and not _pending.is_empty():
		var last: Dictionary = _pending[-1]
		if last.has("l"):
			last["l"] = str(last["l"]) + str(item["l"])
			return
	if _pending.size() >= MAX_BATCH:
		# Flush early rather than drop: a paste can outrun one frame.
		flush()
	_pending.append(item)


func _process(_delta: float) -> void:
	flush()


func flush() -> void:
	if _pending.is_empty():
		return
	var seq := _pending
	_pending = []
	emit_signal("batch", seq)

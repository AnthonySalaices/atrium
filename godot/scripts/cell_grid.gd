extends Control
class_name CellGrid

## Paints a terminal cell grid.
##
## Deliberately NOT a RichTextLabel: a terminal is a fixed grid and anything
## that reflows or kerns reads as subtly broken. Every glyph lands on an exact
## integer cell, which is also what makes the composition layer look crisp.

const DEFAULT = -1
const RGB_FLAG = 0x1000000

# attribute bits, matching atriumd/sgr.py
const BOLD = 1
const DIM = 2
const ITALIC = 4
const UNDERLINE = 8
const REVERSE = 16
const STRIKE = 32

var font: FontFile
var font_size := 32
var cell := Vector2i(16, 40)
var cols := 80
var rows := 28

var fg_default := Color(0.878, 0.898, 0.925)
var bg_default := Color(0.051, 0.067, 0.09)
var cursor_bg := Color(0.878, 0.898, 0.925)
var cursor_fg := Color(0.051, 0.067, 0.09)
var cursor_border := Color(0.878, 0.898, 0.925)
## WezTerm's names: Steady|Blinking + Block|Underline|Bar.
var cursor_style := "SteadyBlock"
var blink_ms := 800
var _blink_on := true
var _blink_t := 0.0

## rows of [[fg, bg, attrs, text], ...]
var grid: Array = []
var cursor := Vector2i(0, 0)
var cursor_visible := true
var _palette: PackedColorArray = PackedColorArray()


func _ready() -> void:
	if _palette.is_empty():
		_build_palette()
	set_process(cursor_style.begins_with("Blinking") and blink_ms > 0)
	grid.resize(rows)
	for y in range(rows):
		grid[y] = [[DEFAULT, DEFAULT, 0, " ".repeat(cols)]]


## Standard xterm-256: 16 system colours, a 6x6x6 cube, then 24 greys.
func _build_palette() -> void:
	_palette.resize(256)
	var base := [
		Color8(0, 0, 0), Color8(205, 49, 49), Color8(13, 188, 121), Color8(229, 229, 16),
		Color8(36, 114, 200), Color8(188, 63, 188), Color8(17, 168, 205), Color8(229, 229, 229),
		Color8(102, 102, 102), Color8(241, 76, 76), Color8(35, 209, 139), Color8(245, 245, 67),
		Color8(59, 142, 234), Color8(214, 112, 214), Color8(41, 184, 219), Color8(255, 255, 255),
	]
	for i in range(16):
		_palette[i] = base[i]
	var steps := [0, 95, 135, 175, 215, 255]
	for r in range(6):
		for g in range(6):
			for b in range(6):
				_palette[16 + 36 * r + 6 * g + b] = Color8(steps[r], steps[g], steps[b])
	for i in range(24):
		var v := 8 + i * 10
		_palette[232 + i] = Color8(v, v, v)


## The resolved `colors` table from atriumd (schemes.py): 16 ANSI colours,
## defaults, cursor, and any `indexed` overrides. The 6x6x6 cube and the greys
## stay xterm's unless indexed says otherwise, as in WezTerm.
func set_colors(c: Dictionary, style: String = "SteadyBlock", blink: int = 800) -> void:
	_build_palette()
	var ansi: Array = c.get("ansi", [])
	var brights: Array = c.get("brights", [])
	for i in range(min(8, ansi.size())):
		_palette[i] = Color.html(str(ansi[i]))
	for i in range(min(8, brights.size())):
		_palette[8 + i] = Color.html(str(brights[i]))
	var idx: Dictionary = c.get("indexed", {})
	for k in idx:
		var n := int(k)
		if n >= 0 and n < 256:
			_palette[n] = Color.html(str(idx[k]))
	fg_default = Color.html(str(c.get("foreground", fg_default.to_html(false))))
	bg_default = Color.html(str(c.get("background", bg_default.to_html(false))))
	cursor_bg = Color.html(str(c.get("cursor_bg", fg_default.to_html(false))))
	cursor_fg = Color.html(str(c.get("cursor_fg", bg_default.to_html(false))))
	cursor_border = Color.html(str(c.get("cursor_border", cursor_bg.to_html(false))))
	cursor_style = style
	blink_ms = blink
	_blink_on = true
	_blink_t = 0.0
	set_process(cursor_style.begins_with("Blinking") and blink_ms > 0)
	queue_redraw()


## Blink by redrawing only on a phase change; a steady cursor never ticks.
func _process(delta: float) -> void:
	_blink_t += delta * 1000.0
	if _blink_t >= blink_ms:
		_blink_t = fmod(_blink_t, float(blink_ms))
		_blink_on = not _blink_on
		queue_redraw()


func color_of(c: int, is_fg: bool) -> Color:
	if c == DEFAULT:
		return fg_default if is_fg else bg_default
	if c & RGB_FLAG:
		return Color8((c >> 16) & 255, (c >> 8) & 255, c & 255)
	if c >= 0 and c < 256:
		return _palette[c]
	return fg_default if is_fg else bg_default


func configure(p_cols: int, p_rows: int, p_font: FontFile, p_font_size: int, p_cell: Vector2i) -> void:
	cols = p_cols
	rows = p_rows
	font = p_font
	font_size = p_font_size
	cell = p_cell
	custom_minimum_size = Vector2(cols * cell.x, rows * cell.y)
	size = custom_minimum_size
	grid.resize(rows)
	for y in range(rows):
		if grid[y] == null:
			grid[y] = [[DEFAULT, DEFAULT, 0, " ".repeat(cols)]]
	queue_redraw()


## Blank every row. Used when switching sessions: the first frame of the new
## session arrives a moment later, and showing the PREVIOUS session's text in the
## meantime is worse than showing nothing — it reads as "the switch did nothing".
func clear() -> void:
	for y in range(rows):
		grid[y] = [[DEFAULT, DEFAULT, 0, " ".repeat(cols)]]
	queue_redraw()


## Apply one frame from atriumd. base == 0 means a full frame.
func apply_frame(msg: Dictionary) -> void:
	var c: int = int(msg.get("cols", cols))
	var r: int = int(msg.get("rows", rows))
	if c != cols or r != rows:
		cols = c
		rows = r
		grid.resize(rows)
		custom_minimum_size = Vector2(cols * cell.x, rows * cell.y)
		size = custom_minimum_size
	for line in msg.get("lines", []):
		var y: int = int(line.get("y", -1))
		if y >= 0 and y < rows:
			grid[y] = line.get("runs", [])
	var cur = msg.get("cursor", null)
	if cur != null:
		cursor = Vector2i(int(cur.get("x", 0)), int(cur.get("y", 0)))
		cursor_visible = bool(cur.get("visible", true))
	queue_redraw()


func _draw() -> void:
	if font == null:
		return
	draw_rect(Rect2(Vector2.ZERO, Vector2(cols * cell.x, rows * cell.y)), bg_default, true)
	var ascent := font.get_ascent(font_size)

	for y in range(min(rows, grid.size())):
		var runs = grid[y]
		if runs == null:
			continue
		var x := 0
		for run in runs:
			if run.size() < 4:
				continue
			var fg_i: int = int(run[0])
			var bg_i: int = int(run[1])
			var attrs: int = int(run[2])
			var text: String = str(run[3])

			var fg := color_of(fg_i, true)
			var bg := color_of(bg_i, false)
			if attrs & REVERSE:
				var t := fg
				fg = bg
				bg = t
			if attrs & DIM:
				fg = fg.darkened(0.35)

			var w := text.length()
			if bg != bg_default:
				draw_rect(Rect2(Vector2(x * cell.x, y * cell.y),
						Vector2(w * cell.x, cell.y)), bg, true)

			# One glyph per cell, snapped to the grid. draw_char, not draw_string:
			# proportional advance would drift across an 80-column row.
			for i in range(w):
				var ch := text[i]
				if ch != " ":
					var pos := Vector2((x + i) * cell.x, y * cell.y + ascent)
					draw_char(font, pos, ch, font_size, fg)
					if attrs & BOLD:
						draw_char(font, pos + Vector2(0.6, 0), ch, font_size, fg)
			if attrs & UNDERLINE:
				var uy := y * cell.y + ascent + 3
				draw_line(Vector2(x * cell.x, uy), Vector2((x + w) * cell.x, uy), fg, 1.5)
			if attrs & STRIKE:
				var sy := y * cell.y + cell.y * 0.55
				draw_line(Vector2(x * cell.x, sy), Vector2((x + w) * cell.x, sy), fg, 1.5)
			x += w

	if cursor_visible and cursor.y < rows and cursor.x < cols and _blink_on:
		_draw_cursor(ascent)


## WezTerm's shapes: a filled block that re-draws its glyph in cursor_fg, a bar
## on the cell's left edge, or an underline. The block keeps cursor_border as
## its outline, which is the whole of what the pre-scheme cursor used to be.
func _draw_cursor(ascent: float) -> void:
	var origin := Vector2(cursor.x * cell.x, cursor.y * cell.y)
	if cursor_style.ends_with("Bar"):
		draw_rect(Rect2(origin, Vector2(max(2.0, cell.x * 0.12), cell.y)), cursor_bg, true)
	elif cursor_style.ends_with("Underline"):
		var h: float = max(2.0, cell.y * 0.08)
		draw_rect(Rect2(origin + Vector2(0, cell.y - h), Vector2(cell.x, h)), cursor_bg, true)
	else:
		draw_rect(Rect2(origin, Vector2(cell.x, cell.y)), cursor_bg, true)
		draw_rect(Rect2(origin, Vector2(cell.x, cell.y)), cursor_border, false, 2.0)
		var ch := _char_at(cursor.x, cursor.y)
		if ch != "" and ch != " ":
			draw_char(font, origin + Vector2(0, ascent), ch, font_size, cursor_fg)


## The glyph under cell (x, y), walking the row's runs.
func _char_at(x: int, y: int) -> String:
	if y >= grid.size() or grid[y] == null:
		return ""
	var at := 0
	for run in grid[y]:
		if run.size() < 4:
			continue
		var text: String = str(run[3])
		if x < at + text.length():
			return text[x - at]
		at += text.length()
	return ""

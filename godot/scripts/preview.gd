extends Node3D

## Flat layout preview — renders the arrangement to a PNG and quits.
##
##     godot --path godot --resolution 1280x720 -- --shot out.png
##
## The build host has no X server, so this is the only way to SEE a layout without
## putting the headset on: render it on a machine with a GPU and look at the file.
## Roughly 90 seconds end to end, which makes spacing, colour and glow iterable.
##
## ⚠️ **A stand-in, not a fidelity test.** `OpenXRCompositionLayer` draws nothing
## outside an XR session, so panels here are textured quads — the very path the
## real client avoids. Judge LAYOUT, COLOUR, GLOW, SPACING. Never sharpness.
## ⚠️ A 104° field rendered flat also STRETCHES the frame edges, so anything near
## a corner looks bigger and more skewed than it will on the headset.

const H_FOV := 104.0            # Quest 3, horizontal
const PANEL_DIST := 1.5
const PANEL_DOWN_DEG := 10.0    # the comfortable resting gaze angle
const DMM := 22.3
const FONT_PX := 32
const CELL := Vector2i(16, 40)
const COLS := 80
const ROWS := 28

# ── The card stack: staggered on the left, the urgent one lifts out of it.
const STACK_YAW_DEG := -34.0
const STACK_DIST := 1.55
const STACK_Y := 0.06
const CARD_W := 0.40
const CARD_H := 0.15
# ⛔ Cards that OVERLAP cannot be translucent: glass does not occlude, so a card
# behind shows THROUGH the one in front and the names collide into mush. Caught
# immediately in a render. So: a readable column while there is room, and only
# the overflow collapses into a staggered deck of edges.
const CARD_GAP := 0.028          # clear space between cards in the column
const STACK_MAX := 4             # cards shown in full before collapsing
const DECK_STEP := 0.016         # sliver of each collapsed card: countable, quiet
const DECK_SHOW := 3             # at most this many slivers, then the count
const LIFT_UP := 0.205           # clear air above the column: elevation is the affordance
const LIFT_TOWARD := 0.22

const STATE_COLOR := {
	"needs-input": Color(1.0, 0.72, 0.29),
	"error": Color(1.0, 0.45, 0.42),
	"done": Color(0.55, 0.85, 0.62),
	"working": Color(0.45, 0.68, 1.0),
	"idle": Color(0.62, 0.66, 0.72),
}

const FAKE := [
	{"key": "glasshouse", "state": "needs-input", "focus": true},
	{"key": "ferusky", "state": "needs-input"},
	{"key": "orca-sim", "state": "working"},
	{"key": "stash", "state": "working"},
	{"key": "westworld", "state": "idle"},
	{"key": "vrflip", "state": "idle"},
	{"key": "bf6-stats", "state": "idle"},
	{"key": "aperture", "state": "idle"},
]

var font: FontFile
var glass_shader: Shader
var _frames := 0
var _shot_path := ""
var _status_path := ""


## ⚠️ Godot's stdout is BUFFERED, so a hung windowed run on Windows logs nothing.
## Per-step progress to a file makes a stuck run diagnosable from another machine.
func note(msg: String) -> void:
	print("[preview] " + msg)
	if _status_path == "":
		return
	var f := FileAccess.open(_status_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_status_path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("%d  %s" % [Time.get_ticks_msec(), msg])
	f.close()


func _ready() -> void:
	_shot_path = _arg_value("--shot", "preview.png")
	_status_path = _arg_value("--status", _shot_path + ".status.txt")
	var sf := FileAccess.open(_status_path, FileAccess.WRITE)
	if sf != null:
		sf.store_line("ready")
		sf.close()
	font = load("res://fonts/IosevkaTerm-Medium.ttf")
	glass_shader = load("res://shaders/glass_card.gdshader")
	note("driver=%s" % DisplayServer.get_name())

	var cam := Camera3D.new()
	# ⚠️ `fov` is VERTICAL, and `keep_aspect = KEEP_WIDTH` does NOT change that —
	# measuring a render proved it. Convert explicitly rather than trusting it.
	cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(H_FOV) * 0.5) * 9.0 / 16.0))
	add_child(cam)

	_build_sky()
	_build_focus_panel()
	note("focus panel built")
	_build_stack()
	note("stack built")


func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(flag)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


func _build_sky() -> void:
	var sky := Sky.new()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/nebula_sky.gdshader")
	sky.sky_material = mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


## dmm is the FONT size, so angular width is cols * cell.x * (dmm / font_px) mrad.
func _panel_size(cols: int, rows: int, dmm: float, dist: float) -> Vector2:
	var vp_w := cols * CELL.x
	var ang := (dmm / float(FONT_PX)) * float(vp_w) / 1000.0
	var w := 2.0 * dist * tan(ang * 0.5)
	return Vector2(w, w * float(rows * CELL.y) / float(vp_w))


func _build_focus_panel() -> void:
	var size := _panel_size(COLS, ROWS + 1, DMM, PANEL_DIST)
	var y := -PANEL_DIST * tan(deg_to_rad(PANEL_DOWN_DEG))
	var pos := Vector3(0, y, -PANEL_DIST)

	var vp := SubViewport.new()
	# One extra cell row is the STATUS STRIP: without it the status label covers
	# the terminal's first line, which is real output.
	vp.size = Vector2i(COLS * CELL.x, (ROWS + 1) * CELL.y)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var grid := CellGrid.new()
	grid.configure(COLS, ROWS, font, FONT_PX, CELL)
	grid.position = Vector2(0, CELL.y)
	vp.add_child(grid)
	_load_sample(grid)

	var label := Label.new()
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", STATE_COLOR["needs-input"])
	label.position = Vector2(8, 2)
	label.text = "glasshouse — 1 waiting"
	vp.add_child(label)

	# ⭐ THE HYBRID, made visible: the glass FRAME is in-scene geometry and the
	# text sits inset inside it. In the real client that inset is a composition
	# layer, which cannot be bezelled or blurred — so the frame has to be its own
	# surface around it. This is the arrangement to prove on hardware.
	var margin := 0.055
	_glass(size + Vector2(margin, margin), pos + Vector3(0, 0, -0.012), {
		"corner_radius_px": 34.0, "bezel_px": 4.0, "glass_opacity": 0.30,
		"edge_strength": 0.9,
	})
	_glass(size, pos, {
		"corner_radius_px": 26.0, "bezel_px": 2.0, "glass_opacity": 0.72,
		"edge_strength": 0.25, "content": vp.get_texture(),
	})


func _load_sample(grid: CellGrid) -> void:
	var f := FileAccess.open("res://data/sample.txt", FileAccess.READ)
	if f == null:
		return
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	var rows_out: Array = []
	for y in range(ROWS):
		var text: String = str(lines[y]) if y < lines.size() else ""
		if text.length() < COLS:
			text += " ".repeat(COLS - text.length())
		# ⚠️ A line is {y, runs}, not a bare array — the array painted nothing.
		rows_out.append({"y": y, "runs": [[7, 0, 0, text.substr(0, COLS)]]})
	grid.apply_frame({"cols": COLS, "rows": ROWS, "base": 0, "lines": rows_out})


## Sessions that are not focused live in a staggered stack, and the one that wants
## you LIFTS OUT of it — the same promote-from-a-deck idea as an iOS notification
## stack, which is a pattern people already know. Elevation is the affordance.
func _build_stack() -> void:
	var rest: Array = FAKE.filter(func(s): return not bool(s.get("focus", false)))
	var lifted: Dictionary = {}
	for s in rest:
		if str(s.get("state", "")) == "needs-input":
			lifted = s
			break
	if not lifted.is_empty():
		rest.erase(lifted)

	var yaw := deg_to_rad(STACK_YAW_DEG)
	var base := Vector3(sin(yaw) * STACK_DIST, STACK_Y, -cos(yaw) * STACK_DIST)
	var toward := -base.normalized()          # out of the stack, toward the eye

	var shown: int = min(rest.size(), STACK_MAX)
	var step := CARD_H + CARD_GAP
	var y_cursor := 0.0
	for i in range(shown):
		var card: Dictionary = rest[i]
		_card(base + Vector3(0, y_cursor, 0), Vector2(CARD_W, CARD_H),
				str(card.get("key", "?")), str(card.get("state", "idle")), 0.0, 0.42)
		y_cursor -= step

	# The overflow: a staggered deck. Each sliver is a real card pushed almost
	# entirely behind the one in front, so you can COUNT the work waiting without
	# reading any of it — and a deck of four reads differently from a deck of one.
	var hidden: int = rest.size() - shown
	if hidden > 0:
		y_cursor -= 0.012
		var slivers: int = min(hidden, DECK_SHOW)
		for i in range(slivers - 1, -1, -1):
			var c: Dictionary = rest[shown + i]
			_card(base + Vector3(0, y_cursor - DECK_STEP * float(i), -0.004 * float(i)),
					Vector2(CARD_W - 0.02 * float(i), CARD_H),
					"", str(c.get("state", "idle")), 0.0, 0.30, true)
		_card(base + Vector3(0, y_cursor - DECK_STEP * float(slivers) - 0.030, 0),
				Vector2(CARD_W - 0.02 * float(slivers), 0.055),
				"+%d more" % hidden, "idle", 0.0, 0.26, true)

	if not lifted.is_empty():
		var pos := base + Vector3(0, LIFT_UP, 0) + toward * LIFT_TOWARD
		_card(pos, Vector2(CARD_W, CARD_H) * 1.06, str(lifted.get("key", "?")),
				str(lifted.get("state", "needs-input")), 1.0, 0.42)


func _card(pos: Vector3, size: Vector2, title: String, state: String, glow: float,
		opacity: float, quiet := false) -> void:
	var tint: Color = STATE_COLOR.get(state, STATE_COLOR["idle"])
	var vp := SubViewport.new()
	vp.size = Vector2i(int(size.x * 900.0), int(size.y * 900.0))
	vp.transparent_bg = true          # the glass IS the plate; no opaque rect
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var name_label := Label.new()
	name_label.add_theme_font_override("font", font)
	name_label.add_theme_font_size_override("font_size", 30 if quiet else 40)
	name_label.add_theme_color_override("font_color",
			Color(0.97, 0.98, 1.0) if glow > 0.0 else Color(0.80, 0.83, 0.88))
	name_label.position = Vector2(26, 14)
	name_label.text = title
	vp.add_child(name_label)

	if not quiet:
		var state_label := Label.new()
		state_label.add_theme_font_override("font", font)
		state_label.add_theme_font_size_override("font_size", 28)
		state_label.add_theme_color_override("font_color", tint)
		state_label.position = Vector2(26, 62)
		state_label.text = state
		vp.add_child(state_label)

	_glass(size, pos, {
		"corner_radius_px": 26.0, "bezel_px": 3.0, "glass_opacity": opacity,
		"edge_strength": 1.0, "glow": glow, "glow_color": tint,
		"content": vp.get_texture(),
	})


## ⚠️ A quad placed off-axis must be aimed at the eye in BOTH axes; rotating only
## around Y leaves a card above you facing the wall behind your head. `look_at`
## does yaw and pitch together, and the extra 180° is because a QuadMesh faces +Z
## while look_at aims -Z.
func _glass(size: Vector2, pos: Vector3, params: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = glass_shader
	mat.set_shader_parameter("size_px", Vector2(size.x * 900.0, size.y * 900.0))
	for k in params:
		mat.set_shader_parameter(k, params[k])

	var mesh := QuadMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	if pos.length() > 0.001:
		mi.look_at(Vector3.ZERO, Vector3.UP)
		mi.rotate_object_local(Vector3.UP, PI)


func _process(_d: float) -> void:
	_frames += 1
	# SubViewport textures and the sky are not ready on frame 1; a shot taken then
	# is simply black.
	if _frames < 24:
		return
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(_shot_path)
	note("%s %s (%dx%d)" % ["saved" if err == OK else "FAILED", _shot_path,
			img.get_width(), img.get_height()])
	get_tree().quit(0 if err == OK else 1)

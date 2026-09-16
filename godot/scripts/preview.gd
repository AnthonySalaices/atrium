extends Node3D

## Flat layout preview — renders the panel arrangement to a PNG and quits.
##
##     godot --path godot scenes/preview.tscn -- --shot out.png
##
## Why this exists: the build host has no X server, so the only way to SEE a
## layout without putting the headset on is to render it on a machine with a GPU
## and look at the file. That makes tile placement, glow intensity and label
## legibility iterable in seconds instead of once per headset window.
##
## ⚠️ **This is a stand-in, not a fidelity test.** `OpenXRCompositionLayer` draws
## nothing outside an XR session, so the panels here are ordinary textured quads —
## exactly the "blurry mesh" path the real client never uses. Judge LAYOUT,
## COLOUR, GLOW and SPACING here. Never judge sharpness: that question was already
## answered on hardware, and a layer beats a mesh.

const PANEL_DIST := 1.5
const DMM := 22.3
const FONT_PX := 32
const CELL := Vector2i(16, 40)
const COLS := 80
const ROWS := 28

# One tile per non-focused session: name + state, never prose.
const TILE_COLS := 20
const TILE_ROWS := 3
const TILE_DIST := 1.9
const TILE_DMM := 26.0        # bigger than the terminal: read at a glance, not read

# The glass language's state colours. Glow is expressed as edge luminance.
const STATE_COLOR := {
	"needs-input": Color(1.0, 0.72, 0.29),
	"error": Color(1.0, 0.45, 0.42),
	"done": Color(0.55, 0.85, 0.62),
	"working": Color(0.45, 0.68, 1.0),
	"idle": Color(0.55, 0.58, 0.64),
}

# A plausible fleet, so the preview shows what a busy moment looks like.
const FAKE := [
	{"key": "glasshouse", "state": "needs-input", "focus": true},
	{"key": "ferusky", "state": "working"},
	{"key": "orca-sim", "state": "idle"},
	{"key": "stash", "state": "done"},
	{"key": "westworld", "state": "error"},
	{"key": "vrflip", "state": "idle"},
]

var font: FontFile
var _frames := 0
var _shot_path := ""
var _status_path := ""


## ⚠️ Godot's stdout is BUFFERED, so when a windowed run hangs on Windows you see
## nothing at all — the log stays empty until the process exits, which is exactly
## when it never does. Writing progress to a file each step makes a stuck run
## diagnosable from another machine. Cost one debugging round; keep it.
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
	var f := FileAccess.open(_status_path, FileAccess.WRITE)
	if f != null:
		f.store_line("ready: args=%s" % str(OS.get_cmdline_user_args()))
		f.close()
	note("shot=%s driver=%s" % [_shot_path, DisplayServer.get_name()])
	font = load("res://fonts/IosevkaTerm-Medium.ttf")

	var cam := Camera3D.new()
	cam.position = Vector3(0, 0, 0)
	# Wide, to approximate how much of the headset's field of view this fills.
	cam.fov = 95.0
	add_child(cam)

	_build_sky()
	note("sky built")
	_build_focus_panel()
	note("focus panel built")
	_build_tiles()
	note("tiles built")


func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(flag)
	if i >= 0 and i + 1 < args.size():
		return args[i + 1]
	return fallback


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


## Same arithmetic as terminal.gd: dmm is the FONT size, so the panel's angular
## width is cols * cell.x * (dmm / font_px) milliradians.
func _panel_size(cols: int, rows: int, dmm: float, dist: float) -> Vector2:
	var vp_w := cols * CELL.x
	var vp_h := rows * CELL.y
	var ang := (dmm / float(FONT_PX)) * float(vp_w) / 1000.0
	var w := 2.0 * dist * tan(ang * 0.5)
	return Vector2(w, w * float(vp_h) / float(vp_w))


func _build_focus_panel() -> void:
	var size := _panel_size(COLS, ROWS, DMM, PANEL_DIST)
	var vp := SubViewport.new()
	vp.size = Vector2i(COLS * CELL.x, ROWS * CELL.y)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var grid := CellGrid.new()
	grid.configure(COLS, ROWS, font, FONT_PX, CELL)
	vp.add_child(grid)
	_load_sample(grid)

	var label := Label.new()
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", STATE_COLOR["needs-input"])
	label.position = Vector2(4, 0)
	label.text = "glasshouse   1 waiting"
	vp.add_child(label)

	_quad(vp, size, Vector3(0, 0, -PANEL_DIST), 0.0)


## Paint the bundled sample transcript so the panel shows realistic text density
## rather than lorem ipsum — line length is what makes a layout feel right.
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
			text = text + " ".repeat(COLS - text.length())
		rows_out.append([[7, 0, 0, text.substr(0, COLS)]])
	grid.apply_frame({"cols": COLS, "rows": ROWS, "base": 0, "lines": rows_out})


func _build_tiles() -> void:
	var others: Array = FAKE.filter(func(s): return not bool(s.get("focus", false)))
	var size := _panel_size(TILE_COLS, TILE_ROWS, TILE_DMM, TILE_DIST)
	# Spread across an arc ABOVE the terminal: glanceable without covering it.
	var span := deg_to_rad(76.0)
	var n := others.size()
	for i in range(n):
		var t: Dictionary = others[i]
		var frac := (float(i) / float(max(1, n - 1))) - 0.5
		var yaw := frac * span
		var vp := SubViewport.new()
		vp.size = Vector2i(TILE_COLS * CELL.x, TILE_ROWS * CELL.y)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		_tile_contents(vp, t)
		var pos := Vector3(sin(yaw) * TILE_DIST, 0.62, -cos(yaw) * TILE_DIST)
		_quad(vp, size, pos, -yaw)


func _tile_contents(vp: SubViewport, t: Dictionary) -> void:
	var state := str(t.get("state", "idle"))
	var tint: Color = STATE_COLOR.get(state, STATE_COLOR["idle"])
	var waiting := state in ["needs-input", "error", "done"]

	# Glass: a dark translucent plate. The GLOW is edge luminance in the state
	# tint — not a bolted-on border — and only a session that is WAITING gets it.
	var plate := ColorRect.new()
	plate.size = vp.size
	plate.color = Color(0.05, 0.065, 0.09, 0.85)
	vp.add_child(plate)

	var edge := ColorRect.new()
	edge.size = Vector2(vp.size.x, 6)
	edge.position = Vector2(0, vp.size.y - 6)
	edge.color = tint if waiting else Color(tint.r, tint.g, tint.b, 0.35)
	vp.add_child(edge)

	var name_label := Label.new()
	name_label.add_theme_font_override("font", font)
	name_label.add_theme_font_size_override("font_size", FONT_PX)
	name_label.add_theme_color_override("font_color",
			Color(0.95, 0.96, 0.98) if waiting else Color(0.68, 0.70, 0.74))
	name_label.position = Vector2(10, 4)
	name_label.text = str(t.get("key", "?"))
	vp.add_child(name_label)

	var state_label := Label.new()
	state_label.add_theme_font_override("font", font)
	state_label.add_theme_font_size_override("font_size", 24)
	state_label.add_theme_color_override("font_color", tint)
	state_label.position = Vector2(10, 4 + FONT_PX + 6)
	state_label.text = state
	vp.add_child(state_label)


func _quad(vp: SubViewport, size: Vector2, pos: Vector3, yaw: float) -> void:
	var mesh := QuadMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = vp.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = yaw
	add_child(mi)


func _process(_d: float) -> void:
	_frames += 1
	# A few frames of grace: SubViewport textures and the sky are not ready on
	# frame 1, and a screenshot taken then is simply black.
	if _frames < 20:
		return
	var tex := get_viewport().get_texture()
	if tex == null:
		note("no viewport texture — no rendering device?")
		get_tree().quit(2)
		return
	var img := tex.get_image()
	if img == null:
		note("viewport texture has no image")
		get_tree().quit(3)
		return
	var err := img.save_png(_shot_path)
	note("%s %s (%dx%d)" % ["saved" if err == OK else "save FAILED err=%d" % err,
			_shot_path, img.get_width(), img.get_height()])
	get_tree().quit(0 if err == OK else 1)

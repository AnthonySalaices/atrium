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

# ── Layout, from AS-0001. ⛔ The angles are not a preference: a centred 51° focus
# plus a 15° card needs ~33° of centre separation BEFORE any gutter, so the old
# focus-at-0 / rail-at-−34° had about 1° of clearance. Focus +6° / rail −30°
# buys ~3° and moves the rail closer to forward gaze.
const FOCUS_YAW_DEG := 6.0
const FOCUS_ELEV_DEG := -10.0
const RAIL_YAW_DEG := -30.0
const RAIL_DIST := 1.55
# 5.5° cards with 1.5° clear gaps. Slot 0 is RESERVED for whoever needs you.
const RAIL_ELEV_DEG := [3.0, -4.0, -11.0, -18.0]
const CARD_W_DEG := 15.0
const CARD_H_DEG := 5.5
# Text placement inside a card, in units of card height.
const TEXT_INSET_H := 0.175
const BASELINE_PRIMARY_H := -0.094     # above centre
const BASELINE_SECONDARY_H := 0.242    # below centre

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
	_build_rail()
	note("rail built")


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


## ⛔ "The terminal looks pasted onto the scene" (AS-0001). A hairline around an
## opaque black rectangle does not communicate a window. So: an actual glass
## frame with padding, a title strip of its own, and the grid inset inside it.
## ⚠️ The frame needs SIZE-AWARE tokens — the session card's .100h radius on a
## 1.26 m panel would carve away usable terminal grid.
func _build_focus_panel() -> void:
	var term := _panel_size(COLS, ROWS, DMM, PANEL_DIST)
	var pad := 0.038
	var title_h := 0.075
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	var centre := _polar(FOCUS_YAW_DEG, FOCUS_ELEV_DEG, PANEL_DIST)
	var group := _oriented_group(centre)

	var title_vp := SubViewport.new()
	# ⚠️ Match the GRID's pixels-per-metre. The first attempt sized this viewport
	# independently, so the same font size was ~3x larger here than in the
	# terminal and the glyphs were clipped straight off the top of the strip.
	# Text size only means something relative to the surface it is drawn on.
	var px_per_m := float(ROWS * CELL.y) / term.y
	var oh := outer.y * px_per_m
	title_vp.size = Vector2i(int(round(outer.x * px_per_m)), int(round(oh)))
	title_vp.transparent_bg = true
	title_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(title_vp)
	var strip_px := title_h / outer.y * oh
	var title_px := 40          # ~30 dmm: a touch larger than the 22.3 dmm body
	_baseline_label(title_vp, "glasshouse", title_px, Color(0.957, 0.969, 0.984),
			pad * px_per_m + 6.0, strip_px * 0.70)
	# ⚠️ Measure the string; a guessed fraction of the width ran off the card.
	var waiting_text := "1 waiting"
	var waiting_w := font.get_string_size(waiting_text, HORIZONTAL_ALIGNMENT_LEFT, -1, title_px).x
	_baseline_label(title_vp, waiting_text, title_px, Color(1.0, 0.722, 0.290),
			float(title_vp.size.x) - waiting_w - pad * px_per_m - 6.0, strip_px * 0.70)

	# The frame grows upward around the grid to make room for its title strip.
	_glass_in(group, outer, Vector3(0, title_h * 0.5, -0.004), {
		"radius_h": 0.025, "bezel_h": 0.0045, "falloff_h": 0.008,
		"attention": 0.0, "content": title_vp.get_texture(),
	})

	# The grid itself, inset and in front. In the real client this is a
	# composition layer, which is why it cannot be bezelled or blurred and has to
	# sit inside a separate frame surface.
	var vp := SubViewport.new()
	vp.size = Vector2i(COLS * CELL.x, ROWS * CELL.y)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var grid := CellGrid.new()
	grid.configure(COLS, ROWS, font, FONT_PX, CELL)
	vp.add_child(grid)
	_load_sample(grid)

	_glass_in(group, term, Vector3(0, 0, 0.0), {
		"radius_h": 0.012, "bezel_h": 0.003, "falloff_h": 0.006,
		"body_alpha": 0.94, "attention": 0.0, "content": vp.get_texture(),
	})


func _load_sample(grid: CellGrid) -> void:
	var f := FileAccess.open("res://data/sample.txt", FileAccess.READ)
	if f == null:
		return
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	var rows_out: Array = []
	# Fill every row by cycling the sample: a half-empty panel makes the layout
	# look better than it is, and line density is what you are judging.
	for y in range(ROWS):
		var text: String = str(lines[y % lines.size()]) if lines.size() > 0 else ""
		if text.length() < COLS:
			text += " ".repeat(COLS - text.length())
		# ⚠️ A line is {y, runs}, not a bare array — the array painted nothing.
		rows_out.append({"y": y, "runs": [[7, 0, 0, text.substr(0, COLS)]]})
	grid.apply_frame({"cols": COLS, "rows": ROWS, "base": 0, "lines": rows_out})


## Sessions that are not focused sit on a fixed rail to the left, one per slot.
##
## ⛔ **Slot 0 is reserved for whoever needs you, and nothing moves or grows.**
## The previous version lifted the waiting card up, toward the viewer and 6%
## larger, which broke the layout at exactly the moment predictability matters
## most — and crowded the terminal's reading area. The signal lives in the
## material instead: same slot, same size, brighter edge.
## ⛔ No sliver deck either. A transparent sliver is a poor counting device; the
## number was always the useful part. Four slots, then one overflow affordance.
func _build_rail() -> void:
	var rest: Array = FAKE.filter(func(s): return not bool(s.get("focus", false)))
	var waiting: Dictionary = {}
	for s in rest:
		if str(s.get("state", "")) == "needs-input":
			waiting = s
			break
	if not waiting.is_empty():
		rest.erase(waiting)

	var slots: Array = []
	if not waiting.is_empty():
		slots.append({"card": waiting, "attention": 1.0})
	for c in rest:
		if slots.size() >= RAIL_ELEV_DEG.size():
			break
		slots.append({"card": c, "attention": 0.0})

	var placed: int = slots.size()
	var leftover: int = rest.size() - (placed - (0 if waiting.is_empty() else 1))
	if leftover > 0:
		# The last slot becomes the overflow affordance rather than a session.
		slots[RAIL_ELEV_DEG.size() - 1] = {"overflow": leftover + 1}

	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		var pos := _polar(RAIL_YAW_DEG, float(RAIL_ELEV_DEG[i]), RAIL_DIST)
		var size := _angular_size(CARD_W_DEG, CARD_H_DEG, RAIL_DIST)
		if slot.has("overflow"):
			_card(pos, size, "+%d more" % int(slot["overflow"]), "", 0.0)
		else:
			var c: Dictionary = slot["card"]
			_card(pos, size, str(c.get("key", "?")), str(c.get("state", "idle")),
					float(slot["attention"]))


## Angles to a position, and angular size to metres — so the layout is specified
## the way it is actually perceived rather than in arbitrary metres.
func _polar(yaw_deg: float, elev_deg: float, dist: float) -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	var elev := deg_to_rad(elev_deg)
	return Vector3(dist * cos(elev) * sin(yaw), dist * sin(elev),
			-dist * cos(elev) * cos(yaw))


func _angular_size(w_deg: float, h_deg: float, dist: float) -> Vector2:
	return Vector2(2.0 * dist * tan(deg_to_rad(w_deg) * 0.5),
			2.0 * dist * tan(deg_to_rad(h_deg) * 0.5))


func _card(pos: Vector3, size: Vector2, title: String, state: String,
		attention: float) -> void:
	# The reference card is 329x120 for aspect 2.741; 2x for a clean flat render.
	var h_px := 240.0
	var vp := SubViewport.new()
	vp.size = Vector2i(int(round(h_px * size.x / size.y)), int(h_px))
	vp.transparent_bg = true          # the glass IS the plate
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var inset := TEXT_INSET_H * h_px
	# ⚠️ AS-0001 gives BASELINES, but a Label is positioned by its top-left, so
	# each one is offset up by the font ascent. Placing the label top at the
	# baseline drops the text a whole ascent too low.
	var primary_px := 56          # ~22.3 dmm at this card's angular height
	var secondary_px := 48
	_baseline_label(vp, title, primary_px, Color(0.957, 0.969, 0.984),
			inset, h_px * 0.5 + BASELINE_PRIMARY_H * h_px)
	if state != "":
		# ⚠️ Deliberately NOT state-tinted. Five colours to decode is worse than a
		# word you can read, and the strong edge treatment is reserved for the one
		# state that actually wants you.
		_baseline_label(vp, state, secondary_px, Color(0.882, 0.910, 0.941),
				inset, h_px * 0.5 + BASELINE_SECONDARY_H * h_px)

	_glass(size, pos, {
		"radius_h": 0.100, "bezel_h": 0.018, "falloff_h": 0.032,
		"attention": attention, "content": vp.get_texture(),
	})


func _baseline_label(vp: SubViewport, text: String, size_px: int, color: Color,
		x: float, baseline_y: float) -> void:
	var l := Label.new()
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.position = Vector2(x, baseline_y - font.get_ascent(size_px))
	l.text = text
	vp.add_child(l)


## ⚠️ A quad placed off-axis must be aimed at the eye in BOTH axes; rotating only
## around Y leaves a card above you facing the wall behind your head. `look_at`
## does yaw and pitch together, and the extra 180° is because a QuadMesh faces +Z
## while look_at aims -Z.
## ⛔ Two quads that are each aimed at the eye from slightly different positions
## are NOT coplanar, so a frame and the panel inside it stop nesting — visibly,
## as mismatched margins. Anything that must nest is aimed ONCE as a group and
## then offset in that group's local space.
func _oriented_group(pos: Vector3) -> Node3D:
	var g := Node3D.new()
	g.position = pos
	add_child(g)
	if pos.length() > 0.001:
		g.look_at(Vector3.ZERO, Vector3.UP)
		g.rotate_object_local(Vector3.UP, PI)
	return g


func _glass_in(parent: Node3D, size: Vector2, local_pos: Vector3, params: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = glass_shader
	mat.set_shader_parameter("aspect", size.x / size.y)
	for k in params:
		mat.set_shader_parameter(k, params[k])
	var mesh := QuadMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = local_pos
	parent.add_child(mi)


func _glass(size: Vector2, pos: Vector3, params: Dictionary) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = glass_shader
	# ⚠️ The SDF works in card-height units, so it needs the real quad aspect or
	# the corners stop being circular.
	mat.set_shader_parameter("aspect", size.x / size.y)
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

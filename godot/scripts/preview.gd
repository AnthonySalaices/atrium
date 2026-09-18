extends Node3D

## Flat layout preview — renders the arrangement to a PNG and quits.
##
##     godot --path godot --resolution 1280x720 -- --shot out.png [--backdrop cafe|nebula|void]
##                                                   [--crop COLSxROWS]
##
## The build host has no X server, so this is the only way to SEE a layout without
## putting the headset on: render it on a machine with a GPU and look at the file.
## Roughly 90 seconds end to end, which makes spacing, colour and glow iterable.
##
## ⚠️ **A stand-in, not a fidelity test.** `OpenXRCompositionLayer` draws nothing
## outside an XR session, so the terminal here is a textured quad — the very path
## the real client avoids. Judge LAYOUT, COLOUR, GLOW, SPACING. Never sharpness.
## ⚠️ A 104° field rendered flat also STRETCHES the frame edges, so anything near
## a corner looks bigger and more skewed than it will on the headset.
##
## ⭐ Layout, tokens and card construction come from glass_ui.gd — the same code
## the shipping client runs — so this preview cannot drift from the product.

const H_FOV := 104.0            # Quest 3, horizontal
const PANEL_DIST := 1.5
const DMM := 22.3
const COLS := 80
const ROWS := 28

# Invented sessions. Nothing here is a real project.
const FAKE := [
	{"key": "api", "state": "needs-input"},
	{"key": "billing", "state": "needs-input"},
	{"key": "docs", "state": "working"},
	{"key": "infra", "state": "working"},
	{"key": "mobile", "state": "idle"},
	{"key": "search", "state": "idle"},
	{"key": "web", "state": "idle"},
	{"key": "data", "state": "idle"},
]
const FAKE_CURRENT := "api"             # on the focus panel
const FAKE_FOCUS := "billing"           # the host's "waited longest" pick

var font: FontFile
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
	note("driver=%s" % DisplayServer.get_name())

	var cam := Camera3D.new()
	# ⚠️ `fov` is VERTICAL, and `keep_aspect = KEEP_WIDTH` does NOT change that —
	# measuring a render proved it. Convert explicitly rather than trusting it.
	# `--fov 104` reproduces the headset's field; a narrower value (say 80)
	# makes a nicer showcase image because the flat projection stops stretching
	# the edges. Layout judgements should use the default.
	var hfov := float(_arg_value("--fov", str(H_FOV)))
	cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(hfov) * 0.5) * 9.0 / 16.0))
	# The seated eye point the café was built around: the room's origin is on the
	# floor, the camera 1.2 m above it. The panels are placed relative to the eye.
	var eye := Node3D.new()
	eye.position = Vector3(0, 1.2, 0)
	add_child(eye)
	eye.add_child(cam)
	# `--yaw -6` turns the camera (not the layout) so a showcase frames the rail
	# and the window together; the layout stays where the headset puts it.
	cam.rotation.y = deg_to_rad(float(_arg_value("--yaw", "0")))

	var backdrop := Backdrop.new()
	add_child(backdrop)
	backdrop.apply({"mode": "default", "default": {"preset": _arg_value("--backdrop", "nebula")}})
	note("backdrop %s" % backdrop.preset)

	var panel := _build_focus_panel(eye)
	note("focus panel built")
	_build_rail(panel["group"], panel["outer"])
	note("rail built")


func _arg_value(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var i := args.find(flag)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback


## The same construction as terminal.gd, except the grid is a textured quad
## inside the frame instead of a composition layer.
func _build_focus_panel(eye: Node3D) -> Dictionary:
	var term := GlassUI.term_size(COLS, ROWS, DMM, PANEL_DIST)
	var pad := GlassUI.FRAME_PAD_M
	var title_h := GlassUI.FRAME_TITLE_M
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	var group := GlassUI.oriented_group(eye,
			GlassUI.polar(GlassUI.FOCUS_YAW_DEG, GlassUI.FOCUS_ELEV_DEG, PANEL_DIST))

	var px_per_m := float(ROWS * GlassUI.CELL.y) / term.y * GlassUI.UI_PX_SCALE
	var oh := outer.y * px_per_m
	var title_vp := GlassUI.content_viewport(self,
			Vector2i(int(round(outer.x * px_per_m)), int(round(oh))), false)
	var strip_px := title_h / outer.y * oh
	var title_px := GlassUI.TITLE_PX
	GlassUI.baseline_label(title_vp, font, FAKE_CURRENT, title_px, GlassUI.TEXT_PRIMARY,
			pad * px_per_m + 6.0, strip_px * 0.70)
	# `--crop 210x53` renders the badge an opted-out session gets, through the
	# same builder the client uses — the widest the strip ever gets.
	var crop := Vector2i.ZERO
	var wh := _arg_value("--crop", "").split("x")
	if wh.size() == 2:
		crop = Vector2i(int(wh[0]), int(wh[1]))
	var waiting_text := GlassUI.title_right_text(1, crop)
	var waiting_w := font.get_string_size(waiting_text, HORIZONTAL_ALIGNMENT_LEFT, -1, title_px).x
	GlassUI.baseline_label(title_vp, font, waiting_text, title_px, GlassUI.AMBER,
			float(title_vp.size.x) - waiting_w - pad * px_per_m - 6.0, strip_px * 0.70)

	var frame := GlassUI.FRAME_TOKENS.duplicate()
	frame["attention"] = 0.0
	frame["content"] = title_vp.get_texture()
	GlassUI.glass(group, outer, Vector3(0, title_h * 0.5, -0.004), frame)
	return {"group": group, "outer": outer}

	var vp := SubViewport.new()
	vp.size = Vector2i(COLS * GlassUI.CELL.x, ROWS * GlassUI.CELL.y)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)
	var grid := CellGrid.new()
	grid.configure(COLS, ROWS, font, GlassUI.FONT_PX, GlassUI.CELL)
	grid.bg_default = GlassUI.BODY
	vp.add_child(grid)
	_load_sample(grid)

	GlassUI.glass(group, term, Vector3.ZERO, {
		"radius_h": 0.012, "bezel_h": 0.003, "falloff_h": 0.006,
		"body_alpha": 0.94, "attention": 0.0, "content": vp.get_texture(),
	})


func _load_sample(grid: CellGrid) -> void:
	# `--sample <res path>` swaps the transcript, e.g. res://data/showcase.txt.
	var f := FileAccess.open(_arg_value("--sample", "res://data/sample.txt"), FileAccess.READ)
	if f == null:
		return
	var lines: Array = []
	while not f.eof_reached():
		lines.append(f.get_line())
	var rows_out: Array = []
	# Fill every row by cycling the sample: a half-empty panel makes the layout
	# look better than it is, and line density is what you are judging.
	for y in range(ROWS):
		# A showcase transcript is shown once, not cycled; the layout sample cycles
		# so every row is dense.
		var cycle := not _arg_value("--sample", "").ends_with("showcase.txt")
		var text: String = ""
		if lines.size() > 0 and (cycle or y < lines.size()):
			text = str(lines[y % lines.size()])
		if text.length() < COLS:
			text += " ".repeat(COLS - text.length())
		# ⚠️ A line is {y, runs}, not a bare array — the array painted nothing.
		rows_out.append({"y": y, "runs": [[7, 0, 0, text.substr(0, COLS)]]})
	grid.apply_frame({"cols": COLS, "rows": ROWS, "base": 0, "lines": rows_out})


func _build_rail(group: Node3D, outer: Vector2) -> void:
	var slots := GlassUI.rail_slots(FAKE, FAKE_CURRENT, FAKE_FOCUS)
	var size := GlassUI.angular_size(GlassUI.CARD_W_DEG, GlassUI.CARD_H_DEG, PANEL_DIST)
	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		var pos := GlassUI.rail_local(outer, size, i)
		if slot.has("overflow"):
			GlassUI.card(group, font, pos, size, "+%d more" % int(slot["overflow"]), "", 0.0, false)
		else:
			GlassUI.card(group, font, pos, size, str(slot["key"]), str(slot["state"]),
					float(slot["attention"]), false)


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

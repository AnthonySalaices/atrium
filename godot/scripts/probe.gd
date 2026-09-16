extends Node3D

## The spike. Four unknowns, one headset window, ~15 minutes.
##
##   1 KEYBOARD   does a physical Bluetooth keyboard deliver usable key events
##                to a Godot Android app inside an immersive OpenXR session?
##                This is the assumption the whole native decision rests on.
##   2 LEGIBILITY the same real terminal text at five dmm sizes, on a cylinder
##                layer vs a quad layer vs a flat mesh — which is sharp, and
##                what is the smallest comfortable size?
##   3 CAPABILITY what does this runtime actually support?
##   4 HANDS      do resting hands on a keyboard produce false pinches?
##
## Everything renders in-headset AND POSTs back to the host, so the analysis happens
## afterwards on a desk rather than by reading numbers through a headset.

# Host address lives in `godot/data/host.txt` (gitignored), never in source.
const PROBE_PORT := 7572
var probe_url := ""
var say_url := ""

## ⭐ DEBUG_FLAT swaps every composition layer for a textured QuadMesh.
## Composition layers are composited outside the eye buffer, so their content is
## INVISIBLE to `adb screencap` — which on 2026-09-15 meant nobody but the person
## wearing the headset could see whether anything rendered at all. In flat mode
## the same content goes through the normal renderer and screenshots work, so an
## agent can verify layout, text size and colour from the host.
## Enable with:  adb shell am start -n <pkg>/... --ez debug_flat true
##          or:  export DEBUG_FLAT=1 before launch (desktop)
var debug_flat := false

## All panels hang off this, not off XROrigin3D.
## ⚠️ center_on_hmd() moves the tracking origin — and anything parented to the
## origin moves WITH it, so the panels never change position relative to you.
## Parking them on a rig we place from the CAMERA's own transform is immune to
## reference-space semantics and is what a shipping app needs anyway.
var say_label: Label
var say_http: HTTPRequest
var say_seq := -1
var rig: Node3D
var cam: XRCamera3D

# Legibility ladder. 18 is the comfort floor from the ergonomics research,
# 22.3 the proposed default. He names the smallest he'd read for an hour.
const DMM_LADDER: Array[float] = [18.0, 20.0, 22.3, 26.0, 32.0]

const PANEL_DIST := 1.5
const PANEL_W := 0.8
const PANEL_H := 0.8
const VP_SIZE := 1024

# Keys a terminal cannot live without. The checklist turns "did it work?" into
# a list he can read off in the headset.
const CRITICAL := {
	"arrows": [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN],
	"editing": [KEY_BACKSPACE, KEY_DELETE, KEY_TAB, KEY_ESCAPE, KEY_ENTER],
	"ctrl": [KEY_C, KEY_D, KEY_R, KEY_A, KEY_E, KEY_K],
}

var xr_interface: OpenXRInterface
var http: HTTPRequest
var font: FontFile

var key_log: Array = []
var seen_plain := {}
var seen_ctrl := {}
var key_label: Label
var hands_label: Label
var caps_label: Label
var caps_report := {}
var pinch_samples := {"left": [], "right": []}
var false_pinches := 0
var elapsed := 0.0


func _ready() -> void:
	debug_flat = OS.get_environment("DEBUG_FLAT") == "1" \
		or "--debug-flat" in OS.get_cmdline_args() \
		or "--debug-flat" in OS.get_cmdline_user_args()
	if debug_flat:
		print("[probe] DEBUG_FLAT — composition layers replaced with meshes")

	font = load("res://fonts/IosevkaTerm-Medium.ttf")

	http = HTTPRequest.new()
	add_child(http)

	_boot_xr()

	var origin := XROrigin3D.new()
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	rig = Node3D.new()
	origin.add_child(rig)

	# ── row 1, eye level: the legibility comparison ──────────────────────────
	_ladder_panel(rig, "CYLINDER LAYER", -0.50, 0.0, "cylinder")
	_ladder_panel(rig, "QUAD LAYER",      0.00, 0.0, "quad")
	_ladder_panel(rig, "FLAT MESH",       0.50, 0.0, "mesh")

	# ── row 2, below: the three instrument cards ─────────────────────────────
	key_label = _card(rig, "1 KEYBOARD — type here", -0.50, -0.62)
	caps_label = _card(rig, "3 CAPABILITY", 0.0, -0.62)
	say_label = _card(rig, "MESSAGE FROM FABLE", 0.0, 0.62)
	say_label.text = "(waiting...)"
	say_http = HTTPRequest.new()
	add_child(say_http)
	say_http.request_completed.connect(_on_say)
	var h := "127.0.0.1"
	var hf := FileAccess.open("res://data/host.txt", FileAccess.READ)
	if hf != null:
		var v := hf.get_as_text().strip_edges()
		if v != "":
			h = v
	probe_url = "http://%s:%d/api/probe" % [h, PROBE_PORT]
	say_url = "http://%s:%d/api/say" % [h, PROBE_PORT]
	var t := Timer.new()
	t.wait_time = 2.0
	t.autostart = true
	add_child(t)
	t.timeout.connect(func(): say_http.request(say_url))

	hands_label = _card(rig, "4 HANDS — rest them on the keys", 0.50, -0.62)

	_collect_caps()
	caps_label.text = _caps_text()
	key_label.text = _key_text()

	_post({"kind": "session_start", "caps": caps_report})
	set_process_unhandled_key_input(true)
	# Startup recenter, deferred until the runtime has a real head pose.
	get_tree().create_timer(1.0).timeout.connect(recenter)


# ─────────────────────────────────────────────────────────────────────────────
## Put the panels wherever the user is actually looking.
## ⚠️ Without this, everything is anchored to wherever the headset happened to be
## when the app launched — which, if it was sitting on a desk, means the panels
## end up behind you at desk height. Bit us on the first hardware run.
func recenter() -> void:
	if rig == null or cam == null:
		return
	# Yaw only: match where you are looking horizontally, but keep the panels
	# level. Inheriting pitch/roll from the head makes the whole cluster tilt.
	var t := cam.transform
	var fwd := -t.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3(0, 0, -1)        # looking straight up or down
	fwd = fwd.normalized()
	rig.transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), t.origin)
	print("[probe] recentered at %s facing %s" % [t.origin, fwd])
	_post({"kind": "recenter", "elapsed": elapsed,
		   "head": [t.origin.x, t.origin.y, t.origin.z],
		   "fwd": [fwd.x, fwd.y, fwd.z]})


func _on_focus_gained() -> void:
	# The HMD pose is not trustworthy for a frame or two after focus returns.
	get_tree().create_timer(0.5).timeout.connect(recenter)


func _boot_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface and xr_interface.is_initialized():
		var vp := get_viewport()
		vp.use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		if RenderingServer.get_rendering_device():
			vp.vrs_mode = Viewport.VRS_XR
		# ⚠️ Suspects for "blurry when I move my head", reported on device:
		# fixed foveation reduces resolution off-centre on a headset with no eye
		# tracking, and 72 Hz smears during head motion. Push both.
		var rates: Array = xr_interface.get_available_display_refresh_rates()
		var want := 90.0
		if rates.has(120.0):
			want = 120.0
		elif rates.has(90.0):
			want = 90.0
		if rates.has(want):
			xr_interface.set_display_refresh_rate(want)
			caps_report["refresh_set"] = want
		xr_interface.set_foveation_level(0)
		xr_interface.set_foveation_dynamic(false)
		caps_report["foveation"] = 0
		xr_interface.session_focussed.connect(_on_focus_gained)
		xr_interface.pose_recentered.connect(recenter)
		print("[probe] OpenXR up")
	else:
		print("[probe] no OpenXR — flat mode")


## ⚠️ No Callable here. GDScript lambdas capture locals BY VALUE, so a builder
## closure cannot hand a Label back to its caller — it silently stays null.
## Returns [viewport, column] and the caller fills the column itself.
func _make_viewport() -> Array:
	var sv := SubViewport.new()
	sv.size = Vector2i(VP_SIZE, VP_SIZE)
	sv.transparent_bg = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.051, 0.067, 0.09)
	bg.size = Vector2(VP_SIZE, VP_SIZE)
	sv.add_child(bg)
	var col := VBoxContainer.new()
	col.position = Vector2(16, 12)
	col.size = Vector2(VP_SIZE - 32, VP_SIZE - 24)
	sv.add_child(col)
	return [sv, col]


## A QuadMesh carrying a SubViewport texture — what a composition layer looks
## like when it has to survive a screenshot.
func _flat_quad(parent: Node, sv: SubViewport, size: Vector2, pos: Vector3, rot_deg: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = size
	m.mesh = qm
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = sv.get_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.material_override = mat
	m.position = pos
	m.rotation_degrees = rot_deg
	parent.add_child(m)
	return m


func _mklabel(parent: Node, text: String, size_px: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


## dmm is angular, so the pixel size depends on how big the panel is and how
## far away it sits. This is the conversion everything downstream relies on.
func px_for_dmm(dmm: float, dist_m: float, panel_w_m: float, vp_px: int) -> int:
	return int(round(dmm * dist_m * float(vp_px) / (panel_w_m * 1000.0)))


func _ladder_panel(parent: Node3D, title: String, x_off: float, y_off: float, kind: String) -> void:
	var sample := _sample_lines()
	var made := _make_viewport()
	var sv: SubViewport = made[0]
	var col: VBoxContainer = made[1]

	_mklabel(col, title, 34, Color(1.0, 0.72, 0.29))
	for dmm in DMM_LADDER:
		var px := px_for_dmm(dmm, PANEL_DIST, PANEL_W, VP_SIZE)
		_mklabel(col, "%.1f dmm" % dmm, 22, Color(0.4, 0.55, 0.75))
		for i in range(2):
			_mklabel(col, sample[i % sample.size()], px, Color(0.88, 0.9, 0.92))

	var pos := Vector3(x_off, y_off, -PANEL_DIST)
	if debug_flat and kind != "mesh":
		# Still label them, so a screenshot shows which surface each WOULD be.
		_flat_quad(parent, sv, Vector2(PANEL_W, PANEL_H), pos, Vector3.ZERO)
		return
	match kind:
		"cylinder":
			var c := OpenXRCompositionLayerCylinder.new()
			c.layer_viewport = sv
			c.radius = PANEL_DIST
			c.aspect_ratio = 1.0
			c.central_angle = PANEL_W / PANEL_DIST
			c.sort_order = 1
			# ⚠️ A cylinder layer's POSITION is the centre of the cylinder and
			# `radius` is the distance out to the curved surface. Placing the node
			# PANEL_DIST in front AND setting radius = PANEL_DIST puts the surface
			# ~2x too far away, behind everything else. Centre it on the head and
			# offset horizontally by ROTATION instead.
			c.position = Vector3(0.0, y_off, 0.0)
			c.rotation.y = -atan2(x_off, PANEL_DIST)
			parent.add_child(c)
			caps_report["cylinder_native"] = c.is_natively_supported()
		"quad":
			var q := OpenXRCompositionLayerQuad.new()
			q.layer_viewport = sv
			q.quad_size = Vector2(PANEL_W, PANEL_H)
			q.sort_order = 1
			q.position = pos
			parent.add_child(q)
			caps_report["quad_native"] = q.is_natively_supported()
		"mesh":
			var m := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(PANEL_W, PANEL_H)
			m.mesh = qm
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = sv.get_texture()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			m.material_override = mat
			m.position = pos
			parent.add_child(m)


func _card(parent: Node3D, title: String, x_off: float, y_off: float) -> Label:
	var made := _make_viewport()
	var sv: SubViewport = made[0]
	var col: VBoxContainer = made[1]

	_mklabel(col, title, 38, Color(1.0, 0.72, 0.29))
	var body := _mklabel(col, "", 30, Color(0.88, 0.9, 0.92))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(VP_SIZE - 32, 0)

	if debug_flat:
		_flat_quad(parent, sv, Vector2(PANEL_W, PANEL_H * 0.6),
				Vector3(x_off, y_off, -PANEL_DIST), Vector3(-20, 0, 0))
	else:
		var q := OpenXRCompositionLayerQuad.new()
		q.layer_viewport = sv
		q.quad_size = Vector2(PANEL_W, PANEL_H * 0.6)
		q.sort_order = 1
		q.position = Vector3(x_off, y_off, -PANEL_DIST)
		q.rotation_degrees = Vector3(-20, 0, 0)
		parent.add_child(q)
	return body


## Host -> headset text, asked for mid-session on device; it is also the
## first piece of the real product's display path, streamed from the host.
func _on_say(_r: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if code != 200:
		return
	var j = JSON.parse_string(body.get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		return
	if int(j.get("seq", -1)) != say_seq:
		say_seq = int(j.get("seq", -1))
		say_label.text = str(j.get("text", ""))


func _sample_lines() -> Array:
	var f := FileAccess.open("res://data/sample.txt", FileAccess.READ)
	if f == null:
		return ["the quick brown fox jumps over the lazy dog 0123456789",
				"  Ran 1 shell command  |  esc to interrupt  ->  <- []{}"]
	var out: Array = []
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() != "":
			out.append(line)
	return out if out.size() > 0 else ["(sample.txt empty)"]


# ── 1 KEYBOARD ───────────────────────────────────────────────────────────────
func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return

	# ⭐ Reset view. F1 is unambiguous while the keyboard test is running;
	# ctrl+alt+R matches keys.recenter in config/default.lua.
	if k.keycode == KEY_F1 or (k.ctrl_pressed and k.alt_pressed and k.keycode == KEY_R):
		recenter()
		return

	# Held keys autorepeat and flood the log — 55 of the first 96 events were echoes.
	if k.echo:
		return

	var rec := {
		"keycode": k.keycode,
		"physical": k.physical_keycode,
		"unicode": k.unicode,
		"as_text": k.as_text(),
		"ctrl": k.ctrl_pressed, "alt": k.alt_pressed,
		"shift": k.shift_pressed, "meta": k.meta_pressed,
		"echo": k.echo,
		"t": elapsed,
	}
	key_log.append(rec)
	if k.ctrl_pressed:
		seen_ctrl[k.keycode] = true
	else:
		seen_plain[k.keycode] = true

	key_label.text = _key_text()
	if key_log.size() % 12 == 0:
		_post({"kind": "keys", "events": key_log.slice(max(0, key_log.size() - 12))})


func _key_text() -> String:
	var s := "events: %d\n\n" % key_log.size()
	s += "arrows  %s\n" % _tick(CRITICAL["arrows"], seen_plain)
	s += "editing %s\n" % _tick(CRITICAL["editing"], seen_plain)
	s += "ctrl+   %s\n" % _tick(CRITICAL["ctrl"], seen_ctrl)
	s += "\nlast:\n"
	for rec in key_log.slice(max(0, key_log.size() - 5)):
		var mods := ""
		if rec["ctrl"]: mods += "C-"
		if rec["alt"]: mods += "A-"
		if rec["shift"]: mods += "S-"
		s += "  %s%s  u=%d\n" % [mods, rec["as_text"], rec["unicode"]]
	if key_log.is_empty():
		s += "  (nothing yet — if this stays empty,\n   that is the answer)"
	return s


func _tick(keys: Array, seen: Dictionary) -> String:
	var got := 0
	for k in keys:
		if seen.has(k):
			got += 1
	return "%d/%d %s" % [got, keys.size(), "OK" if got == keys.size() else "..."]


# ── 3 CAPABILITY ─────────────────────────────────────────────────────────────
func _collect_caps() -> void:
	caps_report["godot"] = Engine.get_version_info()["string"]
	caps_report["os"] = OS.get_name()
	caps_report["model"] = OS.get_model_name()
	if xr_interface:
		caps_report["xr_runtime"] = xr_interface.get_name()
		caps_report["refresh_rate"] = xr_interface.get_display_refresh_rate()
		caps_report["refresh_rates"] = xr_interface.get_available_display_refresh_rates()
		caps_report["hand_tracking"] = xr_interface.is_hand_tracking_supported()
		caps_report["blend_modes"] = xr_interface.get_supported_environment_blend_modes()
		caps_report["render_target_size"] = str(xr_interface.get_render_target_size())
	else:
		caps_report["xr_runtime"] = "none"


func _caps_text() -> String:
	var s := ""
	for k in ["xr_runtime", "model", "refresh_rate", "hand_tracking",
			  "quad_native", "cylinder_native", "render_target_size"]:
		if caps_report.has(k):
			s += "%s: %s\n" % [k, str(caps_report[k])]
	if caps_report.has("refresh_rates"):
		s += "rates: %s\n" % str(caps_report["refresh_rates"])
	return s


# ── 4 HANDS ──────────────────────────────────────────────────────────────────
func _pinch(hand: String) -> float:
	var t := XRServer.get_tracker("/user/hand_tracker/" + hand) as XRHandTracker
	if t == null or not t.has_tracking_data:
		return -1.0
	var thumb := t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_THUMB_TIP)
	var index := t.get_hand_joint_transform(XRHandTracker.HAND_JOINT_INDEX_FINGER_TIP)
	return thumb.origin.distance_to(index.origin)


func _process(delta: float) -> void:
	elapsed += delta
	if Engine.get_process_frames() % 18 != 0:
		return

	var l := _pinch("left")
	var r := _pinch("right")
	# Typical pinch threshold is ~2 cm. Anything under that while the hands are
	# on the keyboard is a false positive we would have bound a gesture to.
	for pair in [["left", l], ["right", r]]:
		if pair[1] >= 0.0:
			pinch_samples[pair[0]].append(pair[1])
			if pair[1] < 0.02:
				false_pinches += 1

	hands_label.text = "left  %s\nright %s\n\nfalse pinches (<2cm): %d\nsamples: %d\n\nRest your hands on the\nkeyboard and type normally." % [
		("%.3f m" % l) if l >= 0 else "no tracking",
		("%.3f m" % r) if r >= 0 else "no tracking",
		false_pinches,
		pinch_samples["left"].size() + pinch_samples["right"].size(),
	]

	if int(elapsed) % 20 == 0 and Engine.get_process_frames() % 1080 < 18:
		_post({"kind": "heartbeat", "elapsed": elapsed,
			   "keys": key_log.size(), "false_pinches": false_pinches,
			   "pinch_min_left": _minf(pinch_samples["left"]),
			   "pinch_min_right": _minf(pinch_samples["right"])})


func _minf(a: Array) -> float:
	if a.is_empty():
		return -1.0
	var m: float = a[0]
	for v in a:
		m = min(m, v)
	return m


# ── reporting ────────────────────────────────────────────────────────────────
func _post(payload: Dictionary) -> void:
	if http == null:
		return
	var body := JSON.stringify(payload)
	http.request(probe_url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_post({"kind": "session_end", "elapsed": elapsed, "keys": key_log,
			   "false_pinches": false_pinches, "caps": caps_report})

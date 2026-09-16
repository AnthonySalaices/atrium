extends Node3D

## One real terminal panel, live from a tmux session on the host.
##
## Geometry comes from the Lua config the daemon serves, so changing
## ~/.config/glasshouse/config.lua restyles this without a rebuild.

## Which tmux session to show. Put yours in `godot/data/session.txt` (gitignored).
## ⏳ This belongs in the Lua config, which means subscribing only after the first
## `config` frame arrives rather than at _ready. Not done yet.
const SESSION_FALLBACK := "main"
var session := SESSION_FALLBACK

## The host running glassd. ⚠️ Deliberately NOT in source — put your own address in
## `godot/data/host.txt` before building (see `data/host.txt.example`). The APK
## has to know where to connect before it can be told anything over the wire,
## which is what the first-run pairing flow will eventually replace.
const HOST_FALLBACK := "127.0.0.1"

var rig: Node3D
var cam: XRCamera3D
var client: GlassClient
var grid: CellGrid
var status: Label
var font: FontFile
var viewport: SubViewport
var layer: OpenXRCompositionLayerQuad
var xr_interface: OpenXRInterface
var world_env: WorldEnvironment
var sky_mat: ShaderMaterial
var ambience: Ambience
var router: InputRouter

# The host sends sessions in a STABLE order (by name, never by urgency) so a
# panel never moves because it became urgent — see glassd/focus.py. Cycling walks
# that order locally; `focus_key` is the host's "who has waited longest" pick.
var known: Array = []
var focus_key := ""

# ⛔ An automatic recentre below this head height is almost certainly the headset
# sitting on the desk during an `adb install`, not somebody wearing it.
const MIN_HEAD_Y := 0.9

# Defaults; overwritten by the served config.
var cols := 80
var rows := 28
var dmm := 22.3          # ⭐ chosen by eye in-headset from an 18/20/22.3/26/32 ladder
var distance := 1.5


func _ready() -> void:
	# ⚠️ `--scene` is not honoured when running from a project directory (it is
	# marked export-only), and a bare positional scene path is ignored too — both
	# silently run THIS scene instead, which then sits retrying its connection
	# forever and produces no preview. So the main scene dispatches: passing
	# `--shot <path>` means "render the flat layout preview and quit".
	if OS.get_cmdline_user_args().has("--shot"):
		print("[term] --shot given, handing over to the preview scene")
		get_tree().change_scene_to_file("res://scenes/preview.tscn")
		return

	font = load("res://fonts/IosevkaTerm-Medium.ttf")
	_boot_xr()

	var origin := XROrigin3D.new()
	add_child(origin)
	cam = XRCamera3D.new()
	origin.add_child(cam)
	rig = Node3D.new()
	origin.add_child(rig)

	_build_backdrop()
	_build_panel()

	client = GlassClient.new()
	client.host = _read_data_file("host.txt", HOST_FALLBACK)
	client.token = _read_token()
	add_child(client)
	client.screen_frame.connect(_on_frame)
	client.config_changed.connect(_apply_config)
	client.link_state.connect(func(t):
		# Only show link state while it is not connected; once it is, the label
		# belongs to the switcher (session name + how many are waiting).
		if t == "connected":
			_update_status()
		else:
			status.text = t
		print("[term] link: " + t))
	client.keys_ack.connect(_on_keys_ack)
	client.sessions.connect(_on_sessions)
	client.focus_hint.connect(func(k): focus_key = k)
	client.start()
	session = _read_data_file("session.txt", SESSION_FALLBACK)
	client.subscribe(session, cols, rows)

	# M4: the panel is no longer read-only.
	router = InputRouter.new()
	add_child(router)
	router.batch.connect(_on_keys)
	set_process_unhandled_key_input(true)

	# ⚠️ The head pose is not trustworthy at _ready, hence the delay — and the
	# result still has to pass the height guard before anything is moved.
	get_tree().create_timer(1.0).timeout.connect(_auto_recenter)


var _frames := 0


func _on_frame(m: Dictionary) -> void:
	grid.apply_frame(m)
	_frames += 1
	if _key_sent_ms > 0:
		# Keypress -> the first frame that changed because of it. This is the
		# number that decides whether typing in here feels acceptable.
		print("[keys] keypress -> frame: %d ms" % (Time.get_ticks_msec() - _key_sent_ms))
		_key_sent_ms = 0
	if _frames <= 3 or _frames % 50 == 0:
		print("[term] frame #%d rev=%d base=%d lines=%d %dx%d"
				% [_frames, int(m.get("rev", 0)), int(m.get("base", -1)),
				   m.get("lines", []).size(), int(m.get("cols", 0)), int(m.get("rows", 0))])


## Somewhere that is not a place: an animated nebula sky plus a synthesised
## drone. Both procedural, because the brief asked for MOTION and ambience and
## a static CC0 cubemap can give neither (and the good CC0 drones turned out to
## be CC-BY or login-gated).
func _build_backdrop() -> void:
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/nebula_sky.gdshader")
	sky.sky_material = sky_mat
	# Radiance costs real time on mobile and a background this dim lights nothing.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = false          # ⚠️ glow is expensive on Quest and blooms text

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	ambience = Ambience.new()
	add_child(ambience)


func _apply_backdrop_config(cfg: Dictionary) -> void:
	var bd: Dictionary = cfg.get("backdrop", {})
	var mode := str(bd.get("mode", "default"))
	# ⚠️ WorldEnvironment is a plain Node, not a VisualInstance3D — it has no
	# `visible`. Switch the background mode instead.
	if world_env and world_env.environment:
		var e := world_env.environment
		if mode == "passthrough":
			e.background_mode = Environment.BG_CLEAR_COLOR
			e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		else:
			e.background_mode = Environment.BG_SKY
			e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	var dim := float(bd.get("default", {}).get("dim", 0.0))
	if sky_mat:
		sky_mat.set_shader_parameter("nebula_strength", 0.55 * (1.0 - dim))
		sky_mat.set_shader_parameter("star_brightness", 1.0 - dim * 0.7)
	var amb: Dictionary = cfg.get("ambience", {})
	if ambience:
		ambience.master = float(amb.get("volume", 0.18))
		ambience.set_enabled(bool(amb.get("enabled", true)))


func _read_token() -> String:
	# Shipped alongside the APK for now; a real build asks once and stores it.
	return _read_data_file("token.txt", "")


## ⚠️ `export_filter="all_resources"` does NOT carry plain .txt into the APK —
## the preset needs `include_filter="*.txt"` or these come back empty and every
## connection 401s forever with no clue why.
func _read_data_file(name: String, fallback: String) -> String:
	var f := FileAccess.open("res://data/" + name, FileAccess.READ)
	if f == null:
		return fallback
	var v := f.get_as_text().strip_edges()
	return v if v != "" else fallback


func _boot_xr() -> void:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface and xr_interface.is_initialized():
		var vp := get_viewport()
		vp.use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		if RenderingServer.get_rendering_device():
			vp.vrs_mode = Viewport.VRS_XR
		var rates: Array = xr_interface.get_available_display_refresh_rates()
		if rates.has(120.0):
			xr_interface.set_display_refresh_rate(120.0)
		elif rates.has(90.0):
			xr_interface.set_display_refresh_rate(90.0)
		# Foveation blurs off-centre text; a terminal is nothing but fine detail.
		xr_interface.set_foveation_level(0)
		# Re-donning the headset: automatic, so it goes through the guard.
		xr_interface.session_focussed.connect(
			func(): get_tree().create_timer(0.5).timeout.connect(_auto_recenter))
		# Long-press of the Meta button: an explicit reset binding is a shipping
		# feature, not a debug aid, so this one always fires wherever the head is.
		xr_interface.pose_recentered.connect(recenter)


## dmm is angular, so pixel size follows from panel size and distance.
func px_for_dmm(v: float, dist_m: float, panel_w_m: float, vp_px: int) -> int:
	return int(round(v * dist_m * float(vp_px) / (panel_w_m * 1000.0)))


func _build_panel() -> void:
	var cell := Vector2i(16, 40)
	var vp_w := cols * cell.x
	var vp_h := rows * cell.y

	# dmm is the FONT size, not the cell advance: 22.3 dmm <-> 32 px. So the
	# panel's angular width is vp_w * (dmm / font_px) milliradians, and the
	# physical width follows from the distance.
	# ⚠️ Dividing by cell.x instead of font_px makes every panel exactly 2x too
	# big (2.68 m instead of 1.44 m) — caught only because this prints.
	var font_px := 32.0
	var ang_rad := (dmm / font_px) * float(vp_w) / 1000.0
	var panel_w := 2.0 * distance * tan(ang_rad * 0.5)
	var panel_h := panel_w * float(vp_h) / float(vp_w)

	viewport = SubViewport.new()
	viewport.size = Vector2i(vp_w, vp_h)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	grid = CellGrid.new()
	grid.configure(cols, rows, font, 32, cell)
	viewport.add_child(grid)

	status = Label.new()
	status.add_theme_font_override("font", font)
	status.add_theme_font_size_override("font_size", 22)
	status.add_theme_color_override("font_color", Color(1.0, 0.72, 0.29))
	status.position = Vector2(4, 0)
	viewport.add_child(status)

	# ⚠️ Quad, not cylinder: the cylinder layer did not follow the rig between
	# rooms on 2026-09-15 and that is still unexplained. Quad is proven.
	layer = OpenXRCompositionLayerQuad.new()
	layer.layer_viewport = viewport
	layer.quad_size = Vector2(panel_w, panel_h)
	layer.sort_order = 1
	layer.position = Vector3(0, 0, -distance)
	rig.add_child(layer)

	print("[term] %dx%d cells, viewport %dx%d, panel %.2fm x %.2fm at %.1fm = %.1f deg wide (%.1f dmm)"
			% [cols, rows, vp_w, vp_h, panel_w, panel_h, distance, rad_to_deg(ang_rad), dmm])


func _apply_config(cfg: Dictionary) -> void:
	var f = cfg.get("font", {})
	var p = cfg.get("panels", {}).get("focus", {})
	var new_dmm := float(f.get("size_dmm", dmm))
	var new_cols := int(p.get("cols", cols))
	var new_rows := int(p.get("rows", rows))
	var new_dist := float(p.get("distance_m", distance))
	_apply_backdrop_config(cfg)
	if is_equal_approx(new_dmm, dmm) and new_cols == cols and new_rows == rows \
			and is_equal_approx(new_dist, distance):
		return
	_apply_backdrop_config(cfg)
	dmm = new_dmm
	cols = new_cols
	rows = new_rows
	distance = new_dist
	# Rebuild: cheap, and far simpler than mutating live geometry.
	if layer: layer.queue_free()
	if viewport: viewport.queue_free()
	_build_panel()
	client.resync(session)
	print("[term] config reload -> %d cols, %.1f dmm, %.2f m" % [cols, dmm, distance])


func recenter() -> void:
	if rig == null or cam == null:
		return
	var t := cam.transform
	var fwd := -t.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3(0, 0, -1)
	fwd = fwd.normalized()
	rig.transform = Transform3D(Basis.looking_at(fwd, Vector3.UP), t.origin)


var _auto_tries := 0


## Automatic recentring, with the guard. ⛔ The bug this exists for: on
## 2026-09-15 the headset lay on the desk while the app launched, so the panel
## was placed at desk height BEHIND the user — "I have to lean into the desk and
## look behind me". Every `adb install` reproduces it. An automatic recentre
## therefore waits for a plausible head height and keeps checking; an explicit
## one (ctrl+alt+R, or the Meta long-press) is never blocked.
func _auto_recenter() -> void:
	if cam == null:
		return
	var y := cam.transform.origin.y
	if y >= MIN_HEAD_Y:
		if _auto_tries > 0:
			print("[term] head at %.2f m — recentring now" % y)
		_auto_tries = 0
		recenter()
		return
	_auto_tries += 1
	if _auto_tries == 1 or _auto_tries % 10 == 0:
		print("[term] recenter deferred (try %d): head at %.2f m < %.2f — headset on a desk?"
				% [_auto_tries, y, MIN_HEAD_Y])
	if _auto_tries < 60:
		get_tree().create_timer(1.0).timeout.connect(_auto_recenter)
	else:
		print("[term] recenter gave up after %d tries — press ctrl+alt+R" % _auto_tries)


var _key_sent_ms := 0


func _on_keys(seq: Array) -> void:
	_key_sent_ms = Time.get_ticks_msec()
	client.send_keys(session, seq, _key_sent_ms)


func _on_sessions(list: Array) -> void:
	# A single-session delta arrives as a one-item list; merge rather than replace,
	# or one update would wipe every other session from the switcher.
	for item in list:
		if typeof(item) != TYPE_DICTIONARY or not item.has("key"):
			continue
		var i := _index_of(str(item["key"]))
		if i >= 0:
			known[i] = item
		else:
			known.append(item)
	known = known.filter(func(x): return str(x.get("state", "")) != "gone")
	known.sort_custom(func(a, b): return str(a.get("key", "")) < str(b.get("key", "")))
	_update_status()


func _index_of(key: String) -> int:
	for i in range(known.size()):
		if str(known[i].get("key", "")) == key:
			return i
	return -1


func waiting_count() -> int:
	var n := 0
	for x in known:
		if str(x.get("state", "")) in ["needs-input", "error", "done"] or bool(x.get("unread", false)):
			n += 1
	return n


func _update_status() -> void:
	if status == null:
		return
	var n := waiting_count()
	status.text = session + ("   %d waiting" % n if n > 0 else "")


## Show a different session on the focus panel.
func switch_to(key: String) -> void:
	if key == "" or key == session:
		return
	client.unsubscribe(session)          # lets the host restore its geometry
	session = key
	if grid:
		grid.clear()                     # never show the old session's text
	client.subscribe(session, cols, rows)
	_update_status()
	print("[term] switched to %s" % session)


func cycle_session(delta: int) -> void:
	if known.is_empty():
		return
	var keys: Array = known.map(func(x): return str(x.get("key", "")))
	var i := keys.find(session)
	if i < 0:
		switch_to(str(keys[0]))
	else:
		switch_to(str(keys[(i + delta + keys.size()) % keys.size()]))


## ⭐ The one that matters: go straight to whoever has been waiting longest.
## A glow you cannot act on is a notification with no button.
func jump_to_glow() -> void:
	if focus_key != "" and focus_key != session:
		switch_to(focus_key)
	elif focus_key == "":
		print("[term] nobody is waiting")


func _on_keys_ack(m: Dictionary) -> void:
	var t := int(m.get("t", 0))
	if t > 0:
		print("[keys] %d item(s) acked in %d ms" % [int(m.get("n", 0)),
				Time.get_ticks_msec() - t])


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	# Local bindings first — these must never reach the pane. Autorepeat is
	# ignored for them, but PASSED THROUGH for typing.
	# ⚠️ Keychron V1 Max sends media keys on the F-row by default, so plain F1
	# never arrives; ctrl+alt+R is the primary binding (and `keys.recenter`).
	if not k.echo and k.ctrl_pressed and k.alt_pressed:
		# ⚠️ These are matched before the router runs, so a binding never also
		# gets typed into the pane. They mirror `keys` in config/default.lua;
		# ⏳ parsing those strings into keycodes is not done yet, so the defaults
		# are hardcoded here and the config values are currently decorative.
		match k.keycode:
			KEY_R:
				recenter()
				return
			KEY_RIGHT:
				cycle_session(+1)
				return
			KEY_LEFT:
				cycle_session(-1)
				return
			KEY_SPACE:
				jump_to_glow()
				return
	if not k.echo and k.keycode == KEY_F1:
		recenter()
		return
	if router != null:
		router.feed(k)

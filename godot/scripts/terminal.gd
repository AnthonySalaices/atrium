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
var font: FontFile
var viewport: SubViewport
var layer: OpenXRCompositionLayerQuad
var xr_interface: OpenXRInterface
var backdrop: Backdrop
var ambience: Ambience
var router: InputRouter

# The focus window: an oriented group holding the glass frame (in-scene geometry,
# with the title strip drawn into its texture) and the composition layer inset
# inside it. ⚠️ The layer composites OVER the scene and never depth-sorts, so
# the frame simply sits 4 mm behind it — that IS the hybrid AS-0001 asked for.
var focus_group: Node3D
var frame_vp: SubViewport
var title_left: Label
var title_right: Label
var link_text := ""              # non-empty while not connected

# Sessions that opted out of pinning (`glasshouse pin off`) are never resized on
# the host; we get the bottom-left crop of a desktop-sized pane instead, flagged
# `cropped: [cols, rows]`. Say so in the strip — without it the missing right-hand
# columns read as a rendering bug. Keyed by session: a late frame from the one we
# just left must not relabel the one we are looking at.
var _cropped := {}               # session key -> Vector2i(cols, rows) of the real pane

# The rail of session cards to the left. Rebuilt whenever the session list
# changes; cheap, and far simpler than diffing four quads.
var rail_root: Node3D
var waiting_cards: Array = []    # ShaderMaterials whose edge breathes

# First-run pairing. The APK ships no host and no token; they come from the
# pairing card (stored in user://) or, for a dev build, from res://data/*.txt.
var pairing: Pairing
var linked := false
var pulse_enabled := true
var _t := 0.0

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
var pitch_deg := GlassUI.FOCUS_ELEV_DEG


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
	rail_root = Node3D.new()
	rig.add_child(rail_root)

	client = GlassClient.new()
	add_child(client)
	client.screen_frame.connect(_on_frame)
	client.config_changed.connect(_apply_config)
	client.link_state.connect(func(t):
		# Only show link state while it is not connected; once it is, the label
		# belongs to the switcher (session name + how many are waiting).
		link_text = "" if t == "connected" else t
		_update_status()
		print("[term] link: " + t))
	client.keys_ack.connect(_on_keys_ack)
	client.sessions.connect(_on_sessions)
	client.focus_hint.connect(func(k):
		if k != focus_key:
			focus_key = k
			_rebuild_rail())
	session = _read_data_file("session.txt", SESSION_FALLBACK)

	# Where do we connect? user:// (paired) beats res://data (dev build) beats
	# nothing (show the pairing card).
	var saved := Pairing.load_saved()
	if saved.is_empty():
		var h := _read_data_file("host.txt", "")
		var t := _read_token()
		if h != "" and t != "":
			saved = {"host": h, "port": 7570, "token": t}
	if saved.is_empty():
		_show_pairing()
	else:
		_link(str(saved["host"]), int(saved.get("port", 7570)), str(saved["token"]))

	# M4: the panel is no longer read-only.
	router = InputRouter.new()
	add_child(router)
	router.batch.connect(_on_keys)
	set_process_unhandled_key_input(true)

	# ⚠️ The head pose is not trustworthy at _ready, hence the delay — and the
	# result still has to pass the height guard before anything is moved.
	get_tree().create_timer(1.0).timeout.connect(_auto_recenter)


var _frames := 0


## Connect with known credentials.
func _link(h: String, p: int, t: String) -> void:
	client.host = h
	client.port = p
	client.token = t
	if not linked:
		client.start()
		linked = true
	else:
		client.reconnect()
	client.subscribe(session, cols, rows)
	_update_status()


func _show_pairing() -> void:
	if pairing != null:
		return
	pairing = Pairing.new()
	pairing.font = font
	rig.add_child(pairing)
	# ⛔ The terminal is a composition layer and draws OVER scene geometry, so a
	# card placed where the window is would be invisible behind the text. The
	# window steps aside while pairing; it is modal anyway.
	if focus_group:
		focus_group.visible = false
	if layer:
		layer.visible = false
	if rail_root:
		rail_root.visible = false
	pairing.paired.connect(func(h, p, t):
		print("[pair] paired with %s:%d" % [h, p])
		_hide_pairing()
		_link(h, p, t))
	pairing.cancelled.connect(func():
		if linked:
			_hide_pairing()
		else:
			print("[pair] nothing to cancel to — no host known yet"))
	link_text = "not paired"
	_update_status()


func _hide_pairing() -> void:
	if pairing:
		pairing.queue_free()
		pairing = null
	if focus_group:
		focus_group.visible = true
	if layer:
		layer.visible = true
	if rail_root:
		rail_root.visible = true


func _on_frame(m: Dictionary) -> void:
	grid.apply_frame(m)
	_frames += 1
	_note_crop(str(m.get("key", session)), m.get("cropped", null))
	if _key_sent_ms > 0:
		# Keypress -> the first frame that changed because of it. This is the
		# number that decides whether typing in here feels acceptable.
		print("[keys] keypress -> frame: %d ms" % (Time.get_ticks_msec() - _key_sent_ms))
		_key_sent_ms = 0
	if _frames <= 3 or _frames % 50 == 0:
		print("[term] frame #%d rev=%d base=%d lines=%d %dx%d"
				% [_frames, int(m.get("rev", 0)), int(m.get("base", -1)),
				   m.get("lines", []).size(), int(m.get("cols", 0)), int(m.get("rows", 0))])


## Every frame of an opted-out session carries the flag, so its absence clears
## the badge. ⚠️ Only touch the strip when the state actually changes: it is an
## UPDATE_ONCE viewport and re-arming it 12x a second re-renders it 12x a second.
func _note_crop(key: String, flag: Variant) -> void:
	var had := _cropped.has(key)
	var have := flag is Array and (flag as Array).size() >= 2
	var now := Vector2i.ZERO
	if have:
		var a: Array = flag
		now = Vector2i(int(a[0]), int(a[1]))
	if had == have and (not have or _cropped[key] == now):
		return
	if have:
		_cropped[key] = now
	else:
		_cropped.erase(key)
	if key == session:
		_update_status()


## The room behind the glass — see backdrop.gd for the presets. The ambience is
## still synthesised here; it never loops and carries no licence.
func _build_backdrop() -> void:
	backdrop = Backdrop.new()
	add_child(backdrop)
	ambience = Ambience.new()
	add_child(ambience)


func _apply_backdrop_config(cfg: Dictionary) -> void:
	if backdrop:
		backdrop.apply(cfg.get("backdrop", {}))
	var amb: Dictionary = cfg.get("ambience", {})
	if ambience:
		ambience.set_config(amb)
	# "none" = no motion; anything else breathes. Reduced-motion users set none.
	var ni: Dictionary = cfg.get("glow", {}).get("states", {}).get("needs_input", {})
	pulse_enabled = str(ni.get("pulse", "breathe")) != "none"


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
	var cell := GlassUI.CELL
	var vp_w := cols * cell.x
	var vp_h := rows * cell.y
	# ⚠️ The status text used to live on an extra row INSIDE the terminal layer.
	# AS-0001 moved it onto the frame's own title strip, so the layer is now
	# exactly the grid and nothing else.
	var term := GlassUI.term_size(cols, rows, dmm, distance)

	viewport = SubViewport.new()
	viewport.size = Vector2i(vp_w, vp_h)
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	grid = CellGrid.new()
	grid.configure(cols, rows, font, GlassUI.FONT_PX, cell)
	# Same body colour as the frame, so layer and frame read as one slab.
	grid.bg_default = GlassUI.BODY
	viewport.add_child(grid)

	# Aim the whole window once, then place frame and layer in its local space.
	focus_group = GlassUI.oriented_group(rig,
			GlassUI.polar(GlassUI.FOCUS_YAW_DEG, pitch_deg, distance))

	# The frame grows upward around the grid to make room for its title strip.
	var pad := GlassUI.FRAME_PAD_M
	var title_h := GlassUI.FRAME_TITLE_M
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	# ⚠️ Match the GRID's pixels-per-metre, or the same font size comes out ~3x
	# larger on the strip and clips off the top of it.
	var px_per_m := float(vp_h) / term.y
	var oh := outer.y * px_per_m
	frame_vp = GlassUI.content_viewport(self,
			Vector2i(int(round(outer.x * px_per_m)), int(round(oh))), true)
	var strip_px := title_h / outer.y * oh
	var title_px := 40          # ~30 dmm: a touch larger than the 22.3 dmm body
	title_left = GlassUI.baseline_label(frame_vp, font, session, title_px,
			GlassUI.TEXT_PRIMARY, pad * px_per_m + 6.0, strip_px * 0.70)
	title_right = GlassUI.baseline_label(frame_vp, font, "", title_px,
			GlassUI.AMBER, 0.0, strip_px * 0.70)
	var params := GlassUI.FRAME_TOKENS.duplicate()
	params["attention"] = 0.0
	params["content"] = frame_vp.get_texture()
	GlassUI.glass(focus_group, outer, Vector3(0, title_h * 0.5, -0.004), params)

	# ⚠️ Quad, not cylinder: the cylinder layer did not follow the rig between
	# rooms on 2026-09-15 and that is still unexplained. Quad is proven.
	layer = OpenXRCompositionLayerQuad.new()
	layer.layer_viewport = viewport
	layer.quad_size = term
	layer.sort_order = 1
	focus_group.add_child(layer)
	_update_status()

	var ang_rad := (dmm / float(GlassUI.FONT_PX)) * float(vp_w) / 1000.0
	print("[term] %dx%d cells, viewport %dx%d, panel %.2fm x %.2fm at %.1fm = %.1f deg wide (%.1f dmm), yaw %.0f pitch %.0f"
			% [cols, rows, vp_w, vp_h, term.x, term.y, distance, rad_to_deg(ang_rad), dmm,
			   GlassUI.FOCUS_YAW_DEG, pitch_deg])


## The cards: every session that is not on the focus panel, in the host's stable
## order, slot 0 reserved for whoever the host says has waited longest.
func _rebuild_rail() -> void:
	if rail_root == null:
		return
	for c in rail_root.get_children():
		c.queue_free()
	waiting_cards.clear()
	var slots := GlassUI.rail_slots(known, session, focus_key)
	var size := GlassUI.angular_size(GlassUI.CARD_W_DEG, GlassUI.CARD_H_DEG, GlassUI.RAIL_DIST)
	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		var pos := GlassUI.polar(GlassUI.RAIL_YAW_DEG, float(GlassUI.RAIL_ELEV_DEG[i]),
				GlassUI.RAIL_DIST)
		if slot.has("overflow"):
			GlassUI.card(rail_root, font, pos, size, "+%d more" % int(slot["overflow"]), "", 0.0)
			continue
		var c := GlassUI.card(rail_root, font, pos, size, str(slot["key"]),
				str(slot["state"]), float(slot["attention"]))
		if float(slot["attention"]) > 0.5:
			waiting_cards.append((c["mesh"] as MeshInstance3D).material_override)


## Attention motion: the amber edge breathes on cards that are waiting on you.
## Never to zero, never on cards that are not, and off entirely when the config
## says `pulse = "none"`.
func _process(delta: float) -> void:
	if waiting_cards.is_empty():
		return
	_t += delta
	var g := GlassUI.pulse_gain(_t) if pulse_enabled else GlassUI.PULSE_GAIN_HI
	for m in waiting_cards:
		if m:
			m.set_shader_parameter("gain_attention", g)


func _apply_config(cfg: Dictionary) -> void:
	var f = cfg.get("font", {})
	var p = cfg.get("panels", {}).get("focus", {})
	var new_dmm := float(f.get("size_dmm", dmm))
	var new_cols := int(p.get("cols", cols))
	var new_rows := int(p.get("rows", rows))
	var new_dist := float(p.get("distance_m", distance))
	var new_pitch := float(p.get("pitch_deg", pitch_deg))
	_apply_backdrop_config(cfg)
	if is_equal_approx(new_dmm, dmm) and new_cols == cols and new_rows == rows \
			and is_equal_approx(new_dist, distance) and is_equal_approx(new_pitch, pitch_deg):
		return
	dmm = new_dmm
	cols = new_cols
	rows = new_rows
	distance = new_dist
	pitch_deg = new_pitch
	# Rebuild: cheap, and far simpler than mutating live geometry.
	if focus_group: focus_group.queue_free()
	if viewport: viewport.queue_free()
	if frame_vp: frame_vp.queue_free()
	_build_panel()
	_rebuild_rail()
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
	if backdrop:
		backdrop.anchor(rig.transform)


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
	_rebuild_rail()


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
	if title_left == null or frame_vp == null:
		return
	title_left.text = link_text if link_text != "" else session
	var crop: Vector2i = _cropped.get(session, Vector2i.ZERO)
	var right := GlassUI.title_right_text(waiting_count(), crop)
	title_right.text = right
	# ⚠️ Measure the string; a guessed fraction of the width runs off the frame.
	var title_px := 40
	var w := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, title_px).x
	var pad_px := float(frame_vp.size.y) / (GlassUI.term_size(cols, rows, dmm, distance).y \
			+ GlassUI.FRAME_PAD_M * 2.0 + GlassUI.FRAME_TITLE_M) * GlassUI.FRAME_PAD_M
	title_right.position.x = float(frame_vp.size.x) - w - pad_px - 6.0
	# The strip only re-renders when its text changes.
	frame_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


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
	_rebuild_rail()
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
	# ⚠️ A keyboard in Mac mode sends Option as Alt but many people reach for
	# Command; accept either as the chord modifier.
	if not k.echo and k.ctrl_pressed and (k.alt_pressed or k.meta_pressed):
		# ⚠️ These are matched before the router runs, so a binding never also
		# gets typed into the pane. They mirror `keys` in config/default.lua;
		# ⏳ parsing those strings into keycodes is not done yet, so the defaults
		# are hardcoded here and the config values are currently decorative.
		match k.keycode:
			KEY_R:
				recenter()
				return
			KEY_P:
				# Re-pair: a new host, a new code. Works with or without a link.
				_show_pairing()
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
	# ⛔ While the pairing card is up, every key belongs to it. Nothing typed
	# there may reach a tmux pane.
	if pairing != null:
		pairing.feed(k)
		return
	if not k.echo and k.keycode == KEY_F1:
		recenter()
		return
	if router != null and router.feed(k) and ambience != null:
		# The click belongs to keys that actually reach a pane, so a chord the
		# router refused stays silent instead of sounding like it typed.
		ambience.click()

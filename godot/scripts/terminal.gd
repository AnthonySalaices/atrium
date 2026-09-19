extends Node3D

## One real terminal panel, live from a tmux session on the host.
##
## Geometry comes from the Lua config the daemon serves, so changing
## ~/.config/atrium/config.lua restyles this without a rebuild.

## Which tmux session to show. Put yours in `godot/data/session.txt` (gitignored).
## ⏳ This belongs in the Lua config, which means subscribing only after the first
## `config` frame arrives rather than at _ready. Not done yet.
const SESSION_FALLBACK := "main"
var session := SESSION_FALLBACK

## The host running atriumd. ⚠️ Deliberately NOT in source — put your own address in
## `godot/data/host.txt` before building (see `data/host.txt.example`). The APK
## has to know where to connect before it can be told anything over the wire,
## which is what the first-run pairing flow will eventually replace.
const HOST_FALLBACK := "127.0.0.1"

var rig: Node3D
var xr_origin: XROrigin3D
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
var pointers: Pointers

# The focus window: an oriented group holding the glass frame (in-scene geometry,
# with the title strip drawn into its texture) and the composition layer inset
# inside it. ⚠️ The layer composites OVER the scene and never depth-sorts, so
# the frame simply sits 4 mm behind it — that IS the hybrid AS-0001 asked for.
var focus_group: Node3D
var frame_mesh: MeshInstance3D
var frame_outer := Vector2.ZERO
# Where the user dragged the focus window to, rig-relative; ZERO = the config's
# default place. Survives a config rebuild, cleared by an explicit recentre —
# which is also the way to undo a bad drop.
var _focus_override := Vector3.ZERO
# A size the user chose with the thumbstick, in dmm; 0 = the config's font size.
var _dmm_override := 0.0
var hover_dot: ColorRect          # drawn INTO the terminal layer, see Pointers
var frame_vp: SubViewport
var title_left: Label
var title_right: Label
var link_text := ""              # non-empty while not connected

# Sessions that opted out of pinning (`atrium pin off`) are never resized on
# the host; we get the bottom-left crop of a desktop-sized pane instead, flagged
# `cropped: [cols, rows]`. Say so in the strip — without it the missing right-hand
# columns read as a rendering bug. Keyed by session: a late frame from the one we
# just left must not relabel the one we are looking at.
# Browser mode: a web app replaces the grid with its frames, in the SAME layer.
var web_rect: TextureRect
var _web_tex: ImageTexture
var _web_css := Vector2(1280, 800)   # the page's CSS size, for mapping clicks
var _web_decoding := false
var _web_pending = null              # newest frame that arrived mid-decode
var _web_hover := Vector2i(-1, -1)
var _button_groups: Array = []   # [Node3D], index = button_local slot
var _close_armed_ms := 0          # Close waits for a second tap until this time
const CLOSE_CONFIRM_MS := 3000
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
# panel never moves because it became urgent — see atriumd/focus.py. Cycling walks
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

	_set_font("Iosevka Term", 1.25)
	_boot_xr()

	var origin := XROrigin3D.new()
	add_child(origin)
	xr_origin = origin
	cam = XRCamera3D.new()
	origin.add_child(cam)
	rig = Node3D.new()
	origin.add_child(rig)

	_build_backdrop()
	_build_panel()
	# Controllers / hands. ⚠️ Must be a child of the XROrigin3D, not the rig:
	# tracker poses are origin-relative and the rig moves on every recentre.
	pointers = Pointers.new()
	origin.add_child(pointers)
	pointers.card_selected.connect(_on_card_selected)
	pointers.menu_pressed.connect(toggle_settings)
	pointers.overflow_selected.connect(func(): cycle_session(+1))
	pointers.focus_moved.connect(_on_focus_dragged)
	pointers.focus_resized.connect(_on_focus_resized)
	pointers.scroll.connect(func(lines, col, row):
		client.send_scroll(session, lines, col, row, _page_uv(_cell_uv(col, row))))
	pointers.surface_tap.connect(_on_surface_tap)
	pointers.grid_hover.connect(_on_grid_hover)
	_push_pointer_targets()

	client = GlassClient.new()
	add_child(client)
	client.screen_frame.connect(_on_frame)
	client.config_changed.connect(_apply_config)
	client.settings_changed.connect(_on_settings)
	client.link_state.connect(func(t):
		# Only show link state while it is not connected; once it is, the label
		# belongs to the switcher (session name + how many are waiting).
		link_text = "" if t == "connected" else t
		_update_status()
		print("[term] link: " + t))
	client.keys_ack.connect(_on_keys_ack)
	client.scroll_ack.connect(func(m):
		if m.has("skipped"):
			print("[scroll] skipped: %s" % str(m["skipped"])))
	client.sessions.connect(_on_sessions)
	client.web_frame.connect(_on_web_frame)
	client.session_removed.connect(_on_session_removed)
	client.session_created.connect(func(k): if k != "": switch_to(k))
	client.focus_hint.connect(func(k):
		if k != focus_key:
			focus_key = k
			_rebuild_rail())
	client.session_missing.connect(_on_session_missing)
	# The session you were last on, else the dev build's session.txt. Checked
	# against the host's list when it arrives (_ensure_session): a session
	# closed since the last run must not greet you with an error.
	session = _read_last_session()

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
	# A custom backdrop comes from the same daemon over plain HTTP, so it needs
	# the same three things the socket does.
	if backdrop:
		backdrop.set_source(h, p, t)
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
	if pointers:
		pointers.enabled = false
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
	if pointers:
		pointers.enabled = _pointer_cfg.get("enabled", true)


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


## Refresh rate (the nearest the runtime offers, never above the ask) and fixed
## foveation. ⚠️ Foveation blurs off-centre text, and a terminal is nothing but
## fine detail — hence default 0; heavy rooms may want 1-2 for frame time.
func _apply_comfort(hz: int, fov: int) -> void:
	if xr_interface == null or not xr_interface.is_initialized():
		return
	var best := 0.0
	for r in xr_interface.get_available_display_refresh_rates():
		if float(r) <= float(hz) + 0.5 and float(r) > best:
			best = float(r)
	if best > 0.0 and not is_equal_approx(xr_interface.get_display_refresh_rate(), best):
		xr_interface.set_display_refresh_rate(best)
		print("[term] refresh %d Hz" % int(best))
	xr_interface.set_foveation_level(clampi(fov, 0, 4))


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
		_apply_comfort(120, 0)
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
	var cell := GlassUI.cell
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
	# The scheme's background is also the frame's body (GlassUI.body), so layer
	# and frame read as one slab whatever the colours are.
	_apply_colors()
	viewport.add_child(grid)

	web_rect = TextureRect.new()
	web_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	web_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	web_rect.size = Vector2(vp_w, vp_h)
	web_rect.texture = _web_tex if is_web() else null
	viewport.add_child(web_rect)
	_show_surface()

	# The pointer's hover dot lives in the layer's own pixels, hidden until a
	# ray crosses the text. One cell, amber, translucent.
	hover_dot = ColorRect.new()
	hover_dot.color = Color(GlassUI.AMBER, 0.45)
	hover_dot.size = Vector2(cell.x, cell.y)
	hover_dot.visible = false
	viewport.add_child(hover_dot)

	# Aim the whole window once, then place frame and layer in its local space.
	focus_group = GlassUI.oriented_group(rig, _focus_override if _focus_override != Vector3.ZERO
			else GlassUI.polar(GlassUI.FOCUS_YAW_DEG, pitch_deg, distance))

	# The frame grows upward around the grid to make room for its title strip.
	var pad := GlassUI.FRAME_PAD_M
	var title_h := GlassUI.FRAME_TITLE_M
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	# ⚠️ Match the GRID's pixels-per-metre, or the same font size comes out ~3x
	# larger on the strip and clips off the top of it.
	var px_per_m := float(vp_h) / term.y * GlassUI.UI_PX_SCALE
	var oh := outer.y * px_per_m
	frame_vp = GlassUI.content_viewport(self,
			Vector2i(int(round(outer.x * px_per_m)), int(round(oh))), true)
	var strip_px := title_h / outer.y * oh
	var title_px := GlassUI.TITLE_PX   # ~30 dmm: a touch larger than the 22.3 dmm body
	title_left = GlassUI.baseline_label(frame_vp, font, session, title_px,
			GlassUI.TEXT_PRIMARY, pad * px_per_m + 6.0, strip_px * 0.70)
	title_right = GlassUI.baseline_label(frame_vp, font, "", title_px,
			GlassUI.AMBER, 0.0, strip_px * 0.70)
	var params := GlassUI.FRAME_TOKENS.duplicate()
	params["attention"] = 0.0
	params["content"] = frame_vp.get_texture()
	params["body_color"] = GlassUI.body
	frame_mesh = GlassUI.glass(focus_group, outer, Vector3(0, title_h * 0.5, -0.004), params)
	frame_outer = outer
	# The rail lives INSIDE the focus group so it moves and resizes with it.
	rail_root = Node3D.new()
	focus_group.add_child(rail_root)

	# ⚠️ Quad, not cylinder: the cylinder layer did not follow the rig between
	# rooms on 2026-09-15 and that is still unexplained. Quad is proven.
	layer = OpenXRCompositionLayerQuad.new()
	layer.layer_viewport = viewport
	layer.quad_size = term
	layer.sort_order = 1
	focus_group.add_child(layer)
	_update_status()
	_push_pointer_targets()

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
	var size := GlassUI.angular_size(GlassUI.CARD_W_DEG, GlassUI.CARD_H_DEG, distance)
	var k := _card_scale()
	_card_targets.clear()
	_card_groups.clear()
	for i in range(slots.size()):
		var slot: Dictionary = slots[i]
		var pos := GlassUI.rail_local(frame_outer, size * k, i)
		if slot.has("overflow"):
			var o := GlassUI.card(rail_root, font, pos, size, "+%d more" % int(slot["overflow"]), "", 0.0, false)
			_card_targets.append({"mesh": o["mesh"], "size": size, "overflow": true})
			(o["group"] as Node3D).scale = Vector3.ONE * k
			_card_groups.append(o["group"])
			continue
		var c := GlassUI.card(rail_root, font, pos, size, str(slot["key"]),
				str(slot["state"]), float(slot["attention"]), false)
		_card_targets.append({"mesh": c["mesh"], "size": size, "key": str(slot["key"])})
		(c["group"] as Node3D).scale = Vector3.ONE * k
		_card_groups.append(c["group"])
		if float(slot["attention"]) > 0.5:
			waiting_cards.append((c["mesh"] as MeshInstance3D).material_override)
	_build_buttons(k)
	_build_settings(k)
	if pointers:
		pointers.set_cards(_card_targets)


## New / Close under the window. They ride in the rail's list of pointer
## targets with reserved keys, so the pointer needs no new gesture.
func _build_buttons(k: float) -> void:
	_button_groups.clear()
	var size := GlassUI.angular_size(GlassUI.BUTTON_W_DEG, GlassUI.BUTTON_H_DEG, distance)
	var armed := Time.get_ticks_msec() < _close_armed_ms
	var specs := [["__close", "Confirm?" if armed else "Close", 1.0 if armed else 0.0],
			["__new", "+ New", 0.0]]
	if is_web():
		specs = [["__reload", "Reload", 0.0], ["__back", "Back", 0.0]]
	specs.append(["__settings", "Settings", 1.0 if _settings_open else 0.0])
	for i in range(specs.size()):
		var b := GlassUI.button(rail_root, font, GlassUI.button_local(frame_outer, size * k, i),
				size, specs[i][1], specs[i][2])
		(b["group"] as Node3D).scale = Vector3.ONE * k
		_button_groups.append(b["group"])
		_card_targets.append({"mesh": b["mesh"], "size": size, "key": specs[i][0]})


func _on_card_selected(key: String) -> void:
	if key.begins_with("__st:"):
		_on_settings_tap(key.substr(5))
		return
	match key:
		"__settings":
			toggle_settings()
		"__new":
			client.new_session()
		"__back":
			client.send_web_nav(session, "back")
		"__reload":
			client.send_web_nav(session, "reload")
		"__close":
			if Time.get_ticks_msec() < _close_armed_ms:
				_close_armed_ms = 0
				client.close_session(session)
			else:
				# ⛔ Closing kills whatever agent runs there, so one stray trigger
				# pull must never do it: the first tap only asks.
				_close_armed_ms = Time.get_ticks_msec() + CLOSE_CONFIRM_MS
				get_tree().create_timer(CLOSE_CONFIRM_MS / 1000.0 + 0.05).timeout.connect(_rebuild_rail)
			_rebuild_rail()
		_:
			switch_to(key)


func _on_session_removed(key: String) -> void:
	var i := _index_of(key)
	if i >= 0:
		known.remove_at(i)
	if key == session:
		var next := ""
		for x in known:
			next = str(x.get("key", ""))
			if next != "":
				break
		if next != "":
			switch_to(next)
		elif grid:
			grid.clear()
	_update_status()
	_rebuild_rail()


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


var _last_cfg := {}


func _apply_config(cfg: Dictionary) -> void:
	_last_cfg = cfg
	var f = cfg.get("font", {})
	var p = cfg.get("panels", {}).get("focus", {})
	var new_dmm := _dmm_override if _dmm_override > 0.0 else float(f.get("size_dmm", dmm))
	var new_cols := int(p.get("cols", cols))
	var new_rows := int(p.get("rows", rows))
	var new_dist := float(p.get("distance_m", distance))
	var new_pitch := float(p.get("pitch_deg", pitch_deg))
	var font_changed := _set_font(str(f.get("family", "Iosevka Term")),
			float(f.get("line_height", 1.25)))
	_apply_backdrop_config(cfg)
	if _apply_colors() and frame_mesh:
		frame_mesh.material_override.set_shader_parameter("body_color", GlassUI.body)
		_rebuild_rail()
	var cf: Dictionary = cfg.get("comfort", {})
	_apply_comfort(int(cf.get("refresh_hz", 120)), int(cf.get("foveation", 0)))
	_pointer_cfg = cfg.get("pointer", {})
	if pointers:
		pointers.set_config(_pointer_cfg,
				int(cfg.get("comfort", {}).get("typing_lockout_ms", 1500)))
		if pairing != null:
			pointers.enabled = false
	if not font_changed and is_equal_approx(new_dmm, dmm) and new_cols == cols and new_rows == rows \
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


var _font_key := ""


## Load the bundled face `family` names and measure its cell. Returns true when
## anything changed (the caller rebuilds the panel). ⚠️ Only JetBrains gets a
## fallback (Iosevka), never the reverse — two fonts falling back to each other
## is a cycle.
func _set_font(family: String, line_height: float) -> bool:
	line_height = clampf(line_height, 1.0, 2.0)
	var path := GlassUI.font_path(family)
	var key := "%s@%.3f" % [path, line_height]
	if key == _font_key:
		return false
	_font_key = key
	font = load(path)
	if path != GlassUI.FONT_IOSEVKA and font.fallbacks.is_empty():
		font.fallbacks = [load(GlassUI.FONT_IOSEVKA)]
	GlassUI.cell = GlassUI.measure_cell(font, line_height)
	print("[term] font %s, cell %s" % [path.get_file(), GlassUI.cell])
	return true


# ── browser mode ────────────────────────────────────────────────────────────

func is_web() -> bool:
	return session.begins_with("web:")


## The grid stays visible under a page as a blank, cursor-less backdrop, so
## the letterbox bars beside a phone-width app are the scheme's background.
func _show_surface() -> void:
	if grid and is_web():
		grid.clear()
		grid.cursor_visible = false
	if web_rect:
		web_rect.visible = is_web()


## JPEG decode is off the main thread: a 860x1720 frame costs several ms and
## the Quest renders at 72+ Hz. Newest-frame-wins while one is decoding.
func _on_web_frame(msg: Dictionary) -> void:
	if str(msg.get("key", "")) != session:
		return
	if _web_decoding:
		_web_pending = msg
		return
	_web_decoding = true
	WorkerThreadPool.add_task(_decode_web.bind(msg))


func _decode_web(msg: Dictionary) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(Marshalls.base64_to_raw(str(msg.get("jpeg", ""))))
	call_deferred("_web_decoded", img if err == OK else null, str(msg.get("key", "")),
			Vector2(float(msg.get("css_w", 1280)), float(msg.get("css_h", 800))))


func _web_decoded(img: Image, key: String, css: Vector2) -> void:
	_web_decoding = false
	if img != null and key == session:
		if _web_tex != null and Vector2i(_web_tex.get_size()) == img.get_size():
			_web_tex.update(img)
		else:
			_web_tex = ImageTexture.create_from_image(img)
			if web_rect:
				web_rect.texture = _web_tex
		_web_css = css
		_frames += 1
		if _frames <= 3 or _frames % 100 == 0:
			print("[web] %s frame #%d %dx%d" % [key, _frames, img.get_width(), img.get_height()])
	if _web_pending != null:
		var m: Dictionary = _web_pending
		_web_pending = null
		_on_web_frame(m)


## Cell (1-based) -> layer 0..1, at the cell's centre.
func _cell_uv(col: int, row: int) -> Vector2:
	return Vector2((float(col) - 0.5) / float(cols), (float(row) - 0.5) / float(rows))


## Layer 0..1 -> page 0..1 through the letterbox (KEEP_ASPECT_CENTERED).
## Returns (-1, -1) for a point on the bars, which must not click anything.
func _page_uv(uv: Vector2) -> Vector2:
	if web_rect == null or _web_css.y <= 0.0:
		return uv
	var panel := web_rect.size
	var a := _web_css.x / _web_css.y
	var w := panel.x
	var h := panel.y
	if panel.x / panel.y > a:
		w = panel.y * a
	else:
		h = panel.x / a
	var p := Vector2((uv.x * panel.x - (panel.x - w) * 0.5) / w,
			(uv.y * panel.y - (panel.y - h) * 0.5) / h)
	if p.x < 0.0 or p.x > 1.0 or p.y < 0.0 or p.y > 1.0:
		return Vector2(-1, -1)
	return p


func _on_surface_tap(uv: Vector2) -> void:
	if not is_web():
		return
	var p := _page_uv(uv)
	if p.x >= 0.0:
		client.send_web_pointer(session, "click", p)


## Push the config's resolved colours (atriumd/schemes.py) into the grid and
## the glass body. Returns true when the body colour changed, so the caller
## knows the frame and the cards need repainting.
func _apply_colors() -> bool:
	var c: Dictionary = _last_cfg.get("colors", {})
	var before := GlassUI.body
	if not c.is_empty():
		GlassUI.body = Color.html(str(c.get("background", "#101922")))
	if grid:
		if c.is_empty():
			grid.bg_default = GlassUI.body
		else:
			grid.set_colors(c, str(_last_cfg.get("default_cursor_style", "SteadyBlock")),
					int(_last_cfg.get("cursor_blink_rate", 800)))
	return not before.is_equal_approx(GlassUI.body)


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
	# A recentre is also "put my window back where it belongs", size included.
	if _focus_override != Vector3.ZERO:
		_focus_override = Vector3.ZERO
		_place_focus(GlassUI.polar(GlassUI.FOCUS_YAW_DEG, pitch_deg, distance))
	if _dmm_override > 0.0:
		_dmm_override = 0.0
		_resize_panel(float(_last_cfg.get("font", {}).get("size_dmm", 22.3)))


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
	_ensure_session()
	_update_status()
	_rebuild_rail()


const LAST_SESSION := "user://last-session.txt"


func _read_last_session() -> String:
	var f := FileAccess.open(LAST_SESSION, FileAccess.READ)
	if f != null:
		var v := f.get_as_text().strip_edges()
		if v != "":
			return v
	return _read_data_file("session.txt", SESSION_FALLBACK)


func _save_last_session(key: String) -> void:
	var f := FileAccess.open(LAST_SESSION, FileAccess.WRITE)
	if f != null:
		f.store_string(key)


## If the session on the panel is not one the host has, move to whoever needs
## you, else the first one. (Bug 9/18: a stale `cc-vr` from the last run showed
## "server error: no such tmux target" on every boot.)
func _ensure_session() -> void:
	if known.is_empty() or _index_of(session) >= 0:
		return
	var next := focus_key if _index_of(focus_key) >= 0 else str(known[0].get("key", ""))
	if next != "":
		print("[term] %s is gone — showing %s" % [session, next])
		switch_to(next)


func _on_session_missing(key: String) -> void:
	if key != session:
		return
	var i := _index_of(key)
	if i >= 0:
		known.remove_at(i)
	_ensure_session()


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


var _strip_key := ""


func _update_status() -> void:
	if title_left == null or frame_vp == null:
		return
	title_left.text = link_text if link_text != "" else session
	var crop: Vector2i = _cropped.get(session, Vector2i.ZERO)
	var right := GlassUI.title_right_text(waiting_count(), crop)
	# Re-render (and re-bake) only when the words change: a baked strip costs a
	# GPU readback, and session deltas arrive several times a second.
	var key := title_left.text + "|" + right + "|" + str(frame_vp.size)
	if key == _strip_key:
		return
	_strip_key = key
	title_right.text = right
	# ⚠️ Measure the string; a guessed fraction of the width runs off the frame.
	var title_px := GlassUI.TITLE_PX
	var w := font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, title_px).x
	var pad_px := float(frame_vp.size.y) / (GlassUI.term_size(cols, rows, dmm, distance).y \
			+ GlassUI.FRAME_PAD_M * 2.0 + GlassUI.FRAME_TITLE_M) * GlassUI.FRAME_PAD_M
	title_right.position.x = float(frame_vp.size.x) - w - pad_px - 6.0
	# The strip only re-renders when its text changes.
	frame_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if frame_mesh:
		GlassUI.bake_content(frame_vp, frame_mesh.material_override, false)


## A short note on the title strip's right end, then back to the usual status.
func _flash(text: String) -> void:
	if title_right == null:
		return
	title_right.text = text
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, GlassUI.TITLE_PX).x
	title_right.position.x = float(frame_vp.size.x) - w - 60.0
	_strip_key = ""                      # the next status update must redraw
	frame_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	if frame_mesh:
		GlassUI.bake_content(frame_vp, frame_mesh.material_override, false)
	get_tree().create_timer(2.0).timeout.connect(_update_status)


## Show a different session on the focus panel.
func switch_to(key: String) -> void:
	if key == "" or key == session:
		return
	client.unsubscribe(session)          # lets the host restore its geometry
	session = key
	if grid:
		grid.clear()                     # never show the old session's text
	_web_tex = null                      # nor the old page
	_web_pending = null
	if web_rect:
		web_rect.texture = null
	_show_surface()
	client.subscribe(session, cols, rows)
	_save_last_session(session)
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
			KEY_S:
				toggle_settings()
				return
			KEY_K:
				# Keyboard view: a passthrough window at the desk. Saved like a
				# panel change, so it survives a restart.
				var on := backdrop != null and backdrop.desk_window_on()
				client.send_settings({"backdrop.passthrough.desk_window": not on})
				_flash("keyboard view off" if on else "keyboard view on")
				return
			KEY_B:
				# Room <-> your real room (keys.toggle_backdrop).
				var real := str(_cfg_get("backdrop.mode")) == "passthrough"
				client.send_settings({"backdrop.mode": "default" if real else "passthrough"})
				_flash("room" if real else "passthrough")
				return
			KEY_H:
				if pointers:
					_flash("hands on" if pointers.toggle_hands() else "hands off")
				return
	# ⚙ Settings is a mode: Esc closes it, and nothing typed reaches the
	# hidden pane meanwhile.
	if _settings_open:
		if not k.echo and k.keycode == KEY_ESCAPE:
			toggle_settings()
		return
	# ⛔ While the pairing card is up, every key belongs to it. Nothing typed
	# there may reach a tmux pane.
	if pairing != null:
		pairing.feed(k)
		return
	if not k.echo and k.keycode == KEY_F1:
		recenter()
		return
	if router != null and router.feed(k):
		if pointers:
			pointers.note_typing()
		# The click belongs to keys that actually reach a pane, so a chord the
		# router refused stays silent instead of sounding like it typed.
		if ambience != null:
			ambience.click()


# ── Pointer plumbing ──────────────────────────────────────────────────────────

var _pointer_cfg := {}
var _card_targets: Array = []
var _card_groups: Array = []


func _push_pointer_targets() -> void:
	if pointers == null or frame_mesh == null:
		return
	pointers.set_frame(frame_mesh, frame_outer, GlassUI.FRAME_TITLE_M,
			GlassUI.term_size(cols, rows, dmm, distance), cols, rows)
	pointers.set_cards(_card_targets)


## Put the focus group at a rig-local position, aimed at the rig origin the
## same way oriented_group() does, so frame and layer keep nesting.
func _place_focus(local_pos: Vector3) -> void:
	if focus_group == null:
		return
	focus_group.position = local_pos
	if local_pos.length() > 0.001:
		focus_group.look_at(rig.to_global(Vector3.ZERO), Vector3.UP)
		focus_group.rotate_object_local(Vector3.UP, PI)


var _drag_target := Vector3.ZERO
var _drag_pending := false
const FLOOR_CLEAR_M := 0.05
const WALL_CLEAR_M := 0.15


func _on_focus_dragged(world_pos: Vector3) -> void:
	# Applied in _physics_process, where the space state is safe to query.
	_drag_target = world_pos
	_drag_pending = true


## ⭐ Collision (owner 9/17 eve): a window cannot go through the floor or a
## wall. Floor = the tracking origin's plane (local-floor space). Walls = the
## room's static geometry, which backdrop.gd gives trimesh collision, tested
## with one ray from the head to where the window wants to be.
func _physics_process(_delta: float) -> void:
	if not _drag_pending or focus_group == null or rig == null or cam == null:
		return
	_drag_pending = false
	var pos := _drag_target
	var from := cam.global_position
	var dir := pos - from
	if dir.length() < 0.3:
		return
	var space := get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(from, pos + dir.normalized() * WALL_CLEAR_M)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d := maxf(from.distance_to(hit["position"]) - WALL_CLEAR_M, 0.3)
			pos = from + dir.normalized() * d
	if xr_origin != null:
		var floor_y: float = xr_origin.global_position.y
		var half_h := frame_outer.y * 0.5 + GlassUI.FRAME_TITLE_M * 0.5
		pos.y = maxf(pos.y, floor_y + FLOOR_CLEAR_M + half_h)
	var local := rig.to_local(pos)
	_focus_override = local
	_place_focus(local)


func _on_grid_hover(col: int, row: int) -> void:
	if hover_dot == null:
		return
	# A web page gets real mouse moves (hover menus, tooltips), one per cell.
	if is_web() and col >= 1 and row >= 1 and Vector2i(col, row) != _web_hover:
		_web_hover = Vector2i(col, row)
		var p := _page_uv(_cell_uv(col, row))
		if p.x >= 0.0:
			client.send_web_pointer(session, "move", p)
	if col < 1 or row < 1:
		hover_dot.visible = false
		return
	var cell := GlassUI.cell
	hover_dot.position = Vector2((col - 1) * cell.x, (row - 1) * cell.y)
	hover_dot.visible = true


## Live resize: the same cell grid, a different physical size. Only the layer's
## quad, the frame quad and its content viewport change — no resubscribe, no
## new SubViewport for the grid, so this is cheap enough to run every frame
## while the thumbstick is held.
func _on_focus_resized(factor: float) -> void:
	_resize_panel(clampf(dmm * factor, 16.0, 40.0))


## Card text is drawn at ~22.3 dmm (GlassUI.card); scale it to the window's.
func _card_scale() -> float:
	return clampf(dmm / GlassUI.CARD_TEXT_DMM, 0.5, 3.0)


func _resize_panel(new_dmm: float) -> void:
	if layer == null or frame_mesh == null or is_equal_approx(new_dmm, dmm):
		return
	dmm = new_dmm
	_dmm_override = new_dmm
	var term := GlassUI.term_size(cols, rows, dmm, distance)
	var pad := GlassUI.FRAME_PAD_M
	var title_h := GlassUI.FRAME_TITLE_M
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	layer.quad_size = term
	(frame_mesh.mesh as QuadMesh).size = outer
	(frame_mesh.material_override as ShaderMaterial).set_shader_parameter("aspect", outer.x / outer.y)
	frame_outer = outer
	# The strip's pixels per metre must keep matching the grid's, or the title
	# text changes size relative to the body. Rescale the viewport, keep the
	# labels where they are in it.
	var px_per_m := float(viewport.size.y) / term.y * GlassUI.UI_PX_SCALE
	frame_vp.size = Vector2i(int(round(outer.x * px_per_m)), int(round(outer.y * px_per_m)))
	_update_status()
	# Cards grow with the window, so their text stays the size of the terminal's
	# ("the card doesn't grow when the window does… looks goofy", 9/17). Scaling
	# the group keeps the pointer right: hit_quad inverts the global transform.
	var k := _card_scale()
	var card_size := GlassUI.angular_size(GlassUI.CARD_W_DEG, GlassUI.CARD_H_DEG, distance)
	for i in range(_card_groups.size()):
		var g: Node3D = _card_groups[i]
		if is_instance_valid(g):
			g.scale = Vector3.ONE * k
			g.position = GlassUI.rail_local(outer, card_size * k, i)
	var button_size := GlassUI.angular_size(GlassUI.BUTTON_W_DEG, GlassUI.BUTTON_H_DEG, distance)
	for i in range(_button_groups.size()):
		var g: Node3D = _button_groups[i]
		if is_instance_valid(g):
			g.scale = Vector3.ONE * k
			g.position = GlassUI.button_local(outer, button_size * k, i)
	_push_pointer_targets()
	# A bigger window may now reach the floor.
	_drag_target = focus_group.global_position
	_drag_pending = true


# ── ⚙ settings ────────────────────────────────────────────────────────────────
#
# ⭐ A MODE, not a side panel (owner 9/18: "settings should be the center of
# attention"): opening it hides the terminal — frame, text layer and rail —
# and the settings take the window's place, same spot, same distance. Opened by
# the Settings button, ctrl+alt+S or the left Menu button; Done / Esc closes.
# While open, typing never reaches the hidden pane.
#
# Tabs down the left, the open tab's rows on the right. The Scene tab is a grid
# of previews: a tap only PICKS a scene, "Use …" applies it — switching rooms
# is intentional, never a stray trigger pull.
#
# The rows come from the HOST (atriumd/settings.py) with every config frame —
# label, config path, allowed values. A change sends {"op":"set_settings"}; the
# host writes settings.json (never config.lua) and the config frame that comes
# back is what changes anything, so the panel always shows what is applied.

const SET_TOTAL_W_DEG := 58.0
const SET_TOP_DEG := 20.0          # the panel's top edge, above the window centre
const SET_TAB_W_DEG := 10.0
const SET_ROW_W_DEG := 32.0
const SET_SMALL_W_DEG := 3.4
const SET_GAP_DEG := 0.6
const SET_THUMB_COLS := 4
const SET_THUMB_W_DEG := 11.2

var _settings_open := false
var _settings_schema: Array = []
var _settings_over: Dictionary = {}
var _settings_tab := 0
var _scene_pick := ""               # the previewed scene key, "" = none picked yet
var settings_root: Node3D


func toggle_settings() -> void:
	_settings_open = not _settings_open
	_scene_pick = ""
	# The terminal steps aside: hide the whole window group (frame, rail,
	# buttons) and switch the composition layer off — a layer draws over
	# everything, so hiding its parent is not enough on every runtime.
	if focus_group:
		focus_group.visible = not _settings_open
	if layer and "enabled" in layer:
		layer.enabled = not _settings_open
	_rebuild_rail()
	_flash("settings" if _settings_open else "")


func _on_settings(st: Dictionary) -> void:
	_settings_schema = st.get("schema", [])
	_settings_over = st.get("overrides", {})
	_settings_tab = clampi(_settings_tab, 0, maxi(_settings_schema.size() - 1, 0))
	if _settings_open:
		_rebuild_rail()


func _m_per_deg() -> float:
	return distance * tan(deg_to_rad(1.0))


## Build the settings in their own group where the window stands. (`k` is the
## rail's scale and unused: settings are always full size.)
func _build_settings(_k: float) -> void:
	if settings_root != null:
		settings_root.queue_free()
		settings_root = null
	if not _settings_open or focus_group == null or rig == null:
		return
	settings_root = Node3D.new()
	rig.add_child(settings_root)
	settings_root.transform = focus_group.transform
	var bh := GlassUI.BUTTON_H_DEG
	if _settings_schema.is_empty():
		_st_button("done", "Settings: waiting for the host…", 0.0, 0.0, 30.0, 0.0)
		return
	# Sidebar: one tab per group, Done and Reset all underneath.
	var y := 0.0
	for i in range(_settings_schema.size()):
		_st_button("tab:%d" % i, str(_settings_schema[i].get("group", "?")),
				0.0, y, SET_TAB_W_DEG, 1.0 if i == _settings_tab else 0.0)
		y += bh + SET_GAP_DEG
	y += bh * 0.5
	_st_button("done", "Done", 0.0, y, SET_TAB_W_DEG, 0.0)
	if not _settings_over.is_empty():
		y += bh + SET_GAP_DEG
		_st_button("resetall", "Reset all", 0.0, y, SET_TAB_W_DEG, 0.0)
	# Content.
	var x0 := SET_TAB_W_DEG + 1.5
	var g: Dictionary = _settings_schema[_settings_tab]
	y = 0.0
	for r in g.get("rows", []):
		if str(r.get("id", "")) == "scene":
			y = _build_scene_picker(r, x0, y)
			continue
		var id := str(r.get("id", ""))
		var x := _st_button("row:" + id, "%s   %s" % [r.get("label", id), _settings_value_text(r)],
				x0, y, SET_ROW_W_DEG, 0.0)
		if str(r.get("kind", "")) == "step":
			x = _st_button("dec:" + id, "−", x, y, SET_SMALL_W_DEG, 0.0)
			x = _st_button("inc:" + id, "+", x, y, SET_SMALL_W_DEG, 0.0)
		if _settings_row_overridden(r):
			# The panel owns this one: offer the way back to config.lua's value.
			_st_button("reset:" + id, "↺", x, y, SET_SMALL_W_DEG, 0.0)
		y += bh + SET_GAP_DEG


## Scene previews in a grid; a tap picks, "Use …" applies. Returns the next y.
func _build_scene_picker(r: Dictionary, x0: float, y: float) -> float:
	var opts := _settings_options(r)
	var cur := _settings_current(opts)
	var th := SET_THUMB_W_DEG * 9.0 / 16.0
	var picked := -1
	for i in range(opts.size()):
		var key := _scene_key(opts[i])
		if key == _scene_pick:
			picked = i
		var cx := x0 + float(i % SET_THUMB_COLS) * (SET_THUMB_W_DEG + SET_GAP_DEG)
		var cy := y + float(i / SET_THUMB_COLS) * (th + SET_GAP_DEG)
		var tex: Texture2D = null
		var path := "res://thumbs/%s.jpg" % key
		if ResourceLoader.exists(path):
			tex = load(path)
		var label := str(opts[i].get("label", key)) + ("  •" if i == cur else "")
		var t := GlassUI.thumb(settings_root, font, _st_pos(cx, cy, SET_THUMB_W_DEG, th),
				GlassUI.angular_size(SET_THUMB_W_DEG, th, distance), tex, label,
				1.0 if key == _scene_pick else 0.0)
		_card_targets.append({"mesh": t["mesh"], "key": "__st:scene:" + key,
				"size": GlassUI.angular_size(SET_THUMB_W_DEG, th, distance)})
	var rows_n := int(ceil(float(opts.size()) / float(SET_THUMB_COLS)))
	y += float(rows_n) * (th + SET_GAP_DEG) + SET_GAP_DEG
	var bw := SET_ROW_W_DEG
	if picked >= 0 and picked != cur:
		_st_button("use", "Use  " + str(opts[picked].get("label", "")), x0, y, bw, 1.0)
	elif cur >= 0:
		_st_button("noop", "Now: " + str(opts[cur].get("label", "")) + "   (tap a scene to preview)",
				x0, y, bw, 0.0)
	return y + GlassUI.BUTTON_H_DEG + SET_GAP_DEG * 2.0


func _scene_key(o: Dictionary) -> String:
	var p := str(o.get("preset", ""))
	return p if p != "" else "passthrough"


## The centre of an item whose top-left is (x, y) degrees from the panel's
## top-left, in settings_root space.
func _st_pos(x: float, y: float, w: float, h: float) -> Vector3:
	var m := _m_per_deg()
	return Vector3((x + w * 0.5 - SET_TOTAL_W_DEG * 0.5) * m, (SET_TOP_DEG - y - h * 0.5) * m, 0.0)


## One settings button at (x, y) degrees, w wide. Returns the next free x.
func _st_button(key: String, label: String, x: float, y: float, w: float,
		attention: float) -> float:
	var size := GlassUI.angular_size(w, GlassUI.BUTTON_H_DEG, distance)
	var b := GlassUI.button(settings_root, font, _st_pos(x, y, w, GlassUI.BUTTON_H_DEG), size,
			label, attention)
	_card_targets.append({"mesh": b["mesh"], "size": size, "key": "__st:" + key})
	return x + w + SET_GAP_DEG


func _cfg_get(path: String):
	var node = _last_cfg
	for part in path.split("."):
		if typeof(node) != TYPE_DICTIONARY or not node.has(part):
			return null
		node = node[part]
	return node


func _settings_row(id: String) -> Dictionary:
	for g in _settings_schema:
		for r in g.get("rows", []):
			if str(r.get("id", "")) == id:
				return r
	return {}


## The options a choice row may cycle through on THIS build.
func _settings_options(r: Dictionary) -> Array:
	var out: Array = []
	for o in r.get("options", []):
		var p := str(o.get("preset", ""))
		if p == "" or Backdrop.has_preset(p):
			out.append(o)
	return out


## Index of the option matching the applied config, or -1.
func _settings_current(opts: Array) -> int:
	for i in range(opts.size()):
		var ok := true
		var set_: Dictionary = opts[i].get("set", {})
		for path in set_:
			if _cfg_get(path) != set_[path]:
				ok = false
				break
		if ok:
			return i
	return -1


func _settings_value_text(r: Dictionary) -> String:
	if str(r.get("kind", "")) == "step":
		var v = _cfg_get(str(r.get("path", "")))
		if v == null:
			return "?"
		var unit := str(r.get("unit", ""))
		if unit == "%":
			return "%d%%" % roundi(float(v) * 100.0)
		# As many decimals as the step has: 0.45 m, 1.5 m, 120 cols.
		var st := float(r.get("step", 1.0))
		var digits := 0 if st >= 1.0 else (1 if st >= 0.1 else 2)
		return ("%." + str(digits) + "f%s") % [float(v), unit]
	var opts := _settings_options(r)
	var i := _settings_current(opts)
	return str(opts[i].get("label", "?")) if i >= 0 else "custom"


func _settings_row_overridden(r: Dictionary) -> bool:
	for p in _settings_paths(r):
		if _settings_over.has(p):
			return true
	return false


func _settings_paths(r: Dictionary) -> Array:
	if str(r.get("kind", "")) == "step":
		return [str(r.get("path", ""))]
	var out: Array = []
	for o in r.get("options", []):
		for p in o.get("set", {}):
			if not out.has(p):
				out.append(p)
	return out


func _on_settings_tap(what: String) -> void:
	var verb := what.get_slice(":", 0)
	var arg := what.substr(verb.length() + 1)
	match verb:
		"done":
			toggle_settings()
		"noop":
			pass
		"scene":
			_scene_pick = arg
			_rebuild_rail()
		"use":
			for o in _settings_options(_settings_row("scene")):
				if _scene_key(o) == _scene_pick:
					client.send_settings(o.get("set", {}))
					_flash("scene: " + str(o.get("label", "")))
			_scene_pick = ""
		"tab":
			_settings_tab = int(arg)
			_rebuild_rail()
		"resetall":
			client.reset_settings(null)
		"reset":
			client.reset_settings(_settings_paths(_settings_row(arg)))
		"row":
			var r := _settings_row(arg)
			if str(r.get("kind", "")) != "choice":
				return
			var opts := _settings_options(r)
			if opts.is_empty():
				return
			var nxt: Dictionary = opts[(_settings_current(opts) + 1) % opts.size()]
			client.send_settings(nxt.get("set", {}))
		"dec", "inc":
			var r := _settings_row(arg)
			var path := str(r.get("path", ""))
			var lo := float(r.get("min", 0.0))
			var st := float(r.get("step", 1.0))
			var cur = _cfg_get(path)
			var v := float(cur) if cur != null else lo
			v = lo + roundf((v - lo) / st) * st + (st if verb == "inc" else -st)
			v = clampf(v, lo, float(r.get("max", v)))
			if path == "font.size_dmm":
				# The thumbstick resize is a local override; the panel's size wins.
				_dmm_override = 0.0
			client.send_settings({path: v})

extends Node3D
class_name Backdrop

## What you see behind the windows. Driven by `backdrop` in the Lua config:
##
##   mode = "passthrough"  -> your real room (clear colour, alpha-blended)
##   mode = "default"      -> a shipped preset:
##       preset = "cafe"    the Astra-built coffee shop (AS-0002), a GLB with
##                          baked lighting and a handful of slow animation loops
##       preset = "cafe-night" / "cabin" / "library"   more Astra rooms (ROOMS);
##                          one that is not in this build falls back to the sky
##       preset = "nebula"  the procedural sky that shipped first
##       preset = "void"    flat dark
##   mode = "custom"       -> your own .glb, fetched from the daemon at runtime
##                          (`backdrop.custom.glb` on the host; `atrium pack`)
##
## ⭐ Glass is for the windows only; nothing here is glass.
##
## The sky and the void are switched with background mode. A room is a GLB:
## only one is held at a time and picking another loads it (a second or so).

## Every Astra room, by preset name. `clear` is only seen through a gap in the
## geometry. ⚠️ A new GLB needs the café's two import flags
## (force_disable_compression, generate_lods=false) — see cafe.glb.import.
const ROOMS := {
	"cafe": {"scene": "res://backdrops/cafe.glb", "clear": Color(0.10, 0.08, 0.07)},
	"cafe-night": {"scene": "res://backdrops/cafe-night.glb", "clear": Color(0.07, 0.08, 0.16)},
	"cabin": {"scene": "res://backdrops/cabin.glb", "clear": Color(0.20, 0.12, 0.22)},
	"library": {"scene": "res://backdrops/library.glb", "clear": Color(0.10, 0.09, 0.08)},
	"golden-gate": {"scene": "res://backdrops/golden-gate.glb", "clear": Color(0.93, 0.88, 0.84)},
	"twin-peaks": {"scene": "res://backdrops/twin-peaks.glb", "clear": Color(0.04, 0.05, 0.12)},
	"painted-ladies": {"scene": "res://backdrops/painted-ladies.glb", "clear": Color(0.55, 0.75, 0.95)},
	# ⭐ One GLB, two places to sit (AS-0008). `seat` names an Empty in the GLB
	# whose position is 1.20 m below the design eye, facing the view: the room is
	# offset so that Empty lands where every other room's origin does.
	"palace-lawn": {"scene": "res://backdrops/palace.glb", "clear": Color(0.55, 0.62, 0.72),
			"seat": "Seat_Lawn"},
	"palace-rotunda": {"scene": "res://backdrops/palace.glb", "clear": Color(0.55, 0.62, 0.72),
			"seat": "Seat_Rotunda"},
}
const VOID_COLOR := Color(0.035, 0.030, 0.028)
const CAFE_CLEAR := Color(0.10, 0.08, 0.07)

var env: Environment
var sky_mat: ShaderMaterial
var room: Node3D
var mode := "default"
var preset := "nebula"
var _players: Array = []
var _anchor := Transform3D.IDENTITY

# Which GLB `room` currently holds, so switching preset <-> custom rebuilds it.
var _room_kind := ""
# The inverse of the chosen seat's transform in the room (identity for a room
# built around its origin), applied under the anchor.
var _seat_inv := Transform3D.IDENTITY

# A custom backdrop arrives over the same link as the pixels. ⚠️ It is fetched,
# never bundled: the .glb lives on the HOST (backdrop.custom.glb) and only the
# daemon may hand it out, token-gated like everything else.
const CACHE_GLB := "user://backdrop-custom.glb"
const CACHE_TAG := "user://backdrop-custom.etag"
var _src_host := ""
var _src_port := 7570
var _src_token := ""
var _http: HTTPRequest
var _fetching := false
var _custom: Node3D                # built, waiting to be installed
# ⌨ Keyboard view: a passthrough window at the desk (backdrop.passthrough.desk_*).
var desk_hole: MeshInstance3D
var _desk := {}
var _want_custom := false          # the config asked for a custom room


## Built in _init, not _ready, so `apply()` is safe the moment the node exists —
## the preview calls it before the node has entered the tree.
func _init() -> void:
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/nebula_sky.gdshader")
	sky.sky_material = sky_mat
	# Radiance costs real time on mobile and a background this dim lights nothing.
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL

	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.35
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = false          # ⚠️ glow is expensive on Quest and blooms text

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


## The seated eye height the shipped room was built around (AS-0002 brief).
const DESIGN_EYE_M := 1.20
## How far the room may be shifted to fit a shorter or taller user.
const SEAT_ADJUST_MAX_M := 0.35
const SEAT_STEP_M := 0.05
var _fit_dy := 0.0
var _fit_set := false

## Put the room's seat under the user. `t` is the rig transform (head position
## and yaw after a recentre); the room takes its x/z and yaw, so recentring
## carries the café with the panels instead of leaving the seat wherever the
## play space happened to start.
##
## ⚠️ The room is also shifted vertically so ITS design eye height lands on the
## user's ACTUAL eye height. The first wearer recentred at 1.08 m in a room built
## for 1.20 m: the table rose 12 cm relative to him and the coffee cup crossed
## the sight line to the panel's bottom edge — in front of the bezel (scene
## geometry, depth-sorted) but behind the text (composition layer, always on
## top). Matching eye heights keeps the keep-out wedge where Astra checked it.
func anchor(t: Transform3D) -> void:
	var fwd := -t.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3(0, 0, -1)
	# ⚠️ Recentres arrive with the head anywhere within ~30 cm of "seated" (a
	# minute of one session logged 0.91–1.22 m), and re-fitting the room to each
	# reading made the café nudge a few centimetres per press. Quantise to 5 cm
	# and keep the previous fit unless the reading moved a full step.
	var raw := clampf(t.origin.y - DESIGN_EYE_M, -SEAT_ADJUST_MAX_M, SEAT_ADJUST_MAX_M)
	var dy := snappedf(raw, SEAT_STEP_M)
	if _fit_set and absf(dy - _fit_dy) < SEAT_STEP_M * 0.99:
		dy = _fit_dy
	_fit_dy = dy
	_fit_set = true
	_anchor = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP),
			Vector3(t.origin.x, dy, t.origin.z))
	if room:
		room.transform = _anchor * _seat_inv
	_place_desk()
	print("[backdrop] anchored: eye %.2f m, room shifted %.2f m" % [t.origin.y, dy])


## Apply the `backdrop` table from the served config.
func apply(bd: Dictionary) -> void:
	mode = str(bd.get("mode", "default"))
	var d: Dictionary = bd.get("default", {})
	preset = str(d.get("preset", "nebula"))
	var dim := clampf(float(d.get("dim", 0.0)), 0.0, 1.0)

	# A custom room cannot appear synchronously — it is a download. Show the
	# preset now, swap the room in when it lands, and keep the preset if it
	# never does. Nothing here blocks a config save from restyling the rest.
	var want_custom := mode == "custom"
	_want_custom = want_custom
	if want_custom:
		mode = "default"
		if _custom != null:
			_install_room(_custom, "custom")
			_custom = null
		else:
			_fetch_custom()

	# ⚠️ WorldEnvironment is a plain Node, not a VisualInstance3D — it has no
	# `visible`. Switch the background mode instead.
	_desk = bd.get("passthrough", {})
	if mode == "passthrough":
		env.background_mode = Environment.BG_CLEAR_COLOR
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_show_room(false)
	elif want_custom and _room_kind == "custom":
		# The user's own room is up: light it like the café (baked colours) and
		# leave the preset alone underneath.
		env.background_mode = Environment.BG_COLOR
		env.background_color = CAFE_CLEAR
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_show_room(true)
	else:
		match preset:
			_ when ROOMS.has(preset):
				if _ensure_room(preset):
					env.background_mode = Environment.BG_COLOR
					env.background_color = ROOMS[preset]["clear"]
					env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
					# The room's colours are already baked; a filmic curve on top
					# only washes them out. Linear reproduces what Astra rendered.
					env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
					_show_room(true)
				else:
					# The GLB is not in this build; keep the sky rather than a void.
					preset = "nebula"
					_use_sky()
			"void":
				env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
				env.background_mode = Environment.BG_COLOR
				env.background_color = VOID_COLOR
				env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
				_show_room(false)
			_:
				_use_sky()

	# `dim` darkens the backdrop so the glass pops. The sky has its own knobs;
	# the room goes through the environment's brightness adjustment, which also
	# touches the in-scene glass frames a little — acceptable, they are dark —
	# and never the terminal text, which is on a composition layer.
	if sky_mat:
		sky_mat.set_shader_parameter("nebula_strength", 0.55 * (1.0 - dim))
		sky_mat.set_shader_parameter("star_brightness", 1.0 - dim * 0.7)
	var room_dim := dim > 0.001 and room != null and room.visible
	env.adjustment_enabled = room_dim
	env.adjustment_brightness = 1.0 - 0.6 * dim if room_dim else 1.0
	_update_passthrough()
	print("[backdrop] mode=%s preset=%s dim=%.2f%s"
			% [mode, preset, dim, "  (custom)" if _room_kind == "custom" else ""])


func _use_sky() -> void:
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	_show_room(false)


func _show_room(on: bool) -> void:
	if room == null:
		return
	room.visible = on
	for p in _players:
		if on:
			if not p.is_playing():
				p.play()
		else:
			p.pause()


## True when `p` can be shown by this build: the sky and the void always, a
## room only if its GLB was packed. The ⚙ panel hides the rest.
static func has_preset(p: String) -> bool:
	if p == "nebula" or p == "void":
		return true
	return ROOMS.has(p) and ResourceLoader.exists(ROOMS[p]["scene"])


## Instantiate room `kind` (a ROOMS key). Returns false when its GLB is not in
## the build. Already showing it = nothing to do.
func _ensure_room(kind: String) -> bool:
	if room != null and _room_kind == kind:
		return true
	if not ROOMS.has(kind):
		return false
	var path: String = ROOMS[kind]["scene"]
	if room != null and ROOMS.has(_room_kind) and ROOMS[_room_kind]["scene"] == path:
		# Another seat in the same GLB: move, don't reload.
		_room_kind = kind
		_seat_inv = _seat_of(room, str(ROOMS[kind].get("seat", ""))).affine_inverse()
		room.transform = _anchor * _seat_inv
		print("[backdrop] %s: same room, new seat" % kind)
		return true
	if not ResourceLoader.exists(path):
		print("[backdrop] %s is not in this build" % path)
		return false
	var packed := load(path) as PackedScene
	if packed == null:
		print("[backdrop] %s failed to load" % path)
		return false
	var node := packed.instantiate() as Node3D
	node.name = kind.capitalize().replace(" ", "")
	_install_room(node, kind)
	return true


## The transform of seat Empty `seat_name` relative to the room's root, or
## identity when the room has none (every room built around its own origin).
## ⚠️ Only the Y rotation is kept: a tilted Empty would tilt the whole world.
static func _seat_of(root: Node3D, seat_name: String) -> Transform3D:
	if seat_name == "":
		return Transform3D.IDENTITY
	var seat := root.find_child(seat_name, true, false) as Node3D
	if seat == null:
		print("[backdrop] seat %s not found — using the room origin" % seat_name)
		return Transform3D.IDENTITY
	var t := Transform3D.IDENTITY
	var n: Node = seat
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	var fwd := -t.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3(0, 0, -1)
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), t.origin)


## Put a room in place, replacing whatever was there. One room exists at a time:
## two GLBs of baked geometry is a lot of memory for something you cannot see.
func _install_room(node: Node3D, kind: String) -> void:
	if room != null:
		remove_child(room)
		room.queue_free()
	_players.clear()
	room = node
	_room_kind = kind
	_seat_inv = _seat_of(node, str(ROOMS.get(kind, {}).get("seat", ""))).affine_inverse()
	room.transform = _anchor * _seat_inv
	add_child(room)
	_fix_materials(room)
	var n := _add_collision(room)
	_start_loops(room)
	print("[backdrop] collision on %d static mesh(es)" % n)
	print("[backdrop] %s room loaded: %d animation loop(s)" % [kind, _players.size()])


# ── the user's own room ─────────────────────────────────────────

## Where to fetch a custom backdrop from — the same host, port and token the
## pixels come over. Set by the client once it is linked.
func set_source(h: String, p: int, t: String) -> void:
	if h == _src_host and p == _src_port and t == _src_token:
		return
	_src_host = h
	_src_port = p
	_src_token = t


## Ask the daemon for `backdrop.custom.glb`. Cached on the device between runs:
## re-downloading tens of megabytes at every launch over the headset's Wi-Fi is
## the difference between a room that is there and a room that arrives later.
func _fetch_custom() -> void:
	if _fetching or _src_host == "" or not is_inside_tree():
		return
	_fetching = true
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = 60.0
		_http.request_completed.connect(_on_custom_fetched)
		add_child(_http)
	var headers := PackedStringArray()
	var tag := _cached_tag()
	if tag != "" and FileAccess.file_exists(CACHE_GLB):
		headers.append("If-None-Match: " + tag)
	var url := "http://%s:%d/backdrop.glb?token=%s" % [_src_host, _src_port, _src_token.uri_encode()]
	var err := _http.request(url, headers)
	if err != OK:
		_fetching = false
		print("[backdrop] custom fetch could not start (%d) — keeping the preset" % err)


func _on_custom_fetched(result: int, code: int, headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_fetching = false
	if result != HTTPRequest.RESULT_SUCCESS:
		print("[backdrop] custom fetch failed (result %d) — keeping the preset" % result)
		_use_cached_custom()
		return
	if code == 304:
		_use_cached_custom()
		return
	if code != 200:
		# 404 is the normal "the host is not configured for this" answer.
		print("[backdrop] host has no custom backdrop (HTTP %d) — keeping the preset" % code)
		return
	var tag := ""
	for h in headers:
		if h.to_lower().begins_with("etag:"):
			tag = h.substr(5).strip_edges()
	if _build_custom(body):
		_write_cache(body, tag)


func _use_cached_custom() -> void:
	if not FileAccess.file_exists(CACHE_GLB):
		return
	var f := FileAccess.open(CACHE_GLB, FileAccess.READ)
	if f == null:
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	_build_custom(bytes)


## ⚠️ A .glb is self-contained, so it parses straight from the buffer with no
## base path and nothing written to disk first. An unpacked .gltf with sidecar
## textures would need one — which is exactly why only .glb is accepted.
func _build_custom(bytes: PackedByteArray) -> bool:
	if bytes.is_empty():
		return false
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(bytes, "", st) != OK:
		print("[backdrop] custom .glb did not parse — keeping the preset")
		return false
	var node := doc.generate_scene(st) as Node3D
	if node == null:
		print("[backdrop] custom .glb has no scene — keeping the preset")
		return false
	node.name = "CustomRoom"
	if not _want_custom:
		# It arrived after the user moved on. Keep it — the next `apply()` with
		# mode = "custom" installs it without another download.
		_custom = node
		return true
	_install_room(node, "custom")
	# Light it the way a baked room wants to be lit.
	env.background_mode = Environment.BG_COLOR
	env.background_color = CAFE_CLEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_show_room(true)
	return true


func _cached_tag() -> String:
	if not FileAccess.file_exists(CACHE_TAG):
		return ""
	var f := FileAccess.open(CACHE_TAG, FileAccess.READ)
	return "" if f == null else f.get_as_text().strip_edges()


func _write_cache(bytes: PackedByteArray, tag: String) -> void:
	var f := FileAccess.open(CACHE_GLB, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(bytes)
	f.close()
	if tag != "":
		var t := FileAccess.open(CACHE_TAG, FileAccess.WRITE)
		if t:
			t.store_string(tag)
			t.close()


## Play EVERY animation in the GLB at once, forever.
##
## ⚠️ A glTF with twelve animations imports as ONE AnimationPlayer, and one
## player plays one animation at a time — so the fan would spin and nothing
## else would move. Each extra animation gets its own player pointed at the
## same root. Loop mode is forced here too, so the `-loop` naming convention in
## the brief is belt-and-braces rather than load-bearing.
func _start_loops(root: Node) -> void:
	_players.clear()
	var found: Array = []
	_collect_players(root, found)
	for ap: AnimationPlayer in found:
		var names: PackedStringArray = ap.get_animation_list()
		if names.is_empty():
			continue
		var anim_root: Node = ap.get_node(ap.root_node)
		for i in range(names.size()):
			var anim: Animation = _only_moving(ap.get_animation(names[i]))
			anim.loop_mode = Animation.LOOP_LINEAR
			var player: AnimationPlayer = ap
			if i > 0:
				player = AnimationPlayer.new()
				player.name = "Loop_" + str(names[i]).validate_node_name()
				var lib := AnimationLibrary.new()
				lib.add_animation(names[i], anim)
				anim_root.add_child(player)
				player.root_node = player.get_path_to(anim_root)
				player.add_animation_library("", lib)
			else:
				ap.get_animation_library("").add_animation(names[i], anim)
			player.play(names[i])
			_players.append(player)


## A copy of `anim` without the tracks that never change.
##
## ⛔ Godot's glTF import gives EVERY clip a track for EVERY node any clip
## animates (40 here), holding the ones it does not move at rest. With one
## player per clip, all eleven write every node each frame and the last one
## wins — so the café stood frozen: people, fan, clock and clouds (9/17).
## A clip keeps only what it actually moves, and the players stop fighting.
static func _only_moving(anim: Animation) -> Animation:
	var a: Animation = anim.duplicate(true)
	for t in range(a.get_track_count() - 1, -1, -1):
		var n := a.track_get_key_count(t)
		var moving := false
		if n > 1:
			var v0 = a.track_get_key_value(t, 0)
			for k in range(1, n):
				if a.track_get_key_value(t, k) != v0:
					moving = true
					break
		if not moving:
			a.remove_track(t)
	return a


## ⚠️ The room's lighting is BAKED INTO VERTEX COLOURS and its material is
## `KHR_materials_unlit`. Godot's glTF importer keeps the unlit flag but does
## not turn on "vertex colour as albedo", so the whole café rendered pure white
## the first time — every wall, every patron. Force it here rather than depend
## on an import setting that a fresh checkout would not have.
## Static meshes get a concave collision shape so a dragged window can be
## stopped at a wall (terminal.gd raycasts against it). Skinned meshes — the
## patrons — are skipped: they move, and nobody drags a window into a person.
func _add_collision(n: Node) -> int:
	var count := 0
	if n is MeshInstance3D and n.mesh and (n as MeshInstance3D).skeleton == NodePath():
		(n as MeshInstance3D).create_trimesh_collision()
		count += 1
	for c in n.get_children():
		count += _add_collision(c)
	return count


func _fix_materials(n: Node) -> void:
	if n is MeshInstance3D and n.mesh:
		for i in range(n.mesh.get_surface_count()):
			var m: Material = n.mesh.surface_get_material(i)
			if m is BaseMaterial3D:
				# ⚠️ Only when the surface HAS colours: a textured mesh without
				# COLOR_0 multiplied by "vertex colour" can come out black.
				m.vertex_color_use_as_albedo = \
						(n.mesh.surface_get_format(i) & Mesh.ARRAY_FORMAT_COLOR) != 0
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for c in n.get_children():
		_fix_materials(c)


func _collect_players(n: Node, out: Array) -> void:
	if n is AnimationPlayer:
		out.append(n)
	for c in n.get_children():
		_collect_players(c, out)


# ── passthrough ────────────────────────────────────────────────────────────
#
# ⚠️ Until 9/18 `mode = "passthrough"` only switched the background to a clear
# colour: nothing ever asked the runtime for passthrough, so the headset showed
# a flat colour. It takes BOTH: the OpenXR environment blend mode ALPHA_BLEND
# (the vendors plugin starts Meta passthrough on it) and a transparent main
# viewport, so clear pixels have alpha 0. Only while needed — passthrough costs
# GPU and battery, and a room needs neither.

func desk_window_on() -> bool:
	return mode != "passthrough" and bool(_desk.get("desk_window", false))


func _update_passthrough() -> void:
	var want_alpha := mode == "passthrough" or desk_window_on()
	var xri := XRServer.find_interface("OpenXR")
	if xri != null and xri.is_initialized():
		var bm := XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND if want_alpha \
				else XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		if xri.environment_blend_mode != bm:
			if bm in xri.get_supported_environment_blend_modes():
				xri.environment_blend_mode = bm
			else:
				print("[backdrop] blend mode %d not supported by this runtime" % bm)
	if is_inside_tree():
		get_viewport().transparent_bg = want_alpha
	if desk_window_on():
		if desk_hole == null:
			desk_hole = MeshInstance3D.new()
			desk_hole.name = "KeyboardView"
			desk_hole.mesh = QuadMesh.new()
			var m := ShaderMaterial.new()
			m.shader = load("res://shaders/passthrough_hole.gdshader")
			# Before every other transparent thing: the glass frame and cards
			# draw over the hole instead of being punched out by it.
			m.render_priority = -100
			desk_hole.material_override = m
			desk_hole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(desk_hole)
		desk_hole.visible = true
		_place_desk()
	elif desk_hole != null:
		desk_hole.visible = false


## Size and place the keyboard view in ANCHOR space — the recentred head, not
## the room: a seat offset must never move your real keyboard. It sits
## `forward` ahead and `below` under the eye, tilted to face you.
func _place_desk() -> void:
	if desk_hole == null or not desk_hole.visible:
		return
	var sz = _desk.get("desk_window_size_m", [1.2, 0.6])
	var size := Vector2(float(sz[0]), float(sz[1])) if sz is Array and sz.size() >= 2 \
			else Vector2(1.2, 0.6)
	var fwd := float(_desk.get("desk_window_forward_m", 0.45))
	var below := float(_desk.get("desk_window_below_eye_m", 0.40))
	var pitch := float(_desk.get("desk_window_pitch_deg", -35.0))
	(desk_hole.mesh as QuadMesh).size = size
	var mat := desk_hole.material_override as ShaderMaterial
	mat.set_shader_parameter("size_m", size)
	mat.set_shader_parameter("radius_m", minf(0.08, size.y * 0.2))
	# A QuadMesh faces +Z (toward the seated user). Pitch 0 = upright like a
	# screen, -90 = flat on the desk; the default leans back toward the eye.
	var local := Transform3D(Basis(Vector3.RIGHT, deg_to_rad(pitch)),
			Vector3(0.0, DESIGN_EYE_M - below, -fwd))
	desk_hole.transform = _anchor * local

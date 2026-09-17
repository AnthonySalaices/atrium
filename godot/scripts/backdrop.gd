extends Node3D
class_name Backdrop

## What you see behind the windows. Driven by `backdrop` in the Lua config:
##
##   mode = "passthrough"  -> your real room (clear colour, alpha-blended)
##   mode = "default"      -> a shipped preset:
##       preset = "cafe"    the Astra-built coffee shop (AS-0002), a GLB with
##                          baked lighting and a handful of slow animation loops
##       preset = "nebula"  the procedural sky that shipped first
##       preset = "void"    flat dark
##   mode = "custom"       -> your own .glb, fetched from the daemon at runtime
##                          (`backdrop.custom.glb` on the host; `glasshouse pack`)
##
## ⭐ Glass is for the windows only; nothing here is glass.
##
## Every preset is built once and switched with `visible` / background mode, so a
## config save flips between them live without reloading anything.

const CAFE_SCENE := "res://backdrops/cafe.glb"
const VOID_COLOR := Color(0.035, 0.030, 0.028)
const CAFE_CLEAR := Color(0.10, 0.08, 0.07)   # only seen through a gap Astra left

var env: Environment
var sky_mat: ShaderMaterial
var room: Node3D
var mode := "default"
var preset := "nebula"
var _players: Array = []
var _anchor := Transform3D.IDENTITY

# Which GLB `room` currently holds, so switching preset <-> custom rebuilds it.
var _room_kind := ""

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
		room.transform = _anchor
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
			"cafe":
				if _ensure_room("cafe"):
					env.background_mode = Environment.BG_COLOR
					env.background_color = CAFE_CLEAR
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


## Instantiate the café once. Returns false when the GLB is not in the build.
func _ensure_room(kind: String) -> bool:
	if room != null and _room_kind == kind:
		return true
	if kind != "cafe":
		return false
	if not ResourceLoader.exists(CAFE_SCENE):
		print("[backdrop] %s is not in this build" % CAFE_SCENE)
		return false
	var packed := load(CAFE_SCENE) as PackedScene
	if packed == null:
		print("[backdrop] %s failed to load" % CAFE_SCENE)
		return false
	var node := packed.instantiate() as Node3D
	node.name = "Cafe"
	_install_room(node, "cafe")
	return true


## Put a room in place, replacing whatever was there. One room exists at a time:
## two GLBs of baked geometry is a lot of memory for something you cannot see.
func _install_room(node: Node3D, kind: String) -> void:
	if room != null:
		remove_child(room)
		room.queue_free()
	_players.clear()
	room = node
	_room_kind = kind
	room.transform = _anchor
	add_child(room)
	_fix_materials(room)
	_start_loops(room)
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
			var anim: Animation = ap.get_animation(names[i])
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
			player.play(names[i])
			_players.append(player)


## ⚠️ The room's lighting is BAKED INTO VERTEX COLOURS and its material is
## `KHR_materials_unlit`. Godot's glTF importer keeps the unlit flag but does
## not turn on "vertex colour as albedo", so the whole café rendered pure white
## the first time — every wall, every patron. Force it here rather than depend
## on an import setting that a fresh checkout would not have.
func _fix_materials(n: Node) -> void:
	if n is MeshInstance3D and n.mesh:
		for i in range(n.mesh.get_surface_count()):
			var m: Material = n.mesh.surface_get_material(i)
			if m is BaseMaterial3D:
				m.vertex_color_use_as_albedo = true
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for c in n.get_children():
		_fix_materials(c)


func _collect_players(n: Node, out: Array) -> void:
	if n is AnimationPlayer:
		out.append(n)
	for c in n.get_children():
		_collect_players(c, out)

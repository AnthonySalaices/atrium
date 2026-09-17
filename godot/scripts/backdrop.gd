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
##   mode = "custom"       -> ⏳ your own .glb, not wired yet (falls back to default)
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


## Put the room's seat under the user. `t` is the rig transform (head position
## and yaw after a recentre); the room takes its x/z and yaw with its floor kept
## at y = 0, so recentring carries the café with the panels instead of leaving
## the seat wherever the play space happened to start.
func anchor(t: Transform3D) -> void:
	var fwd := -t.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.001:
		fwd = Vector3(0, 0, -1)
	_anchor = Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP),
			Vector3(t.origin.x, 0.0, t.origin.z))
	if room:
		room.transform = _anchor


## Apply the `backdrop` table from the served config.
func apply(bd: Dictionary) -> void:
	mode = str(bd.get("mode", "default"))
	var d: Dictionary = bd.get("default", {})
	preset = str(d.get("preset", "nebula"))
	var dim := clampf(float(d.get("dim", 0.0)), 0.0, 1.0)

	if mode == "custom":
		# ⏳ Not implemented: the daemon does not serve a user .glb yet. Say so
		# once rather than silently showing the wrong thing.
		print("[backdrop] custom mode is not wired yet — showing preset '%s'" % preset)
		mode = "default"

	# ⚠️ WorldEnvironment is a plain Node, not a VisualInstance3D — it has no
	# `visible`. Switch the background mode instead.
	if mode == "passthrough":
		env.background_mode = Environment.BG_CLEAR_COLOR
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_show_room(false)
	else:
		match preset:
			"cafe":
				if _ensure_room():
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
	print("[backdrop] mode=%s preset=%s dim=%.2f" % [mode, preset, dim])


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
func _ensure_room() -> bool:
	if room != null:
		return true
	if not ResourceLoader.exists(CAFE_SCENE):
		print("[backdrop] %s is not in this build" % CAFE_SCENE)
		return false
	var packed := load(CAFE_SCENE) as PackedScene
	if packed == null:
		print("[backdrop] %s failed to load" % CAFE_SCENE)
		return false
	room = packed.instantiate() as Node3D
	room.name = "Cafe"
	room.transform = _anchor
	add_child(room)
	_fix_materials(room)
	_start_loops(room)
	print("[backdrop] café loaded: %d animation loop(s)" % _players.size())
	return true


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

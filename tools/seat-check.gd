extends SceneTree
## Headless: seat Empties line up with the origin, and the material fix keeps
## vertex colours only where a surface has them.  $GODOT --headless --path godot --script res://../tools/seat-check.gd
var fails := 0

func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1

func _init() -> void:
	var root := Node3D.new()
	var mid := Node3D.new()
	mid.position = Vector3(10, 0, 0)
	root.add_child(mid)
	var seat := Node3D.new()
	seat.name = "Seat_Lawn"
	seat.position = Vector3(0, -0.4, 5)
	seat.rotation.y = deg_to_rad(90)
	mid.add_child(seat)
	var t := Backdrop._seat_of(root, "Seat_Lawn")
	var world_seat := t.origin
	check(world_seat.is_equal_approx(Vector3(10, -0.4, 5)), "seat found through a parent: %s" % world_seat)
	var placed := t.affine_inverse() * world_seat
	check(placed.is_equal_approx(Vector3.ZERO), "seat lands on the origin: %s" % placed)
	var fwd := (t.affine_inverse().basis * (t.basis * Vector3(0, 0, -1)))
	check(fwd.is_equal_approx(Vector3(0, 0, -1)), "seat forward becomes -Z")
	check(Backdrop._seat_of(root, "").is_equal_approx(Transform3D.IDENTITY), "no seat = identity")
	check(Backdrop._seat_of(root, "Nope").is_equal_approx(Transform3D.IDENTITY), "missing seat = identity")
	check(Backdrop.has_preset("cabin") and Backdrop.has_preset("cafe-night"), "cabin + cafe-night in the build")

	var cafe := (load("res://backdrops/cafe.glb") as PackedScene).instantiate()
	var bd := Backdrop.new()
	bd._fix_materials(cafe)
	var on := 0
	var total := 0
	for mi in cafe.find_children("*", "MeshInstance3D", true, false):
		for i in range(mi.mesh.get_surface_count()):
			var m = mi.mesh.surface_get_material(i)
			if m is BaseMaterial3D:
				total += 1
				if m.vertex_color_use_as_albedo:
					on += 1
	check(total > 0 and on == total, "café keeps vertex colours on %d/%d surfaces" % [on, total])
	var am := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	am.surface_set_material(0, StandardMaterial3D.new())
	var tex_mi := MeshInstance3D.new()
	tex_mi.mesh = am
	bd._fix_materials(tex_mi)
	check(not (am.surface_get_material(0) as BaseMaterial3D).vertex_color_use_as_albedo,
			"no COLOR_0 -> vertex colour off (texture shows)")
	# Keyboard view: on in a room, off in passthrough, placed in ANCHOR space.
	var b2 := Backdrop.new()
	b2.apply({"mode": "default", "default": {"preset": "void"},
			"passthrough": {"desk_window": true, "desk_window_width_m": 0.38, "desk_window_height_m": 0.16,
				"desk_window_forward_m": 0.45, "desk_window_below_eye_m": 0.40,
				"desk_window_pitch_deg": -35.0}})
	check(b2.desk_window_on() and b2.desk_hole != null and b2.desk_hole.visible, "keyboard view on in a room")
	b2.anchor(Transform3D(Basis.IDENTITY, Vector3(0.3, 1.10, -0.2)))
	var hp := b2.desk_hole.global_transform.origin if b2.desk_hole.is_inside_tree() else b2.desk_hole.transform.origin
	check(hp.is_equal_approx(Vector3(0.3, 1.10 - 0.40, -0.2 - 0.45)),
			"keyboard view 0.40 m below the eye, 0.45 m ahead: %s" % hp)
	check(b2.dome != null and b2.dome.visible and b2.dome.material_override is StandardMaterial3D,
			"void + keyboard view -> an opaque dome")
	b2.apply({"mode": "default", "default": {"preset": "nebula"}, "passthrough": {"desk_window": true}})
	check(b2.dome.visible and b2.dome.material_override is ShaderMaterial, "night sky + keyboard view -> the night dome")
	b2.apply({"mode": "default", "default": {"preset": "nebula"}, "passthrough": {"desk_window": false}})
	check(not b2.dome.visible, "no keyboard view -> no dome (the sky is enough)")
	b2.apply({"mode": "passthrough", "passthrough": {"desk_window": true}})
	check(not b2.desk_window_on() and not b2.desk_hole.visible, "no keyboard view in full passthrough")
	print("all green" if fails == 0 else "%d FAILED" % fails)
	quit(1 if fails else 0)

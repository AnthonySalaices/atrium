extends SceneTree
## Fails if any imported backdrop mesh still has compressed vertex positions.
## ⚠️ Godot's default import stores positions as 16 bits across the mesh AABB;
## the café is one 430 m x 1 km mesh, so heights snapped to ~6.6 mm steps and a
## napkin 1 mm above the table landed ON it — "disco mode" (9/17).
## Run: $GODOT --headless --path godot --script ../tools/mesh-compress-check.gd

func _check(n: Node, bad: Array) -> void:
	if n is MeshInstance3D and n.mesh:
		for s in range(n.mesh.get_surface_count()):
			var fmt: int = n.mesh.surface_get_format(s)
			if fmt & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES:
				bad.append("%s surface %d" % [n.name, s])
	for c in n.get_children():
		_check(c, bad)

func _init() -> void:
	var bad: Array = []
	var d := DirAccess.open("res://backdrops")
	for f in d.get_files():
		if f.ends_with(".glb"):
			var root: Node = (load("res://backdrops/" + f) as PackedScene).instantiate()
			_check(root, bad)
			root.free()
	print("mesh-compress-check: ", "PASS" if bad.is_empty() else "FAIL " + str(bad))
	quit(0 if bad.is_empty() else 1)

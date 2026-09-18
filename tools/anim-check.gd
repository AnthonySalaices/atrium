extends SceneTree
## Fails unless the café actually MOVES after backdrop.gd starts its loops.
## ⚠️ "Every player is playing" is not enough: on 9/17 all eleven played and
## the room stood still, because each clip also held every other node at rest.
## Run: $GODOT --headless --path godot --script ../tools/anim-check.gd
var room: Node3D
var players: Array = []
var frames := 0
var fan: Node3D
var fan0: Vector3
var bone0: Transform3D
var skel: Skeleton3D
func _walk(n: Node, cls: String, out: Array) -> void:
	if n.is_class(cls): out.append(n)
	for c in n.get_children(): _walk(c, cls, out)
func _initialize() -> void:
	var bd = load("res://scripts/backdrop.gd").new()
	room = (load("res://backdrops/cafe.glb") as PackedScene).instantiate()
	root.add_child(room)
	bd._add_collision(room)
	bd._start_loops(room)
	players = bd._players
	fan = room.find_child("Ceiling_fan*", true, false)
	fan0 = fan.rotation if fan else Vector3.ZERO
	var sk: Array = []; _walk(room, "Skeleton3D", sk); skel = sk[0]
	bone0 = skel.get_bone_pose(1)
func _process(delta: float) -> bool:
	frames += 1
	if frames == 120:
		var ok := not fan.rotation.is_equal_approx(fan0) and not skel.get_bone_pose(1).is_equal_approx(bone0)
		print("anim-check: ", "PASS" if ok else "FAIL (fan or patron frozen)")
		quit(0 if ok else 1)
		return true
	return false

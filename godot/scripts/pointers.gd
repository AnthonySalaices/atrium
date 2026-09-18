extends Node3D
class_name Pointers

## Controllers and hands, as one thing: a ray with a button on it.
##
## Each Quest controller's aim pose gives a ray; the trigger is the button.
## When the controllers are set down and hand tracking takes over, the
## `ext/hand_interaction_ext` profile in the action map binds the same
## `trigger_click` action to the index pinch and the same `aim_pose` to the
## hand's aim, so nothing in here knows or cares which one it is talking to.
##
## ⛔ Composition layers receive no input and draw OVER the scene. So the
## thing that is hit-tested is the in-scene glass FRAME behind the terminal
## layer (title strip included) and the rail cards — never the layer — and
## the hit dot over the text is drawn INTO the terminal viewport by the owner
## (`grid_hover`), because a 3D dot there would be hidden behind the layer.
##
## Gestures, every one optional (config `pointer`):
##   select  press+release on a rail card            -> card_selected(key)
##   drag    hold on the title strip, move the hand  -> focus_moved(world_pos)
##           OR grip (grasp) anywhere on the frame
##           thumbstick fwd/back while holding       -> push / pull
##           thumbstick left/right while holding     -> focus_resized(factor)
##   scroll  hold on the text and drag up/down       -> scroll(lines, col, row)
##           thumbstick up/down while pointing at it -> scroll(...)
##
## The keyboard stays complete without any of this. A hand that is typing
## (`note_typing`) cannot pinch-grab anything for `typing_lockout_ms` — resting
## fingers on a keyboard look exactly like pinches to the tracker.

signal card_selected(key: String)
signal overflow_selected
signal focus_moved(world_pos: Vector3)
signal focus_drag_ended
## Thumbstick left/right while holding the window: a size factor per second
## (>1 = bigger), applied by the owner as a font-size change.
signal focus_resized(factor: float)
## lines > 0 = older (up), < 0 = newer (down); col/row = 1-based cell under the ray.
signal scroll(lines: int, col: int, row: int)
## The cell the ray is over, or (-1, -1). Only emitted when it changes.
signal grid_hover(col: int, row: int)
## A quick press-and-release on the text/page surface that did not scroll.
## `uv` is 0..1 across the layer, (0,0) top-left. Terminals ignore it; a web
## page turns it into a click.
signal surface_tap(uv: Vector2)

const TAP_MAX_S := 0.6
const DRAG_DIST_MIN := 0.6
const DRAG_DIST_MAX := 3.0
const PUSH_PULL_M_PER_S := 1.2
const RESIZE_PER_S := 0.9          # 90 % per second at full deflection
const RAY_IDLE_M := 0.6
const DOT_RADIUS_M := 0.006
const HAPTIC_TAP := 0.35
const HAPTIC_GRAB := 0.55

var enabled := true
var allow_select := true
var allow_drag := true
var allow_scroll := true
var show_ray := true
var scroll_lines_per_s := 14.0
var typing_lockout_ms := 1500

# Targets. The frame is one quad in the focus group's local space; its top
# `title_h` metres are the strip you drag by, the rest maps onto the grid.
var _frame: MeshInstance3D
var _frame_size := Vector2.ZERO
var _title_h := 0.0
var _term_size := Vector2.ZERO
var _cols := 80
var _rows := 28
var _cards: Array = []            # [{mesh, size, key, overflow}]

var _hands: Array = []            # one Dictionary of state per hand
var _typed_ms := -100000
var _hover_cell := Vector2i(-1, -1)


func _ready() -> void:
	for side in ["left_hand", "right_hand"]:
		var c := XRController3D.new()
		c.tracker = side
		c.pose = "aim"
		add_child(c)
		_hands.append(_new_hand(c, side))


func _new_hand(c: XRController3D, side: String) -> Dictionary:
	var ray := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	ray.mesh = im
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.vertex_color_use_as_albedo = true
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ray.material_override = rm
	ray.top_level = true          # world space; the mesh carries absolute points
	add_child(ray)

	var dot := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = DOT_RADIUS_M
	sm.height = DOT_RADIUS_M * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	dot.mesh = sm
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.albedo_color = GlassUI.AMBER
	dot.material_override = dm
	dot.top_level = true
	dot.visible = false
	add_child(dot)

	return {
		"ctrl": c, "side": side, "ray": ray, "dot": dot,
		"pressed": false, "gripped": false, "mode": "", "target": {}, "press_t": 0.0,
		"grab_dist": 0.0, "grab_offset": Vector3.ZERO, "press_local_y": 0.0,
		"scroll_acc": 0.0, "hit": {},
	}


## Called by the owner whenever the focus panel is (re)built.
func set_frame(mesh: MeshInstance3D, outer: Vector2, title_h: float,
		term: Vector2, cols: int, rows: int) -> void:
	_frame = mesh
	_frame_size = outer
	_title_h = title_h
	_term_size = term
	_cols = cols
	_rows = rows
	_drop_targets()


## Called by the owner whenever the rail is rebuilt. Items: {mesh, size, key}
## or {mesh, size, overflow: true}.
func set_cards(cards: Array) -> void:
	_cards = cards
	_drop_targets()


func set_config(p: Dictionary, lockout_ms: int) -> void:
	enabled = bool(p.get("enabled", true))
	allow_select = bool(p.get("select", true))
	allow_drag = bool(p.get("drag", true))
	allow_scroll = bool(p.get("scroll", true))
	show_ray = bool(p.get("show_ray", true))
	scroll_lines_per_s = float(p.get("scroll_lines_per_s", 14.0))
	typing_lockout_ms = lockout_ms
	if not enabled:
		for h in _hands:
			_end_gesture(h)
			_hide(h)


## The keyboard just sent something to a pane.
func note_typing() -> void:
	_typed_ms = Time.get_ticks_msec()


## A target that was freed mid-gesture must not be touched again — but a
## re-registration of the SAME frame (a live resize re-pushes it every frame)
## must not end the grab that is doing the resizing. Only a gesture whose
## target mesh is gone ends here.
func _drop_targets() -> void:
	for h in _hands:
		if h["mode"] != "":
			var m = h["target"].get("mesh")
			if m == null or not is_instance_valid(m) or not _is_target(m):
				_end_gesture(h)
		h["hit"] = {}


func _is_target(m) -> bool:
	if m == _frame:
		return true
	for card in _cards:
		if card["mesh"] == m:
			return true
	return false


func _process(delta: float) -> void:
	if not enabled:
		return
	var hover := Vector2i(-1, -1)
	for h in _hands:
		var c: XRController3D = h["ctrl"]
		if not c.get_is_active():
			if h["mode"] != "":
				_end_gesture(h)
			_hide(h)
			continue
		var t := c.global_transform
		var stick := c.get_vector2("primary")
		var cell := step(h, t.origin, -t.basis.z, c.is_button_pressed("trigger_click"),
				stick, delta, _is_hand(c), c.is_button_pressed("grip_click"))
		if cell.x > 0:
			hover = cell
	if hover != _hover_cell:
		_hover_cell = hover
		emit_signal("grid_hover", hover.x, hover.y)


## One frame of one hand. Pure of XR: the headless check drives this directly.
## Returns the grid cell under the ray (1-based) or (-1, -1).
func step(h: Dictionary, origin: Vector3, dir: Vector3, pressed: bool,
		stick: Vector2, delta: float, is_hand: bool, grip: bool = false) -> Vector2i:
	var hit := _nearest_hit(origin, dir)
	h["hit"] = hit
	var cell := Vector2i(-1, -1)
	if not hit.is_empty() and hit["kind"] == "grid":
		cell = hit["cell"]

	var now := Time.get_ticks_msec()

	# Grip = grab. Anywhere on the frame, strip or text: the controller
	# convention, and the hand's grasp lands on the same action. A grab in
	# progress owns the hand until the grip opens; the trigger is ignored.
	var was_grip: bool = h["gripped"]
	h["gripped"] = grip
	if grip and not was_grip and h["mode"] == "" and allow_drag \
			and not hit.is_empty() and hit["kind"] in ["strip", "grid"] \
			and not (is_hand and (now - _typed_ms) < typing_lockout_ms):
		h["target"] = hit
		h["press_t"] = now / 1000.0
		h["mode"] = "drag"
		h["grab_dist"] = hit["dist"]
		h["grab_offset"] = (_frame.get_parent() as Node3D).global_position - hit["point"]
		h["grab_by"] = "grip"
		_haptic(h, HAPTIC_GRAB)
	if h["mode"] == "drag" and h.get("grab_by", "") == "grip":
		if grip:
			_continue_gesture(h, hit, origin, dir, stick, delta)
		else:
			_end_gesture(h)
		h["pressed"] = pressed
		_draw(h, origin, dir, hit)
		return cell

	var was: bool = h["pressed"]
	h["pressed"] = pressed

	if pressed and not was:
		# Press: what did it land on?
		var locked := is_hand and (now - _typed_ms) < typing_lockout_ms
		if not hit.is_empty() and not locked:
			_begin_gesture(h, hit, origin, dir)
	elif pressed and was and h["mode"] != "":
		_continue_gesture(h, hit, origin, dir, stick, delta)
	elif not pressed and was:
		_release(h, hit, now)

	# Thumbstick scroll needs no press: point at the text and flick.
	if allow_scroll and h["mode"] == "" and not hit.is_empty() and hit["kind"] == "grid" \
			and absf(stick.y) > 0.15:
		h["scroll_acc"] += stick.y * scroll_lines_per_s * delta
		var n := int(h["scroll_acc"])
		if n != 0:
			h["scroll_acc"] -= n
			emit_signal("scroll", n, cell.x, cell.y)
	else:
		h["scroll_acc"] = 0.0

	_draw(h, origin, dir, hit)
	return cell


func _begin_gesture(h: Dictionary, hit: Dictionary, origin: Vector3, dir: Vector3) -> void:
	h["target"] = hit
	h["press_t"] = Time.get_ticks_msec() / 1000.0
	match hit["kind"]:
		"strip":
			if not allow_drag:
				return
			h["mode"] = "drag"
			h["grab_dist"] = hit["dist"]
			h["grab_offset"] = (_frame.get_parent() as Node3D).global_position - hit["point"]
			h["grab_by"] = "trigger"
			_haptic(h, HAPTIC_GRAB)
		"grid":
			if not allow_scroll:
				return
			h["mode"] = "scroll"
			h["press_local_y"] = hit["local"].y
			h["scrolled"] = false
		"card", "overflow":
			if not allow_select:
				return
			h["mode"] = "tap"


func _continue_gesture(h: Dictionary, hit: Dictionary, origin: Vector3, dir: Vector3,
		stick: Vector2, delta: float) -> void:
	match h["mode"]:
		"drag":
			if _frame == null or not is_instance_valid(_frame):
				_end_gesture(h)
				return
			if absf(stick.y) > 0.15:
				h["grab_dist"] = clampf(h["grab_dist"] + stick.y * PUSH_PULL_M_PER_S * delta,
						DRAG_DIST_MIN, DRAG_DIST_MAX)
			if absf(stick.x) > 0.3:
				emit_signal("focus_resized", 1.0 + stick.x * RESIZE_PER_S * delta)
			emit_signal("focus_moved", origin + dir * h["grab_dist"] + h["grab_offset"])
		"scroll":
			# Drag the text: the hand moving up drags the content up, which
			# reveals what is BELOW — i.e. newer lines, a scroll DOWN.
			if hit.is_empty() or hit["kind"] != "grid" and hit["kind"] != "strip":
				return
			var row_h := _term_size.y / float(_rows)
			var dy: float = hit["local"].y - h["press_local_y"]
			var rows := int(dy / row_h)
			if rows != 0:
				h["scrolled"] = true
				h["press_local_y"] += rows * row_h
				var cell: Vector2i = hit.get("cell", Vector2i(1, 1))
				emit_signal("scroll", -rows, maxi(cell.x, 1), maxi(cell.y, 1))


func _release(h: Dictionary, hit: Dictionary, now_ms: int) -> void:
	var mode: String = h["mode"]
	var target: Dictionary = h["target"]
	if mode == "tap" and not hit.is_empty() and not target.is_empty() \
			and hit.get("mesh") == target.get("mesh") \
			and (now_ms / 1000.0 - float(h["press_t"])) <= TAP_MAX_S:
		_haptic(h, HAPTIC_TAP)
		if target["kind"] == "overflow":
			emit_signal("overflow_selected")
		else:
			emit_signal("card_selected", str(target["key"]))
	elif mode == "scroll" and not h.get("scrolled", true) and not hit.is_empty() \
			and hit["kind"] == "grid" \
			and (now_ms / 1000.0 - float(h["press_t"])) <= TAP_MAX_S:
		_haptic(h, HAPTIC_TAP)
		emit_signal("surface_tap", _uv_for(hit["local"]))
	_end_gesture(h)


func _end_gesture(h: Dictionary) -> void:
	if h["mode"] == "drag":
		emit_signal("focus_drag_ended")
	h["mode"] = ""
	h["target"] = {}
	h["grab_by"] = ""


func _haptic(h: Dictionary, amp: float) -> void:
	var c: XRController3D = h["ctrl"]
	if c:
		c.trigger_haptic_pulse("haptic", 0.0, amp, 0.04, 0.0)


func _is_hand(c: XRController3D) -> bool:
	var tr := XRServer.get_tracker(c.tracker)
	if tr == null:
		return false
	return String(tr.get_tracker_profile()).contains("hand_interaction")


## The nearest quad the ray crosses, as
## {kind, mesh, key?, point, dist, local: Vector2, cell?: Vector2i}.
func _nearest_hit(origin: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	if _frame != null and is_instance_valid(_frame):
		var r := hit_quad(_frame.global_transform, _frame_size, origin, dir)
		if not r.is_empty():
			var local: Vector2 = r["local"]
			if local.y > _frame_size.y * 0.5 - _title_h:
				r["kind"] = "strip"
			else:
				r["kind"] = "grid"
				r["cell"] = _cell_for(local)
			r["mesh"] = _frame
			best = r
	for card in _cards:
		var m: MeshInstance3D = card["mesh"]
		if m == null or not is_instance_valid(m):
			continue
		var r := hit_quad(m.global_transform, card["size"], origin, dir)
		if r.is_empty():
			continue
		if best.is_empty() or r["dist"] < best["dist"]:
			r["kind"] = "overflow" if card.get("overflow", false) else "card"
			r["key"] = card.get("key", "")
			r["mesh"] = m
			best = r
	return best


## The frame's local point -> 0..1 across the layer, (0,0) top-left.
func _uv_for(local: Vector2) -> Vector2:
	var gy := local.y + _title_h * 0.5
	return Vector2(clampf((local.x + _term_size.x * 0.5) / _term_size.x, 0.0, 1.0),
			clampf((_term_size.y * 0.5 - gy) / _term_size.y, 0.0, 1.0))


## The frame's local point -> 1-based grid cell. The layer sits at the group
## origin and the frame is raised by half the strip, so undo that offset.
func _cell_for(local: Vector2) -> Vector2i:
	var gx := local.x
	var gy := local.y + _title_h * 0.5
	var u := (gx + _term_size.x * 0.5) / _term_size.x
	var v := (_term_size.y * 0.5 - gy) / _term_size.y
	return Vector2i(clampi(int(floor(u * _cols)) + 1, 1, _cols),
			clampi(int(floor(v * _rows)) + 1, 1, _rows))


## Ray against a QuadMesh in the XY plane of `xf`, facing +Z. Returns {} or
## {point, dist, local}. Back faces count too: a window you walked behind is
## still yours to grab.
static func hit_quad(xf: Transform3D, size: Vector2, origin: Vector3, dir: Vector3) -> Dictionary:
	var n := xf.basis.z.normalized()
	var denom := dir.dot(n)
	if absf(denom) < 1e-6:
		return {}
	var t := (xf.origin - origin).dot(n) / denom
	if t <= 0.0:
		return {}
	var p := origin + dir * t
	var l := xf.affine_inverse() * p
	if absf(l.x) > size.x * 0.5 or absf(l.y) > size.y * 0.5:
		return {}
	return {"point": p, "dist": t, "local": Vector2(l.x, l.y)}


func _draw(h: Dictionary, origin: Vector3, dir: Vector3, hit: Dictionary) -> void:
	var ray: MeshInstance3D = h["ray"]
	var dot: MeshInstance3D = h["dot"]
	var im := ray.mesh as ImmediateMesh
	im.clear_surfaces()
	var end: Vector3
	var col: Color
	if hit.is_empty():
		end = origin + dir * RAY_IDLE_M
		col = Color(GlassUI.TEXT_SECONDARY, 0.25)
	else:
		end = hit["point"]
		col = Color(GlassUI.AMBER, 0.85 if h["mode"] != "" else 0.6)
	ray.visible = show_ray
	if show_ray:
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		im.surface_set_color(Color(col, 0.0))
		im.surface_add_vertex(origin)
		im.surface_set_color(col)
		im.surface_add_vertex(end)
		im.surface_end()
	# The dot only means something on scene geometry; over the grid the owner
	# draws it into the layer instead, where it can actually be seen.
	dot.visible = not hit.is_empty() and hit["kind"] != "grid"
	if dot.visible:
		dot.global_position = end


func _hide(h: Dictionary) -> void:
	(h["ray"] as MeshInstance3D).visible = false
	(h["dot"] as MeshInstance3D).visible = false
	h["hit"] = {}

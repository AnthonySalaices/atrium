extends SceneTree

## Headless check of the pointer gestures — no headset, no XR runtime.
##
##   source toolchain/env.sh && $GODOT --headless --path godot \
##       --script res://../tools/pointer-check.gd
##
## Builds a real focus frame and rail cards through GlassUI, then drives
## Pointers.step() with synthetic rays and asserts on the signals. This is the
## test that says "the hit maths and the gesture state machine are right"; what
## it cannot say is whether the runtime delivers poses and pinches, which is a
## headset window.
##
## ⚠️ A SceneTree script cannot add nodes in _init() — the tree is not up yet —
## so everything happens on the first _process().

var _done := false
var fails := 0
var got: Array = []


func check(ok: bool, what: String, detail: String = "") -> void:
	print(("  ok   " if ok else "  FAIL ") + what + (("  — " + detail) if (not ok and detail != "") else ""))
	if not ok:
		fails += 1


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("all green" if fails == 0 else "%d FAILED" % fails)
	quit(0 if fails == 0 else 1)
	return true


func _run() -> void:
	var font: FontFile = load("res://fonts/IosevkaTerm-Medium.ttf")
	var rig := Node3D.new()
	root.add_child(rig)
	var ptr := Pointers.new()
	root.add_child(ptr)
	ptr.card_selected.connect(func(k): got.append(["card", k]))
	ptr.overflow_selected.connect(func(): got.append(["overflow"]))
	ptr.focus_moved.connect(func(p): got.append(["moved", p]))
	ptr.focus_drag_ended.connect(func(): got.append(["drag_end"]))
	ptr.focus_resized.connect(func(f): got.append(["resized", f]))
	ptr.scroll.connect(func(n, c, r): got.append(["scroll", n, c, r]))

	# The focus frame exactly as terminal.gd builds it.
	var cols := 80
	var rows := 28
	var dist := 1.5
	var term := GlassUI.term_size(cols, rows, 22.3, dist)
	var pad := GlassUI.FRAME_PAD_M
	var title_h := GlassUI.FRAME_TITLE_M
	var outer := Vector2(term.x + pad * 2.0, term.y + pad * 2.0 + title_h)
	var group := GlassUI.oriented_group(rig, GlassUI.polar(GlassUI.FOCUS_YAW_DEG, GlassUI.FOCUS_ELEV_DEG, dist))
	var params := GlassUI.FRAME_TOKENS.duplicate()
	var frame := GlassUI.glass(group, outer, Vector3(0, title_h * 0.5, -0.004), params)
	ptr.set_frame(frame, outer, title_h, term, cols, rows)

	var size := GlassUI.angular_size(GlassUI.CARD_W_DEG, GlassUI.CARD_H_DEG, GlassUI.RAIL_DIST)
	var cards: Array = []
	for i in range(3):
		var pos := GlassUI.polar(GlassUI.RAIL_YAW_DEG, float(GlassUI.RAIL_ELEV_DEG[i]), GlassUI.RAIL_DIST)
		var c := GlassUI.card(rig, font, pos, size, "s%d" % i, "idle", 0.0)
		cards.append({"mesh": c["mesh"], "size": size, "key": "s%d" % i})
	var opos := GlassUI.polar(GlassUI.RAIL_YAW_DEG, float(GlassUI.RAIL_ELEV_DEG[3]), GlassUI.RAIL_DIST)
	var o := GlassUI.card(rig, font, opos, size, "+2 more", "", 0.0)
	cards.append({"mesh": o["mesh"], "size": size, "overflow": true})
	ptr.set_cards(cards)
	var h: Dictionary = ptr._hands[0]

	print("── hit maths")
	var eye := Vector3.ZERO
	var centre: Vector3 = frame.global_position
	var r := Pointers.hit_quad(frame.global_transform, outer, eye, (centre - eye).normalized())
	check(not r.is_empty() and r["local"].length() < 0.002, "ray through the frame centre hits at local (0,0)",
			str(r))
	var miss := Pointers.hit_quad(frame.global_transform, outer, eye, Vector3(0, 0, 1))
	check(miss.is_empty(), "ray pointing away misses")
	var edge := Pointers.hit_quad(frame.global_transform, outer, eye,
			(frame.global_transform * Vector3(outer.x * 0.5 + 0.01, 0, 0) - eye).normalized())
	check(edge.is_empty(), "1 cm outside the edge misses")

	# Strip vs grid, and the grid cell.
	var strip_pt: Vector3 = frame.global_transform * Vector3(0, outer.y * 0.5 - title_h * 0.5, 0)
	var strip_hit := ptr._nearest_hit(eye, (strip_pt - eye).normalized())
	check(strip_hit.get("kind") == "strip", "top band is the title strip", str(strip_hit.get("kind")))
	# Layer origin = group origin; frame is raised by title_h/2, so grid centre
	# is frame-local (0, -title_h/2).
	var grid_pt: Vector3 = frame.global_transform * Vector3(0, -title_h * 0.5, 0)
	var grid_hit := ptr._nearest_hit(eye, (grid_pt - eye).normalized())
	check(grid_hit.get("kind") == "grid", "middle is the grid", str(grid_hit.get("kind")))
	check(grid_hit.get("cell") == Vector2i(41, 15), "centre of an 80x28 grid is cell (41,15)",
			str(grid_hit.get("cell")))
	var tl_pt: Vector3 = frame.global_transform * Vector3(-term.x * 0.5 + 0.001, -title_h * 0.5 + term.y * 0.5 - 0.001, 0)
	var tl := ptr._nearest_hit(eye, (tl_pt - eye).normalized())
	check(tl.get("cell") == Vector2i(1, 1), "top-left of the text is cell (1,1)", str(tl.get("cell")))

	var card_pt: Vector3 = (cards[1]["mesh"] as MeshInstance3D).global_position
	var card_hit := ptr._nearest_hit(eye, (card_pt - eye).normalized())
	check(card_hit.get("kind") == "card" and card_hit.get("key") == "s1", "rail card 1 is hit by key",
			str(card_hit))

	print("── select")
	var cdir := (card_pt - eye).normalized()
	got.clear()
	ptr.step(h, eye, cdir, true, Vector2.ZERO, 0.016, false)
	ptr.step(h, eye, cdir, false, Vector2.ZERO, 0.016, false)
	check(got == [["card", "s1"]], "press+release on a card selects it", str(got))
	got.clear()
	var odir := ((o["mesh"] as MeshInstance3D).global_position - eye).normalized()
	ptr.step(h, eye, odir, true, Vector2.ZERO, 0.016, false)
	ptr.step(h, eye, odir, false, Vector2.ZERO, 0.016, false)
	check(got == [["overflow"]], "the +N card fires overflow", str(got))
	got.clear()
	ptr.step(h, eye, cdir, true, Vector2.ZERO, 0.016, false)
	ptr.step(h, eye, odir, false, Vector2.ZERO, 0.016, false)
	check(got.is_empty(), "release on a different card is not a select", str(got))
	got.clear()
	ptr.allow_select = false
	ptr.step(h, eye, cdir, true, Vector2.ZERO, 0.016, false)
	ptr.step(h, eye, cdir, false, Vector2.ZERO, 0.016, false)
	check(got.is_empty(), "select is optional (pointer.select = false)", str(got))
	ptr.allow_select = true

	print("── drag")
	got.clear()
	var sdir := (strip_pt - eye).normalized()
	ptr.step(h, eye, sdir, true, Vector2.ZERO, 0.016, false)
	check(h["mode"] == "drag", "press on the strip starts a drag", h["mode"])
	# Turn the ray 5 degrees to the right; the group should follow.
	var turned := sdir.rotated(Vector3.UP, deg_to_rad(-5.0))
	ptr.step(h, eye, turned, true, Vector2.ZERO, 0.016, false)
	check(got.size() == 1 and got[0][0] == "moved", "moving the hand emits focus_moved", str(got))
	var before: Vector3 = group.global_position
	var target: Vector3 = got[0][1]
	check(target.distance_to(before) > 0.05 and target.x > before.x, "…to the right of where it was",
			"%s -> %s" % [before, target])
	check(absf(target.distance_to(eye) - before.distance_to(eye)) < 0.02, "…at the same distance",
			"%.3f vs %.3f" % [target.distance_to(eye), before.distance_to(eye)])
	got.clear()
	ptr.step(h, eye, turned, true, Vector2(0, 1), 1.0, false)
	check(got.size() == 1 and (got[0][1] as Vector3).distance_to(eye) > before.distance_to(eye) + 0.5,
			"thumbstick forward while holding pushes it away", str(got))
	got.clear()
	ptr.step(h, eye, turned, false, Vector2.ZERO, 0.016, false)
	check(got == [["drag_end"]], "release ends the drag", str(got))
	check(h["mode"] == "", "…and clears the mode")

	print("── scroll")
	var gdir := (grid_pt - eye).normalized()
	got.clear()
	for i in range(10):
		ptr.step(h, eye, gdir, false, Vector2(0, 1), 0.1, false)      # 1 s at full deflection
	var total := 0
	for g in got:
		if g[0] == "scroll":
			total += g[1]
	check(total == 14, "thumbstick up for 1 s at 14 lines/s scrolls 14 lines older", "total=%d" % total)
	check(got[0][2] == 41 and got[0][3] == 15, "…at the cell under the ray", str(got[0]))
	got.clear()
	ptr.step(h, eye, gdir, true, Vector2.ZERO, 0.016, false)
	check(h["mode"] == "scroll", "press on the text starts a drag-scroll", h["mode"])
	var row_h := term.y / float(rows)
	var up3: Vector3 = frame.global_transform * Vector3(0, -title_h * 0.5 + row_h * 3.2, 0)
	ptr.step(h, eye, (up3 - eye).normalized(), true, Vector2.ZERO, 0.016, false)
	# x = 0 sits exactly on the column boundary between 40 and 41, so accept both.
	check(got.size() == 1 and got[0][0] == "scroll" and got[0][1] == -3 and got[0][2] in [40, 41]
			and got[0][3] == 11, "dragging the text up 3 rows scrolls 3 lines newer, from row 11", str(got))
	got.clear()
	ptr.step(h, eye, (up3 - eye).normalized(), false, Vector2.ZERO, 0.016, false)
	check(got.is_empty() and h["mode"] == "", "release ends it quietly", str(got))

	print("── typing lockout")
	got.clear()
	ptr.note_typing()
	ptr.step(h, eye, cdir, true, Vector2.ZERO, 0.016, true)
	ptr.step(h, eye, cdir, false, Vector2.ZERO, 0.016, true)
	check(got.is_empty(), "a HAND pinch right after typing is ignored", str(got))
	got.clear()
	ptr.step(h, eye, cdir, true, Vector2.ZERO, 0.016, false)
	ptr.step(h, eye, cdir, false, Vector2.ZERO, 0.016, false)
	check(got == [["card", "s1"]], "a CONTROLLER trigger right after typing still works", str(got))

	print("── targets change mid-gesture")
	ptr.step(h, eye, sdir, true, Vector2.ZERO, 0.016, false)
	check(h["mode"] == "drag", "holding the strip")
	got.clear()
	ptr.set_cards([])
	check(h["mode"] == "drag" and got.is_empty(), "a rail rebuild does NOT end a frame grab", str(got))
	ptr.set_frame(frame, outer, title_h, term, cols, rows)
	check(h["mode"] == "drag" and got.is_empty(), "re-pushing the SAME frame (live resize) keeps the grab", str(got))
	ptr.step(h, eye, sdir, true, Vector2(1, 0), 0.5, false)
	check(got.size() == 2 and got[0][0] == "resized" and got[0][1] > 1.3, "thumbstick right while holding asks for a bigger window", str(got))
	got.clear()
	var frame2 := GlassUI.glass(group, outer, Vector3(0, title_h * 0.5, -0.004), params)
	ptr.set_frame(frame2, outer, title_h, term, cols, rows)
	check(h["mode"] == "" and got == [["drag_end"]], "a NEW frame mesh ends the gesture cleanly", str(got))
	ptr.step(h, eye, sdir, false, Vector2.ZERO, 0.016, false)

	# ── Hands near a keyboard (9/17: "the hand control goes wild when typing").
	var hh := ptr._new_hand(null, "test")
	var head := 1.20
	var t0 := 100000
	ptr._typed_ms = -100000
	check(not ptr.hand_allowed(hh, head - 0.60, -0.3, head, t0), "a hand low at the keyboard gets no ray")
	check(not ptr.hand_allowed(hh, head - 0.30, -0.9, head, t0), "a raised hand aimed steeply at the desk gets no ray")
	check(ptr.hand_allowed(hh, head - 0.30, -0.6, head, t0), "a raised hand aimed at the window's bottom rows points")
	hh["raised"] = false
	check(ptr.hand_allowed(hh, head - 0.30, -0.1, head, t0), "a raised hand aimed at the windows points")
	check(ptr.hand_allowed(hh, head - 0.47, -0.1, head, t0), "hysteresis: it stays active a little lower")
	check(not ptr.hand_allowed(hh, head - 0.55, -0.1, head, t0), "...until it drops well below")
	ptr._typed_ms = t0 - 200
	check(not ptr.hand_allowed(hh, head - 0.30, -0.1, head, t0), "typing silences even a raised hand")
	ptr._typed_ms = -100000
	ptr.hands_enabled = false
	check(not ptr.hand_allowed(hh, head - 0.30, -0.1, head, t0), "ctrl+alt+H off: no hands at all")
	ptr.hands_enabled = true
	check(not ptr.deliberate_pinch(hh, true, t0), "a pinch does not count at once")
	check(not ptr.deliberate_pinch(hh, true, t0 + 100), "...nor after 100 ms")
	check(ptr.deliberate_pinch(hh, true, t0 + 160), "...but does once held 150 ms")
	check(not ptr.deliberate_pinch(hh, false, t0 + 170), "letting go releases at once")
	check(not ptr.deliberate_pinch(hh, true, t0 + 180), "and the next pinch starts its own clock")

	# ── A closing hand reports pinch + grasp together (9/17, "hit or miss").
	var hg := ptr._new_hand(null, "right_hand")
	var gd2 := (frame2.global_transform * Vector3(0, -title_h * 0.5, 0) - eye).normalized()
	ptr.step(hg, eye, gd2, false, Vector2.ZERO, 0.016, true, true, false)
	check(hg["mode"] == "scroll", "hand: a grasp over the TEXT scrolls, never drags", str(hg["mode"]))
	ptr.step(hg, eye, gd2, false, Vector2.ZERO, 0.016, true, false, false)
	ptr.step(hg, eye, sdir, false, Vector2.ZERO, 0.016, true, true, false)
	check(hg["mode"] == "drag", "hand: a grasp over the TITLE STRIP drags", str(hg["mode"]))
	ptr.step(hg, eye, gd2, false, Vector2.ZERO, 0.016, true, true, false)
	check(hg["mode"] == "drag", "hand: a running drag keeps its grip over the text", str(hg["mode"]))
	ptr.step(hg, eye, gd2, false, Vector2.ZERO, 0.016, true, false, false)
	var hc := ptr._new_hand(null, "right_hand")
	ptr.step(hc, eye, gd2, false, Vector2.ZERO, 0.016, false, true, true)
	check(hc["mode"] == "drag", "controller: grip over the text still drags", str(hc["mode"]))
	ptr.step(hc, eye, gd2, false, Vector2.ZERO, 0.016, false, false, true)

extends RefCounted
class_name GlassUI

## The settled look and layout from AS-0001, in one place.
##
## Both the shipping client (terminal.gd) and the flat preview (preview.gd)
## build their frames and cards through these helpers, so a number tuned in
## the headset changes the preview too, and the other way round. ⛔ Do not
## copy these constants into a scene script; reference them.
##
## Everything angular is in degrees and everything physical in metres, because
## the layout is perceived in angles (a 15° card) and rendered in metres.

const GLASS_SHADER := preload("res://shaders/glass_card.gdshader")

const FONT_PX := 32                 # 22.3 dmm <-> 32 px on the terminal surface
const CELL := Vector2i(16, 40)

# ── Layout. ⛔ Not preferences: a centred 51° focus plus a 15° card needs ~33°
# of centre separation BEFORE any gutter, so focus-at-0 / rail-at-−34° had about
# 1° of clearance. Focus +6° / rail −30° buys ~3° and keeps the rail near gaze.
const FOCUS_YAW_DEG := 6.0
const FOCUS_ELEV_DEG := -10.0
const RAIL_YAW_DEG := -30.0            # (history: the rail's own polar place, pre-9/17)
const RAIL_DIST := 1.55
# 5.5° cards with 1.5° clear gaps. Slot 0 is RESERVED for whoever needs you.
const RAIL_ELEV_DEG := [3.0, -4.0, -11.0, -18.0]
# ⭐ 9/17 eve (owner): the rail is ATTACHED to the focus window — it hangs off the
# window's left edge in the window's own plane, so dragging or resizing the
# window carries the cards with it. Gaps in metres at the window's distance.
const RAIL_SLOTS := 4
const RAIL_GAP_M := 0.06               # window edge -> card edge
const RAIL_VGAP_M := 0.035             # between cards
const CARD_W_DEG := 15.0
const CARD_H_DEG := 5.5

# Text placement inside a card, in units of card height (AS-0001 NOTES.md).
const TEXT_INSET_H := 0.175
const BASELINE_PRIMARY_H := -0.094     # above centre
const BASELINE_SECONDARY_H := 0.242    # below centre
# ⚠️ UI textures (cards, title strip) are SubViewports sampled by a scene quad in
# the eye buffer, and ViewportTextures have NO mipmaps — so any texture denser
# than the eye buffer's ~17 px/deg aliases when minified ("text with a
# transparent background is pixelated", owner 9/17). The terminal is unaffected:
# a composition layer is filtered by the compositor. Keep these near display
# density: 0.7x the grid's density for the strip, 168 px for a 5.5° card.
const UI_PX_SCALE := 0.7
const TITLE_PX := 28                   # 40 * UI_PX_SCALE
const CARD_H_PX := 168                 # reference card is 329x120; ~1.4x the eye buffer

# Focus frame tokens. ⚠️ Size-aware on purpose: the session card's .100h radius
# on a 1.26 m panel would carve away usable terminal grid.
const FRAME_PAD_M := 0.038
const FRAME_TITLE_M := 0.075
const FRAME_TOKENS := {"radius_h": 0.025, "bezel_h": 0.0045, "falloff_h": 0.008}
const CARD_TOKENS := {"radius_h": 0.100, "bezel_h": 0.018, "falloff_h": 0.032}

const TEXT_PRIMARY := Color(0.957, 0.969, 0.984)      # #F4F7FB
const TEXT_SECONDARY := Color(0.882, 0.910, 0.941)    # #E1E8F0
const AMBER := Color(1.0, 0.722, 0.290)               # #FFB84A
const BODY := Color(0.0627, 0.0980, 0.1333)           # #101922
## The live body colour: the config's `colors.background` (terminal.gd sets it),
## so the frame, the cards and the text behind the cells stay one material.
static var body := BODY

# Attention motion: the edge gain breathes between these at this rate, never to
# zero, and only while the card is actually waiting on you.
const PULSE_HZ := 0.5
const PULSE_GAIN_LO := 0.85
const PULSE_GAIN_HI := 1.10

# States that count as "waiting on you" — mirrors atriumd/focus.py.
const WAITING_STATES := ["needs-input", "error", "done"]


## The right-hand end of a title strip: who is waiting, and whether this pane is
## only a crop of a bigger one (a session that opted out of pinning). Shared with
## the preview so the two cannot drift apart on the widest string the strip holds.
static func title_right_text(waiting: int, crop: Vector2i) -> String:
	var parts: Array[String] = []
	if waiting > 0:
		parts.append("%d waiting" % waiting)
	if crop.x > 0 and crop.y > 0:
		parts.append("desktop %d×%d · crop" % [crop.x, crop.y])
	return " · ".join(parts)


## dmm is the FONT size, so the angular width is cols * cell.x * (dmm / font_px)
## milliradians. ⚠️ Dividing by cell.x instead makes every panel exactly 2x too big.
static func term_size(cols: int, rows: int, dmm: float, dist: float) -> Vector2:
	var vp_w := cols * CELL.x
	var ang := (dmm / float(FONT_PX)) * float(vp_w) / 1000.0
	var w := 2.0 * dist * tan(ang * 0.5)
	return Vector2(w, w * float(rows * CELL.y) / float(vp_w))


static func polar(yaw_deg: float, elev_deg: float, dist: float) -> Vector3:
	var yaw := deg_to_rad(yaw_deg)
	var elev := deg_to_rad(elev_deg)
	return Vector3(dist * cos(elev) * sin(yaw), dist * sin(elev),
			-dist * cos(elev) * cos(yaw))


static func angular_size(w_deg: float, h_deg: float, dist: float) -> Vector2:
	return Vector2(2.0 * dist * tan(deg_to_rad(w_deg) * 0.5),
			2.0 * dist * tan(deg_to_rad(h_deg) * 0.5))


## ⚠️ A quad placed off-axis must be aimed at the eye in BOTH axes; rotating only
## around Y leaves a card above you facing the wall behind your head. `look_at`
## does yaw and pitch together, and the extra 180° is because a QuadMesh faces +Z
## while look_at aims -Z.
## ⛔ Two quads that are each aimed at the eye from slightly different positions
## are NOT coplanar, so a frame and the panel inside it stop nesting — visibly,
## as mismatched margins. Anything that must nest is aimed ONCE as a group and
## then offset in that group's local space.
static func oriented_group(parent: Node, pos: Vector3) -> Node3D:
	var g := Node3D.new()
	g.position = pos
	parent.add_child(g)
	if pos.length() > 0.001:
		g.look_at(Vector3.ZERO, Vector3.UP)
		g.rotate_object_local(Vector3.UP, PI)
	return g


## Where rail card `i` sits in the focus group's local space, given the frame's
## outer size and the card size: to the left of the frame, top-aligned with it,
## in the frame's own plane (z = -0.004, the same 4 mm behind the layer).
static func rail_local(outer: Vector2, card: Vector2, i: int) -> Vector3:
	var frame_top := FRAME_TITLE_M * 0.5 + outer.y * 0.5
	return Vector3(-(outer.x * 0.5 + RAIL_GAP_M + card.x * 0.5),
			frame_top - card.y * 0.5 - float(i) * (card.y + RAIL_VGAP_M), -0.004)


## A glass quad in a group's local space. Returns the mesh so a caller can drive
## `attention` / `gain_attention` on its material later.
static func glass(parent: Node3D, size: Vector2, local_pos: Vector3,
		params: Dictionary) -> MeshInstance3D:
	var mat := ShaderMaterial.new()
	mat.shader = GLASS_SHADER
	# ⚠️ The SDF works in card-height units, so it needs the real quad aspect or
	# the corners stop being circular.
	mat.set_shader_parameter("aspect", size.x / size.y)
	for k in params:
		mat.set_shader_parameter(k, params[k])
	var mesh := QuadMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = local_pos
	parent.add_child(mi)
	return mi


## ⚠️ AS-0001 gives BASELINES, but a Label is positioned by its top-left, so each
## one is offset up by the font ascent. Placing the label top at the baseline
## drops the text a whole ascent too low.
static func baseline_label(vp: SubViewport, font: Font, text: String, size_px: int,
		color: Color, x: float, baseline_y: float) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size_px)
	l.add_theme_color_override("font_color", color)
	l.position = Vector2(x, baseline_y - font.get_ascent(size_px))
	l.text = text
	vp.add_child(l)
	return l


## A texture surface for glass content. `once` renders one frame and then
## stops — right for anything that only changes when its text does, which on a
## Quest is the difference between four idle viewports and four hot ones.
static func content_viewport(parent: Node, size: Vector2i, once: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = true          # the glass IS the plate
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE if once else SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	return vp


## One session card: title + state word on variant-C glass. Returns
## {"mesh": MeshInstance3D, "viewport": SubViewport}.
## `aim` = true turns the card to face the parent's origin (the old free-floating
## rail); false places it flat at `pos` in the parent's space (attached rail).
static func card(parent: Node, font: Font, pos: Vector3, size: Vector2, title: String,
		state: String, attention: float, aim: bool = true) -> Dictionary:
	var h_px := float(CARD_H_PX)
	var vp := content_viewport(parent, Vector2i(int(round(h_px * size.x / size.y)), int(h_px)), true)
	var inset := TEXT_INSET_H * h_px
	var primary_px := 39          # ~22.3 dmm at this card's angular height
	var secondary_px := 34
	baseline_label(vp, font, title, primary_px, TEXT_PRIMARY,
			inset, h_px * 0.5 + BASELINE_PRIMARY_H * h_px)
	if state != "":
		# ⚠️ Deliberately NOT state-tinted. Five colours to decode is worse than a
		# word you can read, and the strong edge treatment is reserved for the one
		# state that actually wants you.
		baseline_label(vp, font, state, secondary_px, TEXT_SECONDARY,
				inset, h_px * 0.5 + BASELINE_SECONDARY_H * h_px)
	var group: Node3D
	if aim:
		group = oriented_group(parent, pos)
	else:
		group = Node3D.new()
		group.position = pos
		parent.add_child(group)
	var params := CARD_TOKENS.duplicate()
	params["attention"] = attention
	params["body_color"] = body
	params["content"] = vp.get_texture()
	var mesh := glass(group, size, Vector3.ZERO, params)
	return {"mesh": mesh, "viewport": vp, "group": group}


## Which sessions go in which rail slot.
##
## ⛔ Slot 0 is reserved for whoever needs you (the host's focus pick), and
## nothing moves or grows — the signal is the edge, not the position. Four
## slots, then the last one becomes "+N more" rather than a sliver deck; the
## number was always the useful part.
##
## Returns a list of slot dictionaries: {"key", "state", "attention"} or
## {"overflow": n}. `sessions` must already be in the host's stable order.
static func rail_slots(sessions: Array, current: String, focus_key: String) -> Array:
	var rest: Array = []
	for s in sessions:
		if typeof(s) != TYPE_DICTIONARY:
			continue
		var k := str(s.get("key", ""))
		if k == "" or k == current or str(s.get("state", "")) == "gone":
			continue
		rest.append(s)
	var waiting: Dictionary = {}
	for s in rest:
		if str(s.get("key", "")) == focus_key:
			waiting = s
			break
	if not waiting.is_empty():
		rest.erase(waiting)

	var slots: Array = []
	if not waiting.is_empty():
		slots.append(_slot(waiting, 1.0))
	for s in rest:
		if slots.size() >= RAIL_ELEV_DEG.size():
			break
		slots.append(_slot(s, 1.0 if str(s.get("state", "")) in WAITING_STATES else 0.0))

	var shown_rest := slots.size() - (0 if waiting.is_empty() else 1)
	var leftover := rest.size() - shown_rest
	if leftover > 0:
		# The last slot becomes the overflow affordance rather than a session.
		slots[RAIL_ELEV_DEG.size() - 1] = {"overflow": leftover + 1}
	return slots


static func _slot(s: Dictionary, attention: float) -> Dictionary:
	return {"key": str(s.get("key", "?")), "state": str(s.get("state", "idle")),
			"attention": attention}


## Edge gain for a waiting card at time t: a slow breath, never dark.
static func pulse_gain(t: float) -> float:
	var s := 0.5 + 0.5 * sin(TAU * PULSE_HZ * t)
	return lerp(PULSE_GAIN_LO, PULSE_GAIN_HI, s)

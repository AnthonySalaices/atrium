shader_type spatial;
// ⛔ `unshaded` matters: the previous version added the rim to BOTH albedo and
// emission while still being lit, counting the same light twice. Astra caught it
// in AS-0001 — copying its numbers into the old shader would not have reproduced
// its render.
render_mode blend_mix, cull_disabled, shadows_disabled, unshaded;

// Glass card — implements variant "C / Smoke" from the AS-0001 look-dev study.
// See inbox/AS-0001/NOTES.md for the derivation and the reference renders.
//
// ⭐ **The finding that drives every number here:** without backdrop blur (and
// Forward Mobile, which the Quest uses, cannot do screen-reading shaders) you
// cannot have both conspicuous transparency and dependable text contrast over
// arbitrary bright clutter. So the text wins. At body alpha 0.88 the secondary
// text holds 4.77:1 over a white background; at 0.42 it was 1.43:1, which is
// unreadable the moment a bright window sits behind the card.
//
// ⚠️ Everything is in units of CARD HEIGHT, not normalised UV, so the corner
// radius stays circular on any aspect and one set of numbers covers every card.
// ⚠️ The focus panel is 1.26 m tall and needs its own tokens (radius .025h,
// bezel .0045h, falloff .008h) — the session card's .100h radius would carve
// away usable terminal grid.

uniform float aspect = 2.741;                 // width / height of the quad
uniform float radius_h = 0.100;
uniform float bezel_h = 0.018;                // ~2.5 px of support at 25 PPD
uniform float falloff_h = 0.032;              // inner e-fold distance

uniform vec4 body_color : source_color = vec4(0.0627, 0.0980, 0.1333, 1.0);   // #101922
uniform float body_alpha : hint_range(0.0, 1.0) = 0.88;                       // floor ~.87, ceiling ~.94
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.96;

uniform vec4 edge_rest : source_color = vec4(0.7294, 0.7961, 0.8627, 1.0);    // #BACBDC
uniform vec4 edge_attention : source_color = vec4(1.0, 0.7216, 0.2902, 1.0);  // #FFB84A
uniform float gain_rest = 0.38;
uniform float gain_attention = 1.10;
uniform float inner_gain = 0.022;

// ⚠️ A 2.5 px amber rim alone was "super subtle, I doubt anyone would notice"
// (9/17). A card that needs you also grows its rim and floods amber inward
// from the edge; the text still composites on top, untouched.
uniform float attention_bezel_scale = 2.4;
uniform float attention_falloff_scale = 4.0;
uniform float attention_inner_gain = 0.34;

// ⚠️ A mild bias only. The strongly directional variant (1.60/0.40) was rejected
// because the bottom edge disappears. If it shimmers on hardware, make it
// uniform BEFORE making it brighter.
uniform float top_bias = 1.15;
uniform float bottom_bias = 0.85;

// 0 = at rest, 1 = needs you. Only the EDGE changes: same geometry, same body,
// same content. Attention is the material brightening, never a border on top.
uniform float attention : hint_range(0.0, 1.0) = 0.0;

uniform sampler2D content : source_color, filter_linear_mipmap, hint_default_transparent;

float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 half_size = vec2(aspect, 1.0) * 0.5;
	vec2 p = (UV - vec2(0.5)) * vec2(aspect, 1.0);
	float d = rounded_box(p, half_size, radius_h);

	// Derivative antialiasing: one screen pixel expressed in card units, so the
	// silhouette stays clean at any distance without a magic constant.
	float aa = max(fwidth(d), 0.00001);
	float coverage = 1.0 - smoothstep(-aa * 0.5, aa * 0.5, d);
	if (coverage <= 0.001) {
		discard;
	}

	float u = max(-d, 0.0);                        // depth inward from the silhouette
	float bz = bezel_h * mix(1.0, attention_bezel_scale, attention);
	float fo = falloff_h * mix(1.0, attention_falloff_scale, attention);
	float rim = 1.0 - smoothstep(0.0, bz, u);
	float inner = exp(-u / fo) * (1.0 - rim);
	float bias = mix(top_bias, bottom_bias, UV.y); // UV.y is down in Godot

	vec3 edge = mix(edge_rest.rgb, edge_attention.rgb, attention);
	float gain = mix(gain_rest, gain_attention, attention);

	float ig = mix(inner_gain, attention_inner_gain * gain, attention);
	vec3 rgb = body_color.rgb + edge * (rim * gain * bias + inner * ig);
	float a = mix(body_alpha, edge_alpha, rim);

	// ⛔ Text composites LAST, at its own coverage, with opaque glyph interiors.
	// Never multiply the text by the glass alpha, never tint it with the edge
	// colour, and never add the rim after this point.
	// ⚠️ content is PREMULTIPLIED (GlassUI.bake_content): mipmaps of straight
	// alpha average white glyphs with the transparent black around them, and
	// text seen from 1.5 m came out dark grey (9/18).
	vec4 c = texture(content, UV);
	rgb = rgb * (1.0 - c.a) + c.rgb;
	a = mix(a, 1.0, c.a);

	ALBEDO = rgb;
	ALPHA = clamp(a, 0.0, 1.0) * coverage;
}

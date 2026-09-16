shader_type spatial;
render_mode blend_mix, cull_disabled, shadows_disabled, depth_draw_opaque;

// Glass card: a rounded, bezelled, translucent plate with its content composited
// on top and an edge that carries the attention signal.
//
// ⭐ Everything here is a SHADER, not geometry: the rounded corners, the bezel
// and the glow are computed from a rounded-rectangle distance field, so there is
// no mesh to author, no UV seams, and the corner radius is a number you can tune
// live from the Lua config rather than a modelling decision.
//
// ⚠️ **No backdrop blur.** Godot's Forward Mobile renderer — the one the Quest
// uses — does not support screen-reading shaders, so a true frosted blur of what
// is behind the card is not available on device. What sells glass here instead
// is the combination that survives without it: genuine transparency, a bright
// specular bezel that catches the environment's colour, a soft inner falloff,
// and a faint procedural frost. Verify on hardware before trusting it.

uniform vec2 size_px = vec2(320.0, 120.0);
uniform float corner_radius_px = 22.0;
uniform float bezel_px = 3.0;

uniform vec4 glass_tint : source_color = vec4(0.06, 0.08, 0.12, 1.0);
uniform float glass_opacity : hint_range(0.0, 1.0) = 0.38;
uniform float frost : hint_range(0.0, 1.0) = 0.10;

uniform vec4 edge_color : source_color = vec4(0.62, 0.70, 0.82, 1.0);
uniform float edge_strength : hint_range(0.0, 4.0) = 1.0;

// The attention signal, driven from code: 0 = at rest, 1 = asking for you.
// ⭐ It is the EDGE that brightens, never a border drawn on top — glow belongs to
// the material, which is what keeps it in the same visual language as the glass.
uniform float glow : hint_range(0.0, 1.0) = 0.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.72, 0.29, 1.0);

uniform sampler2D content : source_color, filter_linear_mipmap, hint_default_transparent;
uniform float content_opacity : hint_range(0.0, 1.0) = 1.0;

// Signed distance to a rounded rectangle: negative inside, zero on the edge.
float rounded_box(vec2 p, vec2 half_size, float r) {
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 p = (UV - vec2(0.5)) * size_px;
	float d = rounded_box(p, size_px * 0.5, corner_radius_px);

	// One pixel of the card, in card space — keeps the antialiasing crisp at any
	// size instead of guessing a constant.
	float px = fwidth(d) + 0.0001;
	float inside = 1.0 - smoothstep(-px, px, d);
	if (inside <= 0.001) {
		discard;
	}

	// The bezel is a band just inside the edge. It brightens, so the card reads
	// as having a lit rim rather than a painted outline.
	float bezel = 1.0 - smoothstep(0.0, bezel_px, abs(d) + bezel_px * 0.35);
	// A wider, softer falloff inside the rim: the thickness cue that makes a flat
	// quad read as a slab of material.
	float inner = 1.0 - smoothstep(0.0, bezel_px * 8.0, abs(d));

	vec3 base = glass_tint.rgb;
	float alpha = glass_opacity;

	// Frost: fine static grain, so the surface is not a perfectly flat wash.
	float grain = hash(floor(p * 0.5)) - 0.5;
	base += grain * frost * 0.35;
	alpha += grain * frost * 0.10;

	base += edge_color.rgb * inner * 0.06;
	alpha += inner * 0.05;

	// Content sits ON the glass, at full opacity where it is opaque, so text is
	// never washed out by the plate it rests on.
	vec4 c = texture(content, UV);
	c.a *= content_opacity;
	base = mix(base, c.rgb, c.a);
	alpha = mix(alpha, 1.0, c.a);

	// Rim: the neutral specular edge, plus the attention colour when glowing.
	vec3 rim = mix(edge_color.rgb, glow_color.rgb, glow);
	float rim_power = edge_strength * (0.55 + 1.45 * glow);
	base += rim * bezel * rim_power;
	alpha = max(alpha, bezel * (0.35 + 0.65 * glow));

	ALBEDO = base;
	ALPHA = clamp(alpha, 0.0, 1.0) * inside;
	// Unshaded-but-emissive: the card lights itself, so it reads the same whether
	// it hangs in a dark nebula or over a bright passthrough desk.
	EMISSION = rim * bezel * rim_power * 0.8 + c.rgb * c.a * 0.25;
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

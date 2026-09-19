// A hole in the eye buffer: wherever this quad draws, the frame's alpha goes to
// zero and the compositor shows passthrough (the real desk and keyboard).
// ⭐ blend_mul makes the result src * dst for colour AND alpha, so a mask of 0
// clears the pixel and 1 leaves it alone; the rounded, feathered edge is the
// mask ramping 0 -> 1. Needs environment_blend_mode = ALPHA_BLEND (backdrop.gd).
shader_type spatial;
render_mode unshaded, blend_mul, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled, fog_disabled;

uniform vec2 size_m = vec2(1.2, 0.6);
uniform float radius_m = 0.06;
uniform float feather_m = 0.03;

void fragment() {
	vec2 p = (UV - 0.5) * size_m;
	vec2 q = abs(p) - (size_m * 0.5 - vec2(radius_m));
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius_m;   // < 0 inside
	float m = smoothstep(-feather_m, 0.0, d);                              // 0 inside, 1 outside
	ALBEDO = vec3(m);
	ALPHA = m;
}

shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled, fog_disabled, depth_draw_never;

// The night sky on a big inside-out sphere around the head. The sky itself
// (nebula_sky) draws where nothing else does — which, with the keyboard view's
// alpha-blended frame, is exactly where passthrough leaked through. A sphere
// writes opaque alpha like any mesh.

#include "res://shaders/nebula_common.gdshaderinc"

varying vec3 v_dir;

void vertex() {
	v_dir = (MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz;
}

void fragment() {
	ALBEDO = nebula_color(normalize(v_dir), TIME);
}

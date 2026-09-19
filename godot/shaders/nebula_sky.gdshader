shader_type sky;
render_mode use_debanding;

// Somewhere that is not a place.
//
// Procedural rather than a photographed HDRI, for three reasons: it MOVES
// (a static cubemap cannot drift), it weighs nothing next to a 122 MB skybox,
// and every parameter can be driven live from config.lua.

#include "res://shaders/nebula_common.gdshaderinc"

void sky() {
	COLOR = nebula_color(normalize(EYEDIR), TIME);
}

shader_type sky;
render_mode use_debanding;

// Somewhere that is not a place.
//
// Procedural rather than a photographed HDRI, for three reasons: it MOVES
// (a static cubemap cannot drift), it weighs nothing next to a 122 MB skybox,
// and every parameter can be driven live from config.lua.

uniform vec3 base_top     : source_color = vec3(0.016, 0.020, 0.055);
uniform vec3 base_bottom  : source_color = vec3(0.004, 0.005, 0.012);
uniform vec3 nebula_a     : source_color = vec3(0.196, 0.098, 0.451);
uniform vec3 nebula_b     : source_color = vec3(0.039, 0.239, 0.361);
uniform vec3 nebula_c     : source_color = vec3(0.510, 0.161, 0.290);

uniform float nebula_strength = 0.55;
uniform float nebula_scale    = 1.8;
uniform float drift_speed     = 0.012;   // very slow: motion you notice only if you look
uniform float star_density    = 0.72;
uniform float star_brightness = 1.0;
uniform float twinkle_speed   = 0.35;
uniform float horizon_glow    = 0.25;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);          // smoothstep, cheaper than a cubic
	float n000 = hash13(i + vec3(0,0,0));
	float n100 = hash13(i + vec3(1,0,0));
	float n010 = hash13(i + vec3(0,1,0));
	float n110 = hash13(i + vec3(1,1,0));
	float n001 = hash13(i + vec3(0,0,1));
	float n101 = hash13(i + vec3(1,0,1));
	float n011 = hash13(i + vec3(0,1,1));
	float n111 = hash13(i + vec3(1,1,1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			   mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// 4 octaves is the most a Quest should pay for a background it renders every frame.
float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

// Sparse stars: one candidate per cell, so density is cheap to control.
float stars(vec3 dir, float t) {
	vec3 p = dir * 220.0;
	vec3 i = floor(p);
	float h = hash13(i);
	if (h < 1.0 - star_density * 0.06) {
		return 0.0;
	}
	vec3 c = i + vec3(hash13(i + 11.0), hash13(i + 23.0), hash13(i + 37.0));
	float d = length(p - c);
	float core = smoothstep(0.55, 0.0, d);
	float tw = 0.65 + 0.35 * sin(t * twinkle_speed * 6.2831 * (0.4 + h) + h * 40.0);
	return core * tw * (0.35 + 0.65 * h);
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	float up = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);

	vec3 col = mix(base_bottom, base_top, pow(up, 0.75));

	// Two layers drifting at different rates gives real parallax depth without
	// any geometry — the thing a static skybox cannot do.
	float t = TIME * drift_speed;
	vec3 q = dir * nebula_scale;
	float n1 = fbm(q + vec3(t, t * 0.6, -t * 0.4));
	float n2 = fbm(q * 2.1 + vec3(-t * 0.7, t * 0.3, t * 0.9) + n1);

	float clouds = pow(clamp(n1 * 1.25 - 0.18, 0.0, 1.0), 1.6);
	float wisps  = pow(clamp(n2 * 1.15 - 0.30, 0.0, 1.0), 2.2);

	vec3 neb = mix(nebula_a, nebula_b, clamp(n2, 0.0, 1.0));
	neb = mix(neb, nebula_c, clamp(wisps * 1.4, 0.0, 1.0));

	col += neb * clouds * nebula_strength;
	col += nebula_c * wisps * nebula_strength * 0.45;

	// Stars sit behind the nebula, so dense regions occlude them.
	float s = stars(dir, TIME) * star_brightness * (1.0 - clamp(clouds * 1.3, 0.0, 1.0));
	col += vec3(s) * vec3(0.92, 0.95, 1.0);

	// A faint band below eye level so the panels have something to sit against
	// instead of dissolving into black.
	float band = exp(-pow(abs(dir.y + 0.12) * 4.2, 2.0));
	col += nebula_b * band * horizon_glow;

	COLOR = col;
}

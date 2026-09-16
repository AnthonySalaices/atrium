extends AudioStreamPlayer
class_name Ambience

## Procedural ambient drone.
##
## Synthesised, not sampled. Three reasons, all of which came out of actually
## looking for assets: the good CC0 drones on Freesound are login-gated, the
## best-sounding ones turned out to be CC-BY (wrong for something we ship free),
## and a sampled loop always eventually reveals its seam. This never repeats,
## weighs nothing, and can react to state later — the glow could warm the pad
## when an agent needs you.

const RATE := 22050.0          # plenty for a low drone; a quarter of the CPU of 44.1k

@export var master := 0.10     # quieter again after the first listen
@export var enabled := true

var _gen := AudioStreamGenerator.new()
var _pb: AudioStreamGeneratorPlayback
var _t := 0.0

# A stack of slightly detuned partials. The irrational ratios mean the combined
# waveform never lines up again, so there is no perceptible loop point.
const PARTIALS := [
	# ⚠️ Warmer, higher, major. The first version stacked bare fifths on a 55 Hz
	# root, which reads as "ominous sci-fi" — first listener's reaction: "a little
	# ominous. i dont think i like it." Low rumble is most of that feeling, so
	# the root moved up an octave and the intervals are now a C major pad.
	{"f": 130.81, "a": 0.42, "lfo": 0.017, "depth": 0.30},   # C3
	{"f": 196.00, "a": 0.26, "lfo": 0.023, "depth": 0.35},   # G3
	{"f": 261.63, "a": 0.20, "lfo": 0.011, "depth": 0.25},   # C4
	{"f": 329.63, "a": 0.13, "lfo": 0.029, "depth": 0.45},   # E4
	{"f": 392.00, "a": 0.08, "lfo": 0.037, "depth": 0.50},   # G4
	{"f": 523.25, "a": 0.05, "lfo": 0.041, "depth": 0.55},   # C5
]

var _phase := PackedFloat32Array()
var _noise_lp := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260915
	_phase.resize(PARTIALS.size())
	for i in range(PARTIALS.size()):
		_phase[i] = _rng.randf() * TAU
	_gen.mix_rate = RATE
	_gen.buffer_length = 0.25
	stream = _gen
	bus = "Master"
	if enabled:
		play()
		_pb = get_stream_playback()


func set_enabled(on: bool) -> void:
	enabled = on
	if on and not playing:
		play()
		_pb = get_stream_playback()
	elif not on and playing:
		stop()


func _process(_delta: float) -> void:
	if _pb == null or not enabled:
		return
	var frames := _pb.get_frames_available()
	if frames <= 0:
		return
	var inc := 1.0 / RATE
	for _i in range(frames):
		_t += inc
		var l := 0.0
		var r := 0.0
		for p in range(PARTIALS.size()):
			var d: Dictionary = PARTIALS[p]
			# Slow detune so the pad breathes instead of sitting still.
			var wob: float = 1.0 + sin(_t * TAU * float(d["lfo"])) * float(d["depth"]) * 0.004
			_phase[p] += TAU * float(d["f"]) * wob * inc
			if _phase[p] > TAU:
				_phase[p] -= TAU
			var s: float = sin(_phase[p]) * float(d["a"])
			# Tiny per-partial stereo spread: width without any reverb cost.
			var pan: float = 0.5 + 0.5 * sin(_t * TAU * float(d["lfo"]) * 0.37 + float(p))
			l += s * (1.0 - pan * 0.35)
			r += s * (1.0 - (1.0 - pan) * 0.35)

		# A whisper of filtered noise stops it sounding like a test tone.
		var n := _rng.randf_range(-1.0, 1.0)
		_noise_lp += (n - _noise_lp) * 0.0018
		l += _noise_lp * 0.30
		r += _noise_lp * 0.30

		var amp := master * 0.5
		_pb.push_frame(Vector2(clampf(l * amp, -1.0, 1.0), clampf(r * amp, -1.0, 1.0)))

extends AudioStreamPlayer
class_name Ambience

## The room's sound — a coffee shop, synthesised.
##
## Three independent layers, each switchable in `config/default.lua`:
##   * **typing** — a soft key click for every keystroke you send to a pane
##   * **steam**  — a distant steam wand, a few seconds, every minute or three
##   * **music**  — a slow chord pad (procedural) or your own folder of files
##
## ⛔ **No audio assets ship with the app.** Every layer here is generated. Three
## reasons, all of which came out of actually going looking: the good CC0 loops
## on Freesound are login-gated, the best-sounding ones are CC-BY (wrong for
## something we ship free), and a sampled loop eventually reveals its seam.
##
## ⚠️ The first drone stacked bare fifths on a 55 Hz root and read as *"a scary
## hum"* — low rumble is most of that feeling. The pad now sits an octave up as
## a C major chord, and `ambience.enabled` defaults to **false** regardless:
## silence is the right default for something you wear on your face.

const RATE := 22050.0          # plenty for room tone; a quarter of the CPU of 44.1k
const MAX_CLICKS := 8          # a fast typist outruns the ear long before this

@export var master := 0.10     # ambience.volume — the whole room
@export var enabled := false

# ── layers (set from config; see set_config) ────────────────────────────────
var typing_enabled := true
var typing_volume := 0.35
var steam_enabled := true
var steam_volume := 0.50
var steam_every := Vector2(60.0, 180.0)    # seconds between hisses
var steam_length := Vector2(2.0, 4.0)      # seconds per hiss
var music_mode := "procedural"             # "procedural" | "folder" | "off"
var music_volume := 0.50
var music_dir := ""

# A stack of slightly detuned partials. The irrational ratios mean the combined
# waveform never lines up again, so the pad has no perceptible loop point.
const PARTIALS := [
	{"f": 130.81, "a": 0.42, "lfo": 0.017, "depth": 0.30},   # C3
	{"f": 196.00, "a": 0.26, "lfo": 0.023, "depth": 0.35},   # G3
	{"f": 261.63, "a": 0.20, "lfo": 0.011, "depth": 0.25},   # C4
	{"f": 329.63, "a": 0.13, "lfo": 0.029, "depth": 0.45},   # E4
	{"f": 392.00, "a": 0.08, "lfo": 0.037, "depth": 0.50},   # G4
	{"f": 523.25, "a": 0.05, "lfo": 0.041, "depth": 0.55},   # C5
]

var _gen := AudioStreamGenerator.new()
var _pb: AudioStreamGeneratorPlayback
var _t := 0.0
var _phase := PackedFloat32Array()
var _noise_lp := 0.0
var _rng := RandomNumberGenerator.new()

# Key clicks in flight: {t, dur, f, amp, lp, ph}.
var _clicks: Array = []

# The steam wand. _steam_t < 0 means "waiting"; _steam_wait counts that down.
var _steam_t := -1.0
var _steam_wait := 30.0
var _steam_len := 3.0
var _steam_lp := 0.0
var _steam_lp2 := 0.0

# Folder music plays through a real decoder, not the generator.
var _music: AudioStreamPlayer
var _playlist: PackedStringArray = PackedStringArray()
var _track := 0
var _fails := 0                # consecutive unloadable files; stops a bad folder looping


func _ready() -> void:
	_rng.randomize()
	_phase.resize(PARTIALS.size())
	for i in range(PARTIALS.size()):
		_phase[i] = _rng.randf() * TAU
	_gen.mix_rate = RATE
	_gen.buffer_length = 0.25
	stream = _gen
	bus = "Master"
	_music = AudioStreamPlayer.new()
	_music.bus = "Master"
	_music.finished.connect(_next_track)
	add_child(_music)
	_steam_wait = _rng.randf_range(steam_every.x, steam_every.y)
	if enabled:
		_start()


## Apply the `ambience` block of the live config. Safe to call on every reload —
## only the folder playlist is rebuilt, and only when the folder changed.
func set_config(amb: Dictionary) -> void:
	master = clampf(float(amb.get("volume", master)), 0.0, 1.0)

	var typing: Dictionary = amb.get("typing", {})
	typing_enabled = bool(typing.get("enabled", typing_enabled))
	typing_volume = clampf(float(typing.get("volume", typing_volume)), 0.0, 1.0)

	var steam: Dictionary = amb.get("steam", {})
	steam_enabled = bool(steam.get("enabled", steam_enabled))
	steam_volume = clampf(float(steam.get("volume", steam_volume)), 0.0, 1.0)
	steam_every = Vector2(float(steam.get("every_min_s", steam_every.x)),
			float(steam.get("every_max_s", steam_every.y)))
	steam_length = Vector2(float(steam.get("length_min_s", steam_length.x)),
			float(steam.get("length_max_s", steam_length.y)))

	var music: Dictionary = amb.get("music", {})
	var dir := str(music.get("dir", music_dir))
	var mode := str(music.get("mode", music_mode))
	music_volume = clampf(float(music.get("volume", music_volume)), 0.0, 1.0)
	var folder_changed := dir != music_dir or mode != music_mode
	music_dir = dir
	music_mode = mode

	# A shorter interval must not wait out the old one: if the next hiss was
	# scheduled minutes away and the user just asked for one a minute, pull it in.
	_steam_wait = minf(_steam_wait, maxf(steam_every.x, steam_every.y))

	set_enabled(bool(amb.get("enabled", enabled)))
	if folder_changed:
		_reload_music()


func set_enabled(on: bool) -> void:
	enabled = on
	if on:
		_start()
	else:
		if playing:
			stop()
		if _music and _music.playing:
			_music.stop()
		_clicks.clear()


func _start() -> void:
	if not playing:
		play()
	if _pb == null and playing:
		_pb = get_stream_playback()
	_reload_music()


## ⭐ One click per keystroke, called from the key path in terminal.gd. Randomised
## pitch and length: identical clicks are what makes a fake keyboard sound fake.
func click() -> void:
	# Queued even before the audio server hands over a playback: the mixer
	# simply ignores the queue until it has somewhere to push frames.
	if not enabled or not typing_enabled:
		return
	if _clicks.size() >= MAX_CLICKS:
		_clicks.pop_front()
	_clicks.append({
		"t": 0.0,
		"dur": _rng.randf_range(0.020, 0.038),
		"f": _rng.randf_range(1500.0, 2700.0),
		"amp": _rng.randf_range(0.7, 1.0),
		"lp": 0.0,
		"ph": _rng.randf() * TAU,
	})


# ── music from a folder ─────────────────────────────────────────────────────

## ⚠️ `music.dir` is a path on the DEVICE running this client — the headset —
## not on the host that evaluates the config. `/sdcard/Music` on a Quest.
func _reload_music() -> void:
	if _music == null:
		return
	if not enabled or music_mode != "folder" or music_dir == "":
		if _music.playing:
			_music.stop()
		_playlist = PackedStringArray()
		return
	var files := PackedStringArray()
	for f in DirAccess.get_files_at(music_dir):
		var low := f.to_lower()
		if low.ends_with(".ogg") or low.ends_with(".mp3"):
			files.append(music_dir.path_join(f))
	if files.is_empty():
		print("[amb] no .ogg/.mp3 in %s — music off" % music_dir)
		_playlist = PackedStringArray()
		return
	var shuffled := Array(files)
	shuffled.shuffle()
	_playlist = PackedStringArray(shuffled)
	_track = 0
	_fails = 0
	_play_track()


func _play_track() -> void:
	if _playlist.is_empty():
		return
	var path := _playlist[_track % _playlist.size()]
	var s := _load_track(path)
	if s == null:
		# ⚠️ Without the counter, a folder of files Godot cannot decode sends
		# _play_track and _next_track round each other until the stack gives out.
		print("[amb] could not load %s" % path)
		_fails += 1
		if _fails >= _playlist.size():
			print("[amb] nothing in %s could be decoded — music off" % music_dir)
			_playlist = PackedStringArray()
			return
		_next_track()
		return
	_fails = 0
	_music.stream = s
	_music.volume_db = linear_to_db(maxf(master * music_volume, 0.0001))
	_music.play()


func _next_track() -> void:
	if _playlist.is_empty() or not enabled or music_mode != "folder":
		return
	_track += 1
	if _track >= _playlist.size():          # one shuffle per pass through
		var again := Array(_playlist)
		again.shuffle()
		_playlist = PackedStringArray(again)
		_track = 0
	_play_track()


func _load_track(path: String) -> AudioStream:
	var low := path.to_lower()
	if low.ends_with(".ogg"):
		return AudioStreamOggVorbis.load_from_file(path)
	if low.ends_with(".mp3"):
		return AudioStreamMP3.load_from_file(path)
	return null


# ── the mixer ───────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if _pb == null or not enabled:
		return
	var frames := _pb.get_frames_available()
	if frames <= 0:
		return
	var inc := 1.0 / RATE
	var pad_on := music_mode == "procedural"
	var pad_amp := master * music_volume
	var click_amp := master * typing_volume
	var steam_amp := master * steam_volume * 0.5

	for _i in range(frames):
		_t += inc
		var l := 0.0
		var r := 0.0

		if pad_on:
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
				l += s * (1.0 - pan * 0.35) * pad_amp
				r += s * (1.0 - (1.0 - pan) * 0.35) * pad_amp

			# A whisper of filtered noise stops the pad sounding like a test tone.
			var n := _rng.randf_range(-1.0, 1.0)
			_noise_lp += (n - _noise_lp) * 0.0018
			l += _noise_lp * 0.30 * pad_amp
			r += _noise_lp * 0.30 * pad_amp

		if steam_enabled:
			var hiss := _steam_sample(inc)
			# Off to one side and a little behind the ear: it is across the room.
			l += hiss * steam_amp * 0.75
			r += hiss * steam_amp * 1.00

		if not _clicks.is_empty():
			var c := _click_sample(inc) * click_amp
			l += c
			r += c

		# ⚠️ No extra trim here: `master` is already folded into every layer's
		# amplitude above. The old single-layer version scaled by master*0.5 at
		# this point, and keeping both halved the whole room.
		_pb.push_frame(Vector2(clampf(l, -1.0, 1.0), clampf(r, -1.0, 1.0)))

	# Retiring voices once per buffer, not once per sample.
	if not _clicks.is_empty():
		var live: Array = []
		for c in _clicks:
			if float(c["t"]) < float(c["dur"]):
				live.append(c)
		_clicks = live


## A key click: a burst of noise with a little pitch in it, decaying fast. The
## pitched part alone reads as a beep; the noise alone reads as static.
func _click_sample(inc: float) -> float:
	var out := 0.0
	for c in _clicks:
		var t: float = c["t"]
		if t >= float(c["dur"]):
			continue
		var env: float = exp(-t / (float(c["dur"]) * 0.32))
		var n := _rng.randf_range(-1.0, 1.0)
		c["lp"] = lerp(float(c["lp"]), n, 0.45)
		c["ph"] = float(c["ph"]) + TAU * float(c["f"]) * inc
		out += (float(c["lp"]) * 0.75 + sin(float(c["ph"])) * 0.25) * env * float(c["amp"])
		c["t"] = t + inc
	return out


## The steam wand: filtered noise with a slow swell and a longer tail, so it
## reads as a barista across the room rather than a hiss in your ear.
func _steam_sample(inc: float) -> float:
	if _steam_t < 0.0:
		_steam_wait -= inc
		if _steam_wait > 0.0:
			return 0.0
		_steam_t = 0.0
		_steam_len = _rng.randf_range(minf(steam_length.x, steam_length.y),
				maxf(steam_length.x, steam_length.y))

	var n := _rng.randf_range(-1.0, 1.0)
	# Two poles down, one pole of that back out: a broad band, no resonance.
	_steam_lp += (n - _steam_lp) * 0.35
	_steam_lp2 += (_steam_lp - _steam_lp2) * 0.10
	var band := _steam_lp - _steam_lp2

	var attack := clampf(_steam_t / 0.45, 0.0, 1.0)
	var release := clampf((_steam_len - _steam_t) / 0.9, 0.0, 1.0)
	var env := attack * release
	_steam_t += inc
	if _steam_t >= _steam_len:
		_steam_t = -1.0
		_steam_wait = _rng.randf_range(minf(steam_every.x, steam_every.y),
				maxf(steam_every.x, steam_every.y))
	return band * env

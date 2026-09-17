extends Node3D
class_name Pairing

## First-run pairing card. Shown when the app has no host + token stored, or on
## ctrl+alt+P. The APK ships with no secret; this is how it gets one.
##
##   1. broadcast a discovery ping; hosts running glassd answer with their name
##   2. the user picks one (or types an address), types the 6-digit code that
##      `glasshouse pair` printed on the host
##   3. POST /pair {code} -> {token}; stored in user://glasshouse.cfg
##
## Keyboard-only on purpose: the physical keyboard is the input device of this
## whole app, and a pairing card that needs hands is a card that fails on the
## desk. Tab / arrows move between fields, Enter submits, Escape cancels.

signal paired(host: String, port: int, token: String)
signal cancelled

const CFG_PATH := "user://glasshouse.cfg"
const DISCOVER_PORT := 7570

var font: Font
var host := ""
var code := ""
var field := 0                    # 0 = host, 1 = code
var status := ""
var hosts: Array = []             # [{name, host, port}]
var port := 7570

var _vp: SubViewport
var _labels: Array = []
var _udp := PacketPeerUDP.new()
var _http: HTTPRequest
var _busy := false
var _t := 0.0


static func load_saved() -> Dictionary:
	var cf := ConfigFile.new()
	if cf.load(CFG_PATH) != OK:
		return {}
	var h := str(cf.get_value("link", "host", ""))
	var t := str(cf.get_value("link", "token", ""))
	if h == "" or t == "":
		return {}
	return {"host": h, "port": int(cf.get_value("link", "port", 7570)), "token": t}


static func save(p_host: String, p_port: int, p_token: String) -> void:
	var cf := ConfigFile.new()
	cf.set_value("link", "host", p_host)
	cf.set_value("link", "port", p_port)
	cf.set_value("link", "token", p_token)
	cf.save(CFG_PATH)


static func forget() -> void:
	DirAccess.remove_absolute(CFG_PATH)


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 8.0
	add_child(_http)
	_http.request_completed.connect(_on_http)
	_build_card()
	_start_discovery()
	_render()


func _build_card() -> void:
	# A wide card straight ahead, a touch below eye level, where the focus
	# window normally sits — this IS the focus while pairing.
	var size := GlassUI.angular_size(40.0, 18.0, 1.5)
	var h_px := 480.0
	_vp = GlassUI.content_viewport(self, Vector2i(int(round(h_px * size.x / size.y)), int(h_px)), true)
	var group := GlassUI.oriented_group(self, GlassUI.polar(0.0, -8.0, 1.5))
	var params := {"radius_h": 0.06, "bezel_h": 0.008, "falloff_h": 0.02,
			"attention": 0.0, "content": _vp.get_texture()}
	GlassUI.glass(group, size, Vector3.ZERO, params)
	var x := 0.06 * h_px
	var rows := [66, 60, 44, 44, 44, 44, 44]        # px sizes per line
	var y := 0.16 * h_px
	for i in range(7):
		var l := GlassUI.baseline_label(_vp, font, "", rows[i],
				GlassUI.TEXT_PRIMARY if i < 2 else GlassUI.TEXT_SECONDARY, x, y)
		_labels.append(l)
		y += rows[i] * 1.35


func _render() -> void:
	var lines := [
		"Glasshouse",
		"Run  glasshouse pair  on your computer, then enter the code.",
		"",
		"Host   %s%s" % [host, "▏" if field == 0 else ""],
		"Code   %s%s" % [code, "▏" if field == 1 else ""],
		"",
		status,
	]
	if hosts.size() > 0 and field == 0:
		var names := []
		for h in hosts:
			names.append("%s (%s)" % [h["name"], h["host"]])
		lines[2] = "Found: " + ", ".join(names) + "   — Tab to accept the first"
	elif hosts.is_empty():
		lines[2] = "Looking for hosts on this network…"
	for i in range(_labels.size()):
		_labels[i].text = str(lines[i])
		_labels[i].modulate = GlassUI.AMBER if (i == 6 and status.begins_with("!")) else Color.WHITE
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


## Broadcast on the LAN; every glassd answers with its name and port.
func _start_discovery() -> void:
	_udp.set_broadcast_enabled(true)
	var err := _udp.bind(0)
	if err != OK:
		print("[pair] udp bind failed: %d" % err)
		return
	_ping()


func _ping() -> void:
	_udp.set_dest_address("255.255.255.255", DISCOVER_PORT)
	_udp.put_packet(JSON.stringify({"glasshouse": "discover"}).to_utf8_buffer())


func _process(delta: float) -> void:
	_t += delta
	if _t > 3.0:
		_t = 0.0
		_ping()
	while _udp.get_available_packet_count() > 0:
		var pkt := _udp.get_packet()
		var from := _udp.get_packet_ip()
		var v = JSON.parse_string(pkt.get_string_from_utf8())
		if typeof(v) != TYPE_DICTIONARY or str(v.get("glasshouse", "")) != "here":
			continue
		var entry := {"name": str(v.get("name", from)), "host": from, "port": int(v.get("port", 7570))}
		var dup := false
		for h in hosts:
			if h["host"] == from:
				dup = true
		if not dup:
			hosts.append(entry)
			print("[pair] found host %s at %s" % [entry["name"], from])
			if host == "":
				host = from
				port = entry["port"]
				field = 1
			_render()


## Returns true when the key was consumed. Called by terminal.gd before the
## router so nothing typed here reaches a tmux pane.
func feed(k: InputEventKey) -> bool:
	if not k.pressed or _busy:
		return true
	match k.keycode:
		KEY_ESCAPE:
			emit_signal("cancelled")
			return true
		KEY_TAB, KEY_DOWN, KEY_UP:
			if field == 0 and host == "" and hosts.size() > 0:
				host = hosts[0]["host"]
				port = hosts[0]["port"]
			field = 1 - field
			_render()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if field == 0:
				field = 1
				_render()
			else:
				_submit()
			return true
		KEY_BACKSPACE:
			if field == 0:
				host = host.left(host.length() - 1)
			else:
				code = code.left(code.length() - 1)
			_render()
			return true
	var ch := char(k.unicode) if k.unicode > 0 else ""
	if ch == "":
		return true
	if field == 0:
		if ch.is_valid_int() or ch in ".:-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_":
			host += ch
	else:
		if ch.is_valid_int() and code.length() < 6:
			code += ch
	_render()
	return true


func _submit() -> void:
	if host == "":
		status = "! pick or type the host first"
		_render()
		return
	if code.length() != 6:
		status = "! the code is six digits"
		_render()
		return
	var h := host
	var p := port
	if ":" in host:
		var parts := host.split(":")
		h = parts[0]
		p = int(parts[1])
	_busy = true
	status = "pairing with %s…" % h
	_render()
	var url := "http://%s:%d/pair" % [h, p]
	var body := JSON.stringify({"code": code})
	var err := _http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_busy = false
		status = "! could not reach %s (%d)" % [h, err]
		_render()


func _on_http(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS:
		status = "! no answer from the host (%d) — is glassd running with --lan?" % result
		_render()
		return
	var v = JSON.parse_string(body.get_string_from_utf8())
	if response_code == 200 and typeof(v) == TYPE_DICTIONARY and v.has("token"):
		var h := host.split(":")[0]
		save(h, port, str(v["token"]))
		status = "paired ✓"
		_render()
		emit_signal("paired", h, port, str(v["token"]))
		return
	var reason := str(v.get("error", response_code)) if typeof(v) == TYPE_DICTIONARY else str(response_code)
	match reason:
		"wrong": status = "! wrong code"
		"expired": status = "! that code expired — run  glasshouse pair  again"
		"none": status = "! no code is active — run  glasshouse pair  on the host"
		"locked": status = "! too many tries — wait 5 minutes, then  glasshouse pair"
		_: status = "! pairing failed: " + reason
	code = ""
	_render()

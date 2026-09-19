extends Node
class_name GlassClient

## WebSocket link to atriumd on the host.
##
## Godot's built-in WebSocketPeer — no addon, no native dependency. That is the
## whole point of the architecture: the host does the terminal emulation, this
## end just receives already-rendered cells.

signal screen_frame(msg)
signal sessions(list)
signal config_changed(cfg)
## The ⚙ panel: {"schema": [...], "overrides": {...}} — sent with every config.
signal settings_changed(s)
## A subscribe named a session the host does not have (closed since last run).
signal session_missing(key)
signal link_state(text)
signal keys_ack(msg)
signal scroll_ack(msg)
## The host's recommendation for `jump to whoever needs me`, or "" for nobody.
signal focus_hint(key)
## A session ended or was closed — drop its card.
signal session_removed(key)
## The host started the session we asked for with new_session().
signal session_created(key)
## A JPEG frame of a web app (browser mode).
signal web_frame(msg)

@export var host := "127.0.0.1"
@export var port := 7570
@export var token := ""

var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _retry := 0.0
var _subscribed: Array[String] = []
var connected := false


func url() -> String:
	var u := "ws://%s:%d/ws" % [host, port]
	if token != "":
		u += "?token=" + token
	return u


func start() -> void:
	_connect()


## Drop the current socket and connect again with the current host/token —
## what a re-pair needs. Subscriptions are replayed on connect as usual.
func reconnect() -> void:
	connected = false
	_ws.close()
	_ws = WebSocketPeer.new()
	_retry = 0.0
	_connect()


func _connect() -> void:
	emit_signal("link_state", "connecting to %s:%d" % [host, port])
	# ⛔ Godot's default inbound buffer is 64 KB and a web frame is ~60-200 KB:
	# the socket closes with 1009 (message too big) on every frame. Set before
	# connecting — it cannot change on an open socket.
	_ws.inbound_buffer_size = 8 * 1024 * 1024
	_ws.max_queued_packets = 64
	var err := _ws.connect_to_url(url())
	if err != OK:
		emit_signal("link_state", "connect failed: %d" % err)
		_retry = 2.0


var want_cols := 0
var want_rows := 0


## Ask the host to resize the tmux window to our panel geometry. atriumd records
## the previous size and restores it on unsubscribe, disconnect or silence.
func subscribe(key: String, cols := 0, rows := 0) -> void:
	want_cols = cols
	want_rows = rows
	if not _subscribed.has(key):
		_subscribed.append(key)
	if connected:
		_send({"op": "subscribe", "key": key, "cols": cols, "rows": rows})


## Stop streaming a session. ⚠️ The host restores that window's original
## geometry when the last subscriber leaves, so always unsubscribe on a switch
## rather than just subscribing to something else.
func unsubscribe(key: String) -> void:
	_subscribed.erase(key)
	if connected:
		_send({"op": "unsubscribe", "key": key})


## Ask for a fresh session. The host decides what runs (sessions.new).
func new_session() -> void:
	if connected:
		_send({"op": "new_session"})


## Kill a session this client is watching. The caller confirms first.
func close_session(key: String) -> void:
	if connected:
		_send({"op": "close_session", "key": key})


## ⚙ panel: `values` = {"dotted.path": value}. The host checks every path and
## value against its own schema and writes settings.json, never config.lua.
func send_settings(values: Dictionary) -> void:
	if connected:
		_send({"op": "set_settings", "values": values})


## Drop panel overrides so config.lua shows through. `keys` = [] of paths, or
## null for all of them.
func reset_settings(keys) -> void:
	if connected:
		_send({"op": "reset_settings", "keys": keys})


func resync(key: String) -> void:
	if connected:
		_send({"op": "resync", "key": key})


## Send typed keys. `stamp` comes back in the ack unchanged, which is how the
## client measures round-trip time without a clock shared with the host.
## ⚠️ The host only accepts keys for a session this client has SUBSCRIBED to.
func send_keys(key: String, seq: Array, stamp := 0) -> void:
	if not connected or seq.is_empty():
		return
	_send({"op": "keys", "key": key, "seq": seq, "t": stamp})


## A pointer scroll. `lines` > 0 = older; col/row = the 1-based cell under
## the ray, which the host forwards to apps that take a mouse wheel.
func send_scroll(key: String, lines: int, col: int, row: int, uv := Vector2(0.5, 0.5)) -> void:
	if not connected or lines == 0:
		return
	_send({"op": "scroll", "key": key, "lines": lines, "col": col, "row": row,
			"u": uv.x, "v": uv.y})


## Browser mode: a click or a mouse move at page coordinates 0..1.
func send_web_pointer(key: String, kind: String, uv: Vector2) -> void:
	if connected:
		_send({"op": "web_pointer", "key": key, "kind": kind, "u": uv.x, "v": uv.y})


## Browser mode: "back" or "reload".
func send_web_nav(key: String, what: String) -> void:
	if connected:
		_send({"op": "web_nav", "key": key, "what": what})


func _send(obj: Dictionary) -> void:
	_ws.send_text(JSON.stringify(obj))


var _ka := 0.0


func _process(delta: float) -> void:
	# Keepalive doubles as the pin watchdog heartbeat on the host.
	if connected:
		_ka += delta
		if _ka >= 20.0:
			_ka = 0.0
			_send({"op": "ping"})

	if _retry > 0.0:
		_retry -= delta
		if _retry <= 0.0:
			_connect()
		return

	_ws.poll()
	var st := _ws.get_ready_state()

	if st != _state:
		_state = st
		match st:
			WebSocketPeer.STATE_OPEN:
				connected = true
				emit_signal("link_state", "connected")
				for k in _subscribed:
					_send({"op": "subscribe", "key": k, "cols": want_cols, "rows": want_rows})
			WebSocketPeer.STATE_CLOSED:
				connected = false
				var code := _ws.get_close_code()
				# 1008/401 here almost always means a bad or missing token.
				emit_signal("link_state", "closed (%d) — retrying" % code)
				_retry = 2.0

	if st != WebSocketPeer.STATE_OPEN:
		return

	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet().get_string_from_utf8()
		var msg = JSON.parse_string(raw)
		if typeof(msg) != TYPE_DICTIONARY:
			continue
		match msg.get("type", ""):
			"screen":
				emit_signal("screen_frame", msg)
			"snapshot":
				emit_signal("sessions", msg.get("sessions", []))
				emit_signal("focus_hint", str(msg.get("focus", "")))
			"session":
				emit_signal("sessions", [msg.get("session", {})])
			"config":
				emit_signal("config_changed", msg.get("config", {}))
				emit_signal("settings_changed", msg.get("settings", {}))
			"removed", "session-closed":
				emit_signal("session_removed", str(msg.get("key", "")))
			"web-frame":
				emit_signal("web_frame", msg)
			"session-created":
				emit_signal("session_created", str(msg.get("key", "")))
			"keys-ack":
				emit_signal("keys_ack", msg)
			"scroll-ack":
				emit_signal("scroll_ack", msg)
			"error":
				var err := str(msg.get("error", ""))
				if err.begins_with("no such tmux target"):
					# Not a link problem: the terminal picks another session.
					emit_signal("session_missing", str(msg.get("key", "")))
				else:
					emit_signal("link_state", "server error: " + err)

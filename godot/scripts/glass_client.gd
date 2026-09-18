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
signal link_state(text)
signal keys_ack(msg)
## The host's recommendation for `jump to whoever needs me`, or "" for nobody.
signal focus_hint(key)

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
			"keys-ack":
				emit_signal("keys_ack", msg)
			"error":
				emit_signal("link_state", "server error: " + str(msg.get("error", "")))

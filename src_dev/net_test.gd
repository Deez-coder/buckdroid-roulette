extends Node
## Dev only (never in user builds): WebRTC spike. Checks that the webrtc-native GDExtension loads in the converted game on
## Godot 4.6 and that two devices on the same network get a data channel, then measures round trips and throughput.
## Original code, part of Buckdroid Roulette (GPL-3.0-or-later).
##
## Roles, from a file or the command line (user args after "--"):
##   host:  --bd-net-test=host:7777            (listens for one signalling connection on TCP 7777)
##   join:  --bd-net-test=join:192.168.1.20:7777
## On Android the role is read from <app files>/dev/net_test.txt (same text), so no command line is needed.
## Signalling for this test is a plain TCP connection on the local network (the real layer replaces it).
## Results go to the log ([buckdroid-net] lines) and, on Android, <app files>/dev/net_test.log.

const PINGS := 50
const BULK_BYTES := 1 << 20
const CHUNK := 16000

var role := ""
var host_addr := ""
var port := 7777
var server: TCPServer
var tcp: StreamPeerTCP
var pc: WebRTCPeerConnection
var ch: WebRTCDataChannel
var log_path := ""
var started_ms := 0
var stage := "idle"
var ping_sent := {}
var rtts: Array[float] = []
var bulk_received := 0
var bulk_start := 0


func _ready() -> void:
	_read_role()
	if role == "":
		set_process(false)
		return
	_log("role %s, ClassDB has WebRTCPeerConnection: %s, OS %s" % [role, ClassDB.class_exists("WebRTCPeerConnection"), OS.get_name()])
	pc = WebRTCPeerConnection.new()
	var err := pc.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]})
	_log("initialize: %s (OK means the GDExtension implementation is loaded)" % error_string(err))
	if err != OK:
		set_process(false)
		return
	ch = pc.create_data_channel("game", {"negotiated": true, "id": 1})
	pc.session_description_created.connect(_on_sdp)
	pc.ice_candidate_created.connect(_on_candidate)
	started_ms = Time.get_ticks_msec()
	if role == "host":
		server = TCPServer.new()
		_log("listen: %s" % error_string(server.listen(port)))
		stage = "waiting for joiner"
	else:
		tcp = StreamPeerTCP.new()
		_log("connect to %s:%d: %s" % [host_addr, port, error_string(tcp.connect_to_host(host_addr, port))])
		stage = "connecting signalling"


func _read_role() -> void:
	var text := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-net-test="):
			text = arg.trim_prefix("--bd-net-test=")
	if text == "" and OS.get_name() == "Android":
		var parts := OS.get_user_data_dir().split("/", false)
		var pkg := parts[parts.size() - 1] if parts.size() > 0 else ""
		var dev := "/storage/emulated/0/Android/data/%s/files/dev" % pkg
		log_path = dev.path_join("net_test.log")
		var f := FileAccess.open(dev.path_join("net_test.txt"), FileAccess.READ)
		if f:
			text = f.get_as_text().strip_edges()
	var p := text.split(":")
	if p.size() >= 2 and p[0] == "host":
		role = "host"
		port = int(p[1])
	elif p.size() >= 3 and p[0] == "join":
		role = "join"
		host_addr = p[1]
		port = int(p[2])


func _log(s: String) -> void:
	var line := "[buckdroid-net] %6d ms  %s" % [Time.get_ticks_msec() - started_ms, s]
	print(line)
	if log_path != "":
		var f := FileAccess.open(log_path, FileAccess.READ_WRITE if FileAccess.file_exists(log_path) else FileAccess.WRITE)
		if f:
			f.seek_end()
			f.store_line(line)


func _send_signal(msg: Dictionary) -> void:
	if tcp and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		tcp.put_var(msg)


func _on_sdp(type: String, sdp: String) -> void:
	pc.set_local_description(type, sdp)
	_send_signal({"t": "sdp", "type": type, "sdp": sdp})


func _on_candidate(media: String, index: int, cand: String) -> void:
	_send_signal({"t": "cand", "media": media, "index": index, "name": cand})


func _process(_delta: float) -> void:
	if server and tcp == null and server.is_connection_available():
		tcp = server.take_connection()
		_log("joiner connected over TCP")
		stage = "signalling"
	if tcp:
		tcp.poll()
		if stage == "connecting signalling" and tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			stage = "signalling"
			_log("signalling connected, creating offer")
			pc.create_offer()
		while tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED and tcp.get_available_bytes() > 0:
			var msg = tcp.get_var(false)
			if typeof(msg) != TYPE_DICTIONARY:
				break
			if msg.get("t") == "sdp":
				pc.set_remote_description(str(msg.type), str(msg.sdp))
			elif msg.get("t") == "cand":
				pc.add_ice_candidate(str(msg.media), int(msg.index), str(msg.name))
	pc.poll()
	if ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
		if stage == "signalling":
			stage = "pinging"
			_log("data channel open (ICE state %d)" % pc.get_connection_state())
			if role == "join":
				_ping(0)
		_read_channel()


func _ping(i: int) -> void:
	ping_sent[i] = Time.get_ticks_usec()
	ch.put_packet(var_to_bytes({"ping": i}))


func _read_channel() -> void:
	while ch.get_available_packet_count() > 0:
		var raw := ch.get_packet()
		if raw.size() > 64:
			bulk_received += raw.size()
			if bulk_received >= BULK_BYTES:
				var s := (Time.get_ticks_msec() - bulk_start) / 1000.0
				_log("bulk: %d bytes in %.2f s = %.0f KB/s" % [bulk_received, s, bulk_received / 1024.0 / max(s, 0.001)])
				ch.put_packet(var_to_bytes({"done": true}))
			continue
		var m = bytes_to_var(raw)
		if typeof(m) != TYPE_DICTIONARY:
			continue
		if m.has("ping"):
			ch.put_packet(var_to_bytes({"pong": m.ping}))
		elif m.has("pong"):
			rtts.append((Time.get_ticks_usec() - ping_sent[m.pong]) / 1000.0)
			if rtts.size() < PINGS:
				_ping(m.pong + 1)
			else:
				var sorted := rtts.duplicate()
				sorted.sort()
				_log("round trip over %d pings: median %.1f ms, max %.1f ms" % [PINGS, sorted[PINGS / 2], sorted[-1]])
				ch.put_packet(var_to_bytes({"bulk_start": true}))
				var chunk := PackedByteArray()
				chunk.resize(CHUNK)
				var sent := 0
				while sent < BULK_BYTES:
					ch.put_packet(chunk)
					sent += CHUNK
		elif m.has("bulk_start"):
			bulk_start = Time.get_ticks_msec()
			bulk_received = 0
		elif m.has("done"):
			_log("test finished OK")
			stage = "done"

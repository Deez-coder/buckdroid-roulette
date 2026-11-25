extends Node
## BuckdroidNet - the multiplayer session behind our Steam replacement. Original code, part of Buckdroid Roulette
## (GPL-3.0-or-later). Design and security notes: docs/MULTIPLAYER.md.
##
## A lobby is a star around the host, like the game's own design: every member has one WebRTC data channel to the host,
## and the host forwards. The game never sees this; steam_stub.gd turns its Steam lobby and P2P calls into calls here.
##
## Finding the host, two ways at once (whichever answers first is used):
##   - local network: the host announces its lobby by UDP broadcast; a joiner that knows the lobby ID waits for the
##     announcement and opens a short TCP connection to the host to exchange the WebRTC offer and answer;
##   - internet: the lobby ID is the room code; both sides meet through public brokers with encrypted, authenticated
##     messages (room_signal.gd). Local network addresses are left out of what is sent this way, and public STUN servers
##     help the direct connection through routers.
## Then everything runs over the WebRTC data channel, directly between the phones.
##
## Wire format on the data channel: one byte message type, then
##   MSG_CTL   var_to_bytes(Dictionary) (objects never decoded): hello, welcome, deny, joined, left, data, ping, pong
##   MSG_GAME  8 bytes sender ID, 8 bytes target ID, then the game's packet as it gave it to sendP2PPacket
## Everything from a peer is checked before use: sizes, rates, the game packet's decompressed size, member IDs.

signal lobby_created(ok: bool, lobby_id: int)
signal lobby_joined(lobby_id: int, response: int)              # response: Steam's CHAT_ROOM_ENTER_RESPONSE_* values
signal member_changed(lobby_id: int, member_id: int, state: int)  # state: Steam's CHAT_MEMBER_STATE_CHANGE_* values
signal lobby_list(lobby_ids: Array)
signal chat_received(sender_id: int, text: String)

const PROTOCOL := 1
const DISCOVERY_PORT := 47610
const HOST_PORT := 47611
const ANNOUNCE_EVERY := 1.0
const JOIN_TIMEOUT := 8.0
const HEARTBEAT_EVERY := 2.0
const PEER_TIMEOUT := 60.0          # silence limit; loading a match can freeze a game for many seconds
const MAX_GAME_PACKET := 64 * 1024        # compressed, as the game sends it
const MAX_GAME_UNPACKED := 1024 * 1024    # what it may decompress to (the game decompresses without a limit)
const MAX_PACKETS_PER_SEC := 240
const MAX_BYTES_PER_SEC := 1024 * 1024
const MAX_CHAT := 200
const MSG_CTL := 1
const MSG_GAME := 2
const MSG_CHAT := 3
const STUN := ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"]
const OFFER_RETRY := 4.0
const REJOIN_GRACE := 20.0        # a dropped connection gets this long to come back before the game hears "left"
const MAX_QUEUE := 512            # game messages held for a member while its connection comes back
const ROOM_JOIN_TIMEOUT := 30.0   # the host may be in another app for a moment (sharing the code); Android pauses it
const RoomSignal := preload("res://buckdroid/net/room_signal.gd")

# Steam enum values (the same as steam_stub.gd)
const ENTER_SUCCESS := 1
const ENTER_DOESNT_EXIST := 2
const ENTER_NOT_ALLOWED := 3
const ENTER_FULL := 4
const ENTER_ERROR := 5
const STATE_ENTERED := 1
const STATE_LEFT := 2
const STATE_KICKED := 8

var available := false            # the WebRTC GDExtension is loaded
var my_id := 0
var my_name := "Player"
var lobby_id := 0
var owner_id := 0
var is_host := false
var member_limit := 4
var joinable := true
var members: Array = []           # [{id, name}] in join order, host first
var lobby_data := {}
var game_version := ""

var _inbox: Array = []            # [[sender_id, PackedByteArray]] game packets for readP2PPacket
var _peers := {}                  # host: peer key -> Peer;   member: one entry, key 0 (the host)
var _server: TCPServer
var _announce: PacketPeerUDP
var _listen: PacketPeerUDP
var _announce_timer := 0.0
var _found := {}                  # lobby_id -> {ip, port, name, members, limit, seen}
var _joining := 0
var _join_started := 0.0
var _join_peer: Peer
var _next_key := 1
var _direct_host := ""            # dev and tests: --bd-net-host=ip:port skips discovery
var _no_lan := false              # tests: --bd-net-no-lan forces the internet path
var _kicked: Array[int] = []
var _room: RefCounted             # RoomSignal while hosting (new members) or joining (until welcomed)
var _held := {}                   # host: member ID -> {since, queue} for members whose connection dropped
var _rejoining := false           # member: the connection to the host dropped, reconnecting
var _rejoin_until := 0.0
var _outq: Array = []             # member: messages for the host held while reconnecting


class Peer:
	var key := 0
	var id := 0                   # the member's player ID, after hello
	var name := ""
	var tcp: StreamPeerTCP        # signalling over the local network, closed once the channel is open
	var room_sid := ""            # signalling through the room: the other side's session ID ("" = not known yet)
	var via_room := false
	var pc: WebRTCPeerConnection
	var ch: WebRTCDataChannel
	var open := false
	var last_heard := 0.0
	var window_start := 0.0
	var window_packets := 0
	var window_bytes := 0
	var started := 0.0


func _ready() -> void:
	available = ClassDB.class_exists("WebRTCPeerConnection") and ClassDB.can_instantiate("WebRTCPeerConnection")
	_load_identity()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-net-host="):
			_direct_host = arg.trim_prefix("--bd-net-host=")
		elif arg == "--bd-net-no-lan":
			_no_lan = true
	var vf := FileAccess.open("res://buckdroid/versions.json", FileAccess.READ)
	if vf:
		var v = JSON.parse_string(vf.get_as_text())
		if v is Dictionary and v.get("versions") is Array and not v.versions.is_empty():
			game_version = str(v.versions[0].get("name", ""))
	print("[buckdroid] multiplayer: %s, player %s (%d)" % ["available" if available else "not available", my_name, my_id])


# --- identity: a random player ID kept on this device and the nickname from the settings ---------------------------
func _load_identity() -> void:
	var name_arg := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bd-player="):
			name_arg = arg.trim_prefix("--bd-player=")
	if name_arg != "":               # tests: several copies on one machine, each its own player
		my_name = name_arg
		my_id = _positive_id(name_arg.hash() * 2654435761)
		return
	var cfg := ConfigFile.new()
	var path := "user://buckdroid_player.cfg"
	cfg.load(path)
	my_id = int(cfg.get_value("player", "id", 0))
	if my_id <= 0:
		my_id = _random_id()
		cfg.set_value("player", "id", my_id)
		cfg.save(path)
	my_name = "Player %04d" % (my_id % 10000)
	var settings := get_node_or_null(^"/root/BuckdroidSettings")
	if settings and settings.has_method("get_value"):
		var n = settings.get_value("multiplayer", "nickname")
		if n is String and n.strip_edges() != "":
			my_name = _clean_name(n)


static func _random_id() -> int:
	var c := Crypto.new()
	var b := c.generate_random_bytes(8)
	return _positive_id(b.decode_s64(0))


static func _positive_id(v: int) -> int:
	v = v & 0x0FFFFFFFFFFFFFFF     # positive, and far from Steam's ID range
	return v if v > 0 else 1


static func _clean_name(s: String) -> String:
	var out := ""
	for c in s.strip_edges():
		if c.unicode_at(0) >= 32 and c not in "[]<>":
			out += c
	return out.substr(0, 24) if out != "" else "Player"


# --- lobby: create, join, leave ------------------------------------------------------------------------------------
func create_lobby(limit: int) -> void:
	leave_lobby()
	if not available:
		lobby_created.emit.call_deferred(false, 0)
		return
	_server = TCPServer.new()
	# A fixed port when free (lets a test machine connect with --bd-net-host), any free port otherwise.
	if _server.listen(HOST_PORT) != OK and _server.listen(0) != OK:
		_server = null
		lobby_created.emit.call_deferred(false, 0)
		return
	if not _no_lan:
		_announce = PacketPeerUDP.new()
		_announce.set_broadcast_enabled(true)
	lobby_id = _new_lobby_id()
	owner_id = my_id
	is_host = true
	member_limit = clampi(limit, 2, 4)
	joinable = true
	members = [{"id": my_id, "name": my_name}]
	lobby_data = {}
	_kicked.clear()
	_start_room(lobby_id)
	print("[buckdroid] lobby hosted (local port %d, internet room on)" % _server.get_local_port())
	lobby_created.emit.call_deferred(true, lobby_id)
	lobby_joined.emit.call_deferred(lobby_id, ENTER_SUCCESS)


static func _new_lobby_id() -> int:
	# 18 digits (about 59 bits): the room code for internet play, so it must not be guessable. Exactly 18 because the
	# game's "join with pasted ID" only accepts 18 characters (the length of a Steam lobby ID).
	var c := Crypto.new()
	var b := c.generate_random_bytes(8)
	return 100000000000000000 + absi(b.decode_s64(0)) % 900000000000000000


func join_lobby(id: int) -> void:
	leave_lobby()
	if not available:
		lobby_joined.emit.call_deferred(id, ENTER_ERROR)
		return
	_joining = id
	_join_started = _now()
	_start_listening()
	_start_room(id)
	if _direct_host != "":
		var p := _direct_host.split(":")
		if p.size() == 2:
			_connect_to_host(p[0], int(p[1]))


func leave_lobby() -> void:
	for key in _peers.keys():
		if _peers[key].open:
			_send_ctl(_peers[key], {"t": "bye"})     # leaving on purpose: no reconnect grace on the other side
		_close_peer(_peers[key], false)
	_held.clear()
	_rejoining = false
	_outq.clear()
	_peers.clear()
	if _server:
		_server.stop()
		_server = null
	_announce = null
	if _room:
		_room.stop()
		_room = null
	_join_peer = null
	_joining = 0
	lobby_id = 0
	owner_id = 0
	is_host = false
	members.clear()
	lobby_data.clear()
	_inbox.clear()


func request_lobby_list() -> void:
	_start_listening()
	await get_tree().create_timer(ANNOUNCE_EVERY * 2.5).timeout
	var ids := []
	for id in _found:
		if _now() - _found[id].seen < ANNOUNCE_EVERY * 4:
			ids.append(id)
	lobby_list.emit(ids)


func found_lobby(id: int) -> Dictionary:
	return _found.get(id, {})


func set_data(key: String, value: String) -> void:
	if not is_host:
		return
	lobby_data[key] = value
	_broadcast_ctl({"t": "data", "k": key, "v": value})


func set_limit(limit: int) -> void:
	if is_host:
		member_limit = clampi(limit, 2, 4)


func member_name(id: int) -> String:
	for m in members:
		if m.id == id:
			return m.name
	if id == my_id:
		return my_name
	return "Player"


# --- game packets ----------------------------------------------------------------------------------------------------
func send_game(target: int, data: PackedByteArray) -> bool:
	if lobby_id == 0 or data.size() > MAX_GAME_PACKET:
		return false
	var msg := PackedByteArray([MSG_GAME])
	msg.resize(17)
	msg.encode_s64(1, my_id)
	msg.encode_s64(9, target)
	msg.append_array(data)
	if is_host:
		return _send_to_member(target, msg)
	var host: Peer = _peers.get(0)
	if _rejoining or host == null or not host.open:
		if _rejoining and _outq.size() < MAX_QUEUE:
			_outq.append(msg)
			return true
		return false
	return _send(host, msg)


## Host: send to a member, or hold the message while that member's connection comes back.
func _send_to_member(id: int, msg: PackedByteArray) -> bool:
	var p := _peer_by_id(id)
	if p != null and p.open:
		return _send(p, msg)
	if _held.has(id) and _held[id].queue.size() < MAX_QUEUE:
		_held[id].queue.append(msg)
		return true
	return false


func available_packet_size() -> int:
	return _inbox[0][1].size() if not _inbox.is_empty() else 0


func read_packet() -> Dictionary:
	if _inbox.is_empty():
		return {}
	var item = _inbox.pop_front()
	return {"data": item[1], "steam_id_remote": item[0], "size": item[1].size()}


func send_chat(text: String) -> void:
	text = text.strip_edges().substr(0, MAX_CHAT)
	if text == "" or lobby_id == 0:
		return
	var msg := PackedByteArray([MSG_CHAT])
	msg.resize(9)
	msg.encode_s64(1, my_id)
	msg.append_array(text.to_utf8_buffer())
	if is_host:
		for p in _peers.values():
			if p.open:
				_send(p, msg)
	elif _peers.has(0):
		_send(_peers[0], msg)
	chat_received.emit(my_id, text)


# --- every frame -----------------------------------------------------------------------------------------------------
func _process(delta: float) -> void:
	if not available:
		return
	_poll_discovery(delta)
	if _room:
		_room.poll()
		_poll_room_join()
	if _server:
		while _server.is_connection_available():
			_accept(_server.take_connection())
	var room_waiting := _join_peer != null and _join_peer.via_room and _join_peer.room_sid == ""
	if _joining != 0 and (_join_peer == null or room_waiting):
		var f: Dictionary = _found.get(_joining, {})
		if not f.is_empty():
			_connect_to_host(f.ip, f.port)       # on the same network: the direct local path wins
		elif not _rejoining and _now() - _join_started > ROOM_JOIN_TIMEOUT:
			if _join_peer:
				_close_peer(_join_peer, false)
				_peers.erase(0)
				_join_peer = null
			var id := _joining
			_joining = 0
			lobby_joined.emit(id, ENTER_DOESNT_EXIST)
	for key in _peers.keys():
		var p: Peer = _peers.get(key)
		if p:
			_poll_peer(p)
	var now := _now()
	if is_host:
		for id in _held.keys():
			if now - _held[id].since > REJOIN_GRACE:
				print("[buckdroid] member did not come back in time")
				_held.erase(id)
				if _remove_member(id):
					_broadcast_ctl({"t": "left", "id": id, "kicked": false})
					member_changed.emit(lobby_id, id, STATE_LEFT)
	elif _rejoining and now > _rejoin_until:
		print("[buckdroid] could not reconnect to the host")
		_give_up_host()


func _poll_discovery(delta: float) -> void:
	if is_host and _announce and joinable:
		_announce_timer -= delta
		if _announce_timer <= 0.0:
			_announce_timer = ANNOUNCE_EVERY
			var msg := JSON.stringify({"bd": PROTOCOL, "lobby": lobby_id, "port": _server.get_local_port(),
					"name": my_name, "members": members.size(), "limit": member_limit})
			_announce.set_dest_address("255.255.255.255", DISCOVERY_PORT)
			_announce.put_packet(msg.to_utf8_buffer())
	if _listen:
		while _listen.get_available_packet_count() > 0:
			var raw := _listen.get_packet()
			var ip := _listen.get_packet_ip()
			if raw.size() > 512:
				continue
			var m = JSON.parse_string(raw.get_string_from_utf8())
			if not (m is Dictionary) or int(m.get("bd", 0)) != PROTOCOL:
				continue
			var id := int(m.get("lobby", 0))
			if id <= 0 or id == lobby_id:
				continue
			_found[id] = {"ip": ip, "port": int(m.get("port", 0)), "name": _clean_name(str(m.get("name", ""))),
					"members": int(m.get("members", 0)), "limit": int(m.get("limit", 4)), "seen": _now()}


func _start_listening() -> void:
	if _listen or _no_lan:
		return
	_listen = PacketPeerUDP.new()
	if _listen.bind(DISCOVERY_PORT) != OK:
		push_warning("[buckdroid] lobby discovery port %d is busy" % DISCOVERY_PORT)


# --- connections -----------------------------------------------------------------------------------------------------
func _new_peer(via_room := false) -> Peer:
	var p := Peer.new()
	p.via_room = via_room
	p.pc = WebRTCPeerConnection.new()
	# Over the internet, public STUN servers tell each side its public address (local network: not needed).
	p.pc.initialize({"iceServers": [{"urls": STUN}] if via_room else []})
	p.ch = p.pc.create_data_channel("bd", {"negotiated": true, "id": 1})
	p.pc.session_description_created.connect(func(type: String, sdp: String) -> void:
		p.pc.set_local_description(type, sdp)
		_signal(p, {"t": "sdp", "type": type, "sdp": sdp}))
	p.pc.ice_candidate_created.connect(func(media: String, index: int, cand: String) -> void:
		_signal(p, {"t": "cand", "media": media, "index": index, "name": cand}))
	p.started = _now()
	p.last_heard = _now()
	return p


func _connect_to_host(ip: String, port: int) -> void:
	if _join_peer != null and _join_peer.via_room and _join_peer.room_sid != "":
		return                           # already talking to the host through the room
	if _join_peer != null:
		_close_peer(_join_peer, false)
		_peers.erase(0)
	var p := _new_peer()
	p.key = 0
	p.tcp = StreamPeerTCP.new()
	if p.tcp.connect_to_host(ip, port) != OK:
		return
	_join_peer = p
	_peers[0] = p


func _accept(tcp: StreamPeerTCP) -> void:
	if _peers.size() >= member_limit - 1 or not (joinable or not _held.is_empty()):
		tcp.disconnect_from_host()
		return
	var p := _new_peer()
	p.key = _next_key
	_next_key += 1
	p.tcp = tcp
	_peers[p.key] = p


func _signal(p: Peer, msg: Dictionary) -> void:
	if p.tcp and p.tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		p.tcp.put_var(msg)
	elif p.via_room and _room:
		if msg.get("t") == "cand" and " typ host" in str(msg.get("name", "")):
			return                       # never send this device's local network addresses over the internet
		if msg.get("t") == "sdp":
			msg = msg.duplicate()
			msg["sdp"] = _strip_host_candidates(str(msg.sdp))
			if msg.get("type") == "offer":
				p.set_meta("offer", msg)
				p.set_meta("offer_at", _now())
		_room.send(p.room_sid, msg)


static func _strip_host_candidates(sdp: String) -> String:
	var out := PackedStringArray()
	for line in sdp.split("\n"):
		if line.begins_with("a=candidate:") and " typ host" in line:
			continue
		out.append(line)
	return "\n".join(out)


# --- the internet room ------------------------------------------------------------------------------------------------
func _start_room(id: int) -> void:
	if _room:
		_room.stop()
	_room = RoomSignal.new(str(id))
	_room.message.connect(_on_room)
	_room.start()


## Joining through the room: once a broker is connected, make one peer and send its offer to the room (to everyone:
## only the host answers). Resent until answered, since brokers deliver at most once.
func _poll_room_join() -> void:
	if is_host or _joining == 0 or _room == null or _room.connected_count() == 0:
		return
	if _join_peer == null:
		var p := _new_peer(true)
		p.key = 0
		_join_peer = p
		_peers[0] = p
		p.pc.create_offer()
		return
	var jp := _join_peer
	if jp.via_room and not jp.open and jp.room_sid == "" and jp.has_meta("offer") and _now() - float(jp.get_meta("offer_at")) > OFFER_RETRY:
		jp.set_meta("offer_at", _now())
		_room.send("", jp.get_meta("offer"))


func _on_room(from: String, m: Dictionary) -> void:
	var t := str(m.get("t", ""))
	var p: Peer = null
	for q in _peers.values():
		if q.via_room and q.room_sid == from:
			p = q
	if is_host:
		if p == null:
			if t != "sdp" or str(m.get("type", "")) != "offer" or not (joinable or not _held.is_empty()) 					or _peers.size() >= member_limit - 1:
				return
			p = _new_peer(true)
			p.key = _next_key
			_next_key += 1
			p.room_sid = from
			_peers[p.key] = p
			p.pc.set_remote_description("offer", str(m.get("sdp", "")))
			return
	else:
		var jp := _join_peer
		if jp == null or not jp.via_room or _joining == 0:
			return
		if jp.room_sid == "":
			if t != "sdp" or str(m.get("type", "")) != "answer":
				return
			jp.room_sid = from          # the host
			jp.pc.set_remote_description("answer", str(m.get("sdp", "")))
			return
		p = jp
	if p and t == "cand":
		p.pc.add_ice_candidate(str(m.get("media", "")), int(m.get("index", 0)), str(m.get("name", "")))


func _poll_peer(p: Peer) -> void:
	if p.tcp:
		p.tcp.poll()
		var st := p.tcp.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			if not is_host and p.pc.get_signaling_state() == WebRTCPeerConnection.SIGNALING_STATE_STABLE \
					and not p.open and not p.has_meta("offered"):
				p.set_meta("offered", true)
				p.pc.create_offer()
			while p.tcp.get_available_bytes() > 0:
				if p.tcp.get_available_bytes() > 256 * 1024:
					_close_peer(p, true)
					return
				var m = p.tcp.get_var(false)
				if not (m is Dictionary):
					break
				if m.get("t") == "sdp" and m.get("type") in ["offer", "answer"]:
					p.pc.set_remote_description(str(m.type), str(m.sdp))
				elif m.get("t") == "cand":
					p.pc.add_ice_candidate(str(m.get("media", "")), int(m.get("index", 0)), str(m.get("name", "")))
	p.pc.poll()
	if not p.open:
		if p.ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN:
			p.open = true
			p.last_heard = _now()
			if not is_host:
				_send_ctl(p, {"t": "hello", "proto": PROTOCOL, "ver": game_version, "id": my_id, "name": my_name})
		elif _now() - p.started > (JOIN_TIMEOUT * 2 if p.via_room else JOIN_TIMEOUT):
			if not is_host and _joining != 0:
				if p.via_room and p.room_sid == "":
					return                       # nobody answered yet: the lobby timeout above decides
				if _rejoining:
					_close_peer(p, false)        # this attempt failed; the next one starts on the next frame
					_peers.erase(0)
					_join_peer = null
					return
				var id := _joining
				_joining = 0
				_close_peer(p, false)
				_peers.erase(0)
				_join_peer = null
				if p.via_room:
					# The host answered but no direct path got through (strict routers on both sides).
					_toast("Could not connect directly to the host. Try the same Wi-Fi, or another network.")
				lobby_joined.emit(id, ENTER_ERROR)
			else:
				_close_peer(p, false)
				_peers.erase(p.key)
		return
	if p.tcp and p.id != 0:
		p.tcp.disconnect_from_host()   # signalling done
		p.tcp = null
	while p.ch.get_available_packet_count() > 0:
		var raw := p.ch.get_packet()
		if not _rate_ok(p, raw.size()):
			_drop(p, true, "sends too much")
			return
		_receive(p, raw)
		if not _peers.has(p.key):
			return
	var now := _now()
	var cs := p.pc.get_connection_state()
	var why := ""
	if cs == WebRTCPeerConnection.STATE_FAILED:
		why = "connection failed"
	elif cs == WebRTCPeerConnection.STATE_CLOSED:
		why = "connection closed"
	elif p.ch.get_ready_state() == WebRTCDataChannel.STATE_CLOSED:
		why = "data channel closed"
	elif now - p.last_heard > PEER_TIMEOUT:
		why = "silent for %d s" % int(now - p.last_heard)
	if why != "":
		_drop(p, false, why)
		return
	if not p.has_meta("hb") or now - float(p.get_meta("hb")) > HEARTBEAT_EVERY:
		p.set_meta("hb", now)
		_send_ctl(p, {"t": "ping"})


func _rate_ok(p: Peer, size: int) -> bool:
	var now := _now()
	if now - p.window_start >= 1.0:
		p.window_start = now
		p.window_packets = 0
		p.window_bytes = 0
	p.window_packets += 1
	p.window_bytes += size
	return p.window_packets <= MAX_PACKETS_PER_SEC and p.window_bytes <= MAX_BYTES_PER_SEC


func _receive(p: Peer, raw: PackedByteArray) -> void:
	if raw.is_empty():
		return
	p.last_heard = _now()
	match raw[0]:
		MSG_CTL:
			if raw.size() > 16 * 1024:
				return
			var m = bytes_to_var(raw.slice(1))
			if m is Dictionary:
				_on_ctl(p, m)
		MSG_GAME:
			if raw.size() < 17 or p.id == 0 and is_host:
				return
			var sender := raw.decode_s64(1)
			var target := raw.decode_s64(9)
			var data := raw.slice(17)
			if not _game_packet_ok(data):
				return
			if is_host:
				if sender != p.id:
					return                  # members can only speak for themselves
				if target == my_id:
					_inbox.append([sender, data])
				else:
					_send_to_member(target, raw)   # forwarded unchanged: the target sees the real sender
			else:
				if _is_member(sender):
					_inbox.append([sender, data])
		MSG_CHAT:
			if raw.size() < 9 or raw.size() > 9 + MAX_CHAT * 4:
				return
			var sender := raw.decode_s64(1)
			if is_host:
				if sender != p.id:
					return
				for q in _peers.values():
					if q != p and q.open:
						_send(q, raw)
			elif not _is_member(sender):
				return
			var text := raw.slice(9).get_string_from_utf8().substr(0, MAX_CHAT)
			chat_received.emit(sender, text)


## The game decompresses packets with no size limit: refuse anything that would unpack to more than MAX_GAME_UNPACKED.
func _game_packet_ok(data: PackedByteArray) -> bool:
	if data.is_empty() or data.size() > MAX_GAME_PACKET:
		return false
	var out := data.decompress_dynamic(MAX_GAME_UNPACKED, FileAccess.COMPRESSION_GZIP)
	return not out.is_empty() and out.size() < MAX_GAME_UNPACKED


func _on_ctl(p: Peer, m: Dictionary) -> void:
	var t := str(m.get("t", ""))
	if t == "ping":
		_send_ctl(p, {"t": "pong"})
		return
	if t == "pong":
		return
	if t == "bye":
		p.set_meta("bye", true)
		_drop(p, false, "left")
		return
	if is_host:
		if t == "hello" and p.id == 0 and _held.has(int(m.get("id", 0))):
			# A member whose connection dropped is back: same seat, and what was held for it goes out now.
			var rid := int(m.get("id", 0))
			p.id = rid
			p.name = member_name(rid)
			_send_ctl(p, {"t": "welcome", "lobby": lobby_id, "owner": my_id, "members": members, "data": lobby_data,
					"limit": member_limit, "rejoin": true})
			for msg in _held[rid].queue:
				_send(p, msg)
			print("[buckdroid] member reconnected after %.1f s (%d held messages)" % [_now() - _held[rid].since, _held[rid].queue.size()])
			_held.erase(rid)
			return
		if t == "hello" and p.id == 0:
			var id := int(m.get("id", 0))
			var deny := 0
			if int(m.get("proto", 0)) != PROTOCOL:
				deny = ENTER_ERROR
			elif str(m.get("ver", "")) != game_version:
				deny = ENTER_NOT_ALLOWED
			elif id <= 0 or _is_member(id) or id in _kicked or not joinable:
				deny = ENTER_NOT_ALLOWED       # (not joinable: the match has started; only held seats come back)
			elif members.size() >= member_limit:
				deny = ENTER_FULL
			if deny != 0:
				_send_ctl(p, {"t": "deny", "code": deny})
				_close_peer(p, false)
				_peers.erase(p.key)
				return
			p.id = id
			p.name = _clean_name(str(m.get("name", "")))
			members.append({"id": id, "name": p.name})
			_send_ctl(p, {"t": "welcome", "lobby": lobby_id, "owner": my_id, "members": members, "data": lobby_data,
					"limit": member_limit})
			for q in _peers.values():
				if q != p and q.open and q.id != 0:
					_send_ctl(q, {"t": "joined", "id": id, "name": p.name})
			member_changed.emit(lobby_id, id, STATE_ENTERED)
		return
	# member side
	match t:
		"welcome":
			if _rejoining:
				_finish_rejoin(p, m)
				return
			var id := _joining
			_joining = 0
			lobby_id = int(m.get("lobby", id))
			owner_id = int(m.get("owner", 0))
			member_limit = int(m.get("limit", 4))
			members.clear()
			for e in m.get("members", []):
				if e is Dictionary:
					members.append({"id": int(e.get("id", 0)), "name": _clean_name(str(e.get("name", "")))})
			lobby_data = {}
			var d = m.get("data", {})
			if d is Dictionary:
				for k in d:
					lobby_data[str(k)] = str(d[k])
			p.id = owner_id
			p.name = member_name(owner_id)
			if _room:
				_room.stop()
				_room = null
			lobby_joined.emit(lobby_id, ENTER_SUCCESS)
		"deny":
			if _rejoining:
				_close_peer(p, false)
				_peers.erase(0)
				_give_up_host()
				return
			var id := _joining
			_joining = 0
			_close_peer(p, false)
			_peers.erase(0)
			_join_peer = null
			var code := int(m.get("code", ENTER_ERROR))
			lobby_joined.emit(id, code if code in [ENTER_DOESNT_EXIST, ENTER_NOT_ALLOWED, ENTER_FULL] else ENTER_ERROR)
		"joined":
			var id := int(m.get("id", 0))
			if id > 0 and not _is_member(id):
				members.append({"id": id, "name": _clean_name(str(m.get("name", "")))})
				member_changed.emit(lobby_id, id, STATE_ENTERED)
		"left":
			var id := int(m.get("id", 0))
			_remove_member(id)
			member_changed.emit(lobby_id, id, STATE_KICKED if m.get("kicked", false) else STATE_LEFT)
		"data":
			lobby_data[str(m.get("k", ""))] = str(m.get("v", ""))


func _drop(p: Peer, kicked: bool, why := "") -> void:
	var id := p.id
	var on_purpose := kicked or p.has_meta("bye")
	_close_peer(p, false)
	_peers.erase(p.key)
	if is_host:
		if id == 0 or not _is_member(id):
			return
		if not on_purpose:
			# Keep the seat: the member's game reconnects through the room (mobile networks drop connections).
			print("[buckdroid] lost a member (%s), holding its seat for %d s" % [why, int(REJOIN_GRACE)])
			_held[id] = {"since": _now(), "queue": []}
			return
		print("[buckdroid] member gone (%s)" % why)
		_remove_member(id)
		if kicked:
			_kicked.append(id)
		_broadcast_ctl({"t": "left", "id": id, "kicked": kicked})
		member_changed.emit(lobby_id, id, STATE_KICKED if kicked else STATE_LEFT)
	elif lobby_id != 0:
		if on_purpose or _rejoining:
			print("[buckdroid] the host is gone (%s)" % why)
			_give_up_host()
			return
		# Reconnect through the room (and the local network) to the same host; the game does not notice.
		print("[buckdroid] lost the connection to the host (%s), reconnecting" % why)
		_rejoining = true
		_rejoin_until = _now() + REJOIN_GRACE
		_join_peer = null
		_joining = lobby_id
		_join_started = _now()
		_start_listening()
		_start_room(lobby_id)


## Member: the host could not be reached again. The lobby ends: tell the game every other member left.
func _give_up_host() -> void:
	_rejoining = false
	_outq.clear()
	_joining = 0
	if _room:
		_room.stop()
		_room = null
	for mm in members.duplicate():
		if mm.id != my_id:
			_remove_member(mm.id)
			member_changed.emit(lobby_id, mm.id, STATE_LEFT)
	owner_id = my_id


## Member: back in after a dropped connection. Catch up on members that came or went, then send what was held.
func _finish_rejoin(p: Peer, m: Dictionary) -> void:
	var before := {}
	for mm in members:
		before[mm.id] = mm.name
	members.clear()
	for e in m.get("members", []):
		if e is Dictionary:
			members.append({"id": int(e.get("id", 0)), "name": _clean_name(str(e.get("name", "")))})
	for mm in members:
		if not before.has(mm.id):
			member_changed.emit(lobby_id, mm.id, STATE_ENTERED)
		before.erase(mm.id)
	for gone in before:
		member_changed.emit(lobby_id, gone, STATE_LEFT)
	p.id = owner_id
	p.name = member_name(owner_id)
	_joining = 0
	_rejoining = false
	if _room:
		_room.stop()
		_room = null
	print("[buckdroid] reconnected to the host (%d held messages)" % _outq.size())
	for msg in _outq:
		_send(p, msg)
	_outq.clear()


func kick(id: int) -> void:
	if is_host:
		var p := _peer_by_id(id)
		if p:
			_drop(p, true)


func _close_peer(p: Peer, _rude: bool) -> void:
	if p.tcp:
		p.tcp.disconnect_from_host()
		p.tcp = null
	if p.pc:
		p.pc.close()


func _send(p: Peer, msg: PackedByteArray) -> bool:
	return p.open and p.ch.get_ready_state() == WebRTCDataChannel.STATE_OPEN and p.ch.put_packet(msg) == OK


func _send_ctl(p: Peer, m: Dictionary) -> void:
	var msg := PackedByteArray([MSG_CTL])
	msg.append_array(var_to_bytes(m))
	_send(p, msg)


func _broadcast_ctl(m: Dictionary) -> void:
	for p in _peers.values():
		if p.open and p.id != 0:
			_send_ctl(p, m)


func _peer_by_id(id: int) -> Peer:
	for p in _peers.values():
		if p.id == id:
			return p
	return null


func _is_member(id: int) -> bool:
	for m in members:
		if m.id == id:
			return true
	return false


func _remove_member(id: int) -> bool:
	for i in members.size():
		if members[i].id == id:
			members.remove_at(i)
			return true
	return false


func _toast(text: String) -> void:
	var t := get_node_or_null(^"/root/BuckdroidToast")
	if t and t.has_method("show_text"):
		t.show_text(text, 5.0)


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

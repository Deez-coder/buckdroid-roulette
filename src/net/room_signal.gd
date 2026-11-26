extends RefCounted
## RoomSignal - finds the other players of a room over the internet, through public meeting points, without them
## being able to read anything. Original code, part of Buckdroid Roulette (GPL-3.0-or-later). See docs/MULTIPLAYER.md.
##
## The meeting points are public MQTT brokers, reached over secure WebSockets (wss), several at once: a message goes
## through all of them and duplicates are dropped, so one broker being down or slow does not matter. One of them is on
## port 443 (the normal web port): some mobile and public networks block the others' ports (8084, 8884, 8081).
##
## What a broker sees: a topic that is a hash of the room code (never the code), and messages it cannot read or forge.
##   key material  K = SHA-256 iterated 20000 times over "buckdroid-room-v1|<code>" (slows down guessing codes from
##                 topics seen on a broker)
##   topic         bdroulette/v1/<first 40 hex digits of SHA-256(K | "topic")>
##   message       HMAC-SHA-256(mac key, IV | ciphertext) | IV | AES-256-CBC(enc key, JSON), keys SHA-256(K | "enc"/"mac")
## The JSON carries the sender's session ID, the receiver's (or "" for everyone), a type, a time stamp and a random
## nonce; messages older than 2 minutes or seen before are dropped (no replays).
##
## Only the WebRTC offers, answers and connection candidates travel this way; the game itself then runs over the direct
## WebRTC connection, which is encrypted on its own (DTLS), and whose certificate fingerprints come from these
## authenticated messages, so nobody without the code can sit in the middle.

signal message(from: String, msg: Dictionary)

const BROKERS := [
	"wss://broker.emqx.io:8084/mqtt",
	"wss://broker.hivemq.com:8884/mqtt",
	"wss://test.mosquitto.org:8081/mqtt",
	"wss://public.cloud.shiftr.io:443#public:public",   # "#user:password": the broker's shared public login
]
const KDF_ROUNDS := 20000
const MAX_AGE := 120.0
const MAX_MESSAGE := 16 * 1024
const KEEPALIVE := 30

var session_id := ""
var topic := ""
var _enc_key: PackedByteArray
var _mac_key: PackedByteArray
var _conns: Array = []            # [{ws, state, buf, last_ping}]
var _seen := {}                   # nonce -> time
var _crypto := Crypto.new()


func _init(code: String) -> void:
	session_id = _crypto.generate_random_bytes(8).hex_encode()
	var base := ("buckdroid-room-v1|" + code).to_utf8_buffer()
	var k := _sha256(base)
	for i in KDF_ROUNDS:
		var b := k.duplicate()
		b.append_array(base)
		k = _sha256(b)
	topic = "bdroulette/v1/" + _sha256(_join(k, "topic".to_utf8_buffer())).hex_encode().substr(0, 40)
	_enc_key = _sha256(_join(k, "enc".to_utf8_buffer()))
	_mac_key = _sha256(_join(k, "mac".to_utf8_buffer()))


func start(brokers: Array = BROKERS) -> void:
	for url in brokers:
		var c := {"state": 0, "buf": PackedByteArray(), "last_ping": 0.0, "url": url, "v4": false, "fails": 0,
				"retry_at": 0.0, "last_rx": Time.get_ticks_msec() / 1000.0}
		c.ws = _open_ws(url, "")
		c.started = Time.get_ticks_msec() / 1000.0
		_conns.append(c)


## Opens a WebSocket; with an IPv4 address the URL's host is replaced and the certificate still checked against the name
## (some networks resolve brokers to IPv6 addresses they cannot reach, and the engine does not fall back by itself).
func _open_ws(url: String, ipv4: String) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	ws.supported_protocols = PackedStringArray(["mqtt"])
	ws.inbound_buffer_size = 256 * 1024
	var host := url.get_slice("//", 1).get_slice("/", 0).get_slice(":", 0)
	var tls := TLSOptions.client() if ipv4 == "" else TLSOptions.client(null, host)
	url = url.get_slice("#", 0)
	ws.connect_to_url(url if ipv4 == "" else url.replace("//" + host, "//" + ipv4), tls)
	return ws


func stop() -> void:
	for c in _conns:
		c.ws.close()
		if c.get("rid", -1) >= 0:
			IP.erase_resolve_item(c.rid)
	_conns.clear()


func connected_count() -> int:
	var n := 0
	for c in _conns:
		if c.state == 2:
			n += 1
	return n


## Sends to one session ID, or to everyone in the room with to = "".
func send(to: String, msg: Dictionary) -> void:
	msg = msg.duplicate()
	msg["from"] = session_id
	msg["to"] = to
	msg["ts"] = Time.get_unix_time_from_system()
	msg["n"] = _crypto.generate_random_bytes(12).hex_encode()
	var packet := _seal(JSON.stringify(msg).to_utf8_buffer())
	var pub := _publish_packet(topic, packet)
	for c in _conns:
		if c.state == 2:
			c.ws.put_packet(pub)


func poll() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for c in _conns:
		if c.state == -1:
			# Waiting to reconnect (the game was in the background, the network changed, the broker dropped us...).
			if now >= c.retry_at:
				var ip := ""
				if c.v4:
					# Looked up in the background: a blocking lookup froze the game for seconds at a time on networks
					# where the lookup hangs (tester report, 1.0.2: black screen while joining).
					if c.get("rid", -1) < 0:
						c.rid = IP.resolve_hostname_queue_item(_host(c.url), IP.TYPE_IPV4)
						c.rid_at = now
						continue
					var rs := IP.get_resolve_item_status(c.rid)
					if rs == IP.RESOLVER_STATUS_WAITING and now - c.rid_at < 8.0:
						continue
					if rs == IP.RESOLVER_STATUS_DONE:
						ip = IP.get_resolve_item_address(c.rid)
					IP.erase_resolve_item(c.rid)
					c.rid = -1
				c.ws = _open_ws(c.url, ip)
				c.state = 0
				c.started = now
				c.last_rx = now
				c.buf = PackedByteArray()
			continue
		var ws: WebSocketPeer = c.ws
		ws.poll()
		var st := ws.get_ready_state()
		var failed := false
		if st == WebSocketPeer.STATE_OPEN:
			if c.state == 0:
				ws.put_packet(_connect_packet(c.url))
				c.state = 1
				c.last_ping = now
				c.last_rx = now
			while ws.get_available_packet_count() > 0:
				c.buf.append_array(ws.get_packet())
				c.last_rx = now
				if c.buf.size() > 512 * 1024:
					c.buf = PackedByteArray()
			_parse(c)
			if c.state == 2 and now - c.last_ping > KEEPALIVE * 0.5:
				c.last_ping = now
				ws.put_packet(PackedByteArray([0xC0, 0x00]))   # PINGREQ
			# no answer to pings, or the broker never accepted us: the connection is dead even if the socket looks open
			failed = now - c.last_rx > KEEPALIVE * 1.5 or (c.state == 1 and now - c.started > 10.0)
		elif st == WebSocketPeer.STATE_CLOSED or (st == WebSocketPeer.STATE_CONNECTING and now - c.started > 10.0):
			# 10 s: secure connections to far-away brokers on slow mobile networks take several seconds; with 5 s even a
			# PC on home internet gave up on two brokers before they answered.
			failed = true
		if failed:
			ws.close()
			c.fails += 1
			if c.fails <= 3 or c.state == 2:
				print("[buckdroid] room: %s %s (try %d)" % [_host(c.url), "lost" if c.state == 2 else "unreachable", c.fails])
			# Alternate between the normal address and IPv4 (some networks resolve to IPv6 they cannot reach), and
			# wait a little longer after each failure (2 s up to 20 s).
			c.v4 = not c.v4
			c.state = -1
			c.retry_at = now + minf(20.0, 2.0 * pow(2.0, mini(c.fails - 1, 4)))
	var old := []
	for n in _seen:
		if now - _seen[n] > MAX_AGE * 2:
			old.append(n)
	for n in old:
		_seen.erase(n)


static func _host(url: String) -> String:
	return url.get_slice("#", 0).get_slice("//", 1).get_slice("/", 0).get_slice(":", 0)


# --- MQTT 3.1.1, the few packets needed --------------------------------------------------------------------------------
func _connect_packet(url: String) -> PackedByteArray:
	var login := url.get_slice("#", 1) if "#" in url else ""
	var v := PackedByteArray()
	v.append_array(_mqtt_str("MQTT"))
	var flags := 0x02 | (0xC0 if login != "" else 0)                          # clean session (+ user name, password)
	v.append_array(PackedByteArray([4, flags, KEEPALIVE >> 8, KEEPALIVE & 0xFF]))   # level 4
	v.append_array(_mqtt_str("bd" + _crypto.generate_random_bytes(10).hex_encode()))
	if login != "":
		v.append_array(_mqtt_str(login.get_slice(":", 0)))
		v.append_array(_mqtt_str(login.get_slice(":", 1)))
	return _fixed(0x10, v)


func _subscribe_packet() -> PackedByteArray:
	var v := PackedByteArray([0, 1])
	v.append_array(_mqtt_str(topic))
	v.append(0)                                         # QoS 0
	return _fixed(0x82, v)


func _publish_packet(t: String, payload: PackedByteArray) -> PackedByteArray:
	var v := _mqtt_str(t)
	v.append_array(payload)
	return _fixed(0x30, v)


func _parse(c: Dictionary) -> void:
	var b: PackedByteArray = c.buf
	while b.size() >= 2:
		var mult := 1
		var length := 0
		var i := 1
		var done := false
		while i < b.size() and i <= 4:
			var d := b[i]
			length += (d & 0x7F) * mult
			mult *= 128
			i += 1
			if d & 0x80 == 0:
				done = true
				break
		if not done or b.size() < i + length:
			break
		var first := b[0]
		var kind := first >> 4
		var body := b.slice(i, i + length)
		b = b.slice(i + length)
		match kind:
			2:   # CONNACK
				if body.size() >= 2 and body[1] == 0:
					c.ws.put_packet(_subscribe_packet())
			9:   # SUBACK
				c.state = 2
				c.fails = 0
				print("[buckdroid] room: %s connected" % _host(c.url))
			3:   # PUBLISH
				if body.size() < 2:
					continue
				var tl := (body[0] << 8) | body[1]
				var off := 2 + tl
				if (first >> 1) & 3 > 0:                  # QoS 1/2 carry a packet ID
					off += 2
				if body.size() < off:
					continue
				if body.slice(2, 2 + tl).get_string_from_utf8() == topic:
					_receive(body.slice(off))
	c.buf = b


func _receive(packet: PackedByteArray) -> void:
	if packet.size() > MAX_MESSAGE or packet.size() < 32 + 16 + 16:
		return
	var plain := _open(packet)
	if plain.is_empty():
		return
	var m = JSON.parse_string(plain.get_string_from_utf8())
	if not (m is Dictionary):
		return
	var from := str(m.get("from", ""))
	var to := str(m.get("to", ""))
	var nonce := str(m.get("n", ""))
	if from == "" or from == session_id or nonce == "" or _seen.has(nonce):
		return
	if absf(Time.get_unix_time_from_system() - float(m.get("ts", 0))) > MAX_AGE:
		return
	if to != "" and to != session_id:
		return
	_seen[nonce] = Time.get_ticks_msec() / 1000.0
	message.emit(from, m)


static func _mqtt_str(s: String) -> PackedByteArray:
	var u := s.to_utf8_buffer()
	var out := PackedByteArray([u.size() >> 8, u.size() & 0xFF])
	out.append_array(u)
	return out


static func _fixed(first: int, v: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([first])
	var n := v.size()
	while true:
		var d := n % 128
		n /= 128
		if n > 0:
			d |= 0x80
		out.append(d)
		if n == 0:
			break
	out.append_array(v)
	return out


# --- encryption -------------------------------------------------------------------------------------------------------
func _seal(plain: PackedByteArray) -> PackedByteArray:
	var pad := 16 - plain.size() % 16
	for i in pad:
		plain.append(pad)                                 # PKCS#7
	var iv := _crypto.generate_random_bytes(16)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, _enc_key, iv)
	var ct := aes.update(plain)
	aes.finish()
	var body := _join(iv, ct)
	return _join(_crypto.hmac_digest(HashingContext.HASH_SHA256, _mac_key, body), body)


func _open(packet: PackedByteArray) -> PackedByteArray:
	var mac := packet.slice(0, 32)
	var body := packet.slice(32)
	if (body.size() - 16) % 16 != 0:
		return PackedByteArray()
	if not _crypto.constant_time_compare(mac, _crypto.hmac_digest(HashingContext.HASH_SHA256, _mac_key, body)):
		return PackedByteArray()
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, _enc_key, body.slice(0, 16))
	var plain := aes.update(body.slice(16))
	aes.finish()
	if plain.is_empty():
		return plain
	var pad := plain[plain.size() - 1]
	if pad < 1 or pad > 16 or pad > plain.size():
		return PackedByteArray()
	return plain.slice(0, plain.size() - pad)


static func _sha256(b: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(b)
	return h.finish()


static func _join(a: PackedByteArray, b: PackedByteArray) -> PackedByteArray:
	var out := a.duplicate()
	out.append_array(b)
	return out

## Buckdroid Roulette converter - edits Godot's binary project settings (project.binary, "ECFG"). Original code,
## GPL-3.0-or-later. GDScript port of tools/ecfg.py: untouched values keep their raw bytes; new values may be bool,
## int, float or String. Settings apply in file order, which also decides autoload order.
extends RefCounted

const T_BOOL := 1
const T_INT := 2
const T_FLOAT := 3
const T_STRING := 4

var items: Array = []   # [key: String, raw: PackedByteArray]
var error := ""


## Loads project.binary bytes; check error afterwards.
func load_bytes(data: PackedByteArray) -> void:
	var e = self
	if data.size() < 8 or data.slice(0, 4).get_string_from_ascii() != "ECFG":
		error = "not a project.binary"
		return
	var n := data.decode_u32(4)
	var p := 8
	for i in n:
		var kl := data.decode_u32(p)
		var key := data.slice(p + 4, p + 4 + kl).get_string_from_utf8()
		p += 4 + kl
		var vl := data.decode_u32(p)
		var raw := data.slice(p + 4, p + 4 + vl)
		p += 4 + vl
		e.items.append([key, raw])


static func encode(v) -> PackedByteArray:
	var b := PackedByteArray()
	match typeof(v):
		TYPE_BOOL:
			b.resize(8)
			b.encode_u32(0, T_BOOL)
			b.encode_u32(4, 1 if v else 0)
		TYPE_INT:
			if v >= -2147483648 and v < 2147483648:
				b.resize(8)
				b.encode_u32(0, T_INT)
				b.encode_s32(4, v)
			else:
				b.resize(12)
				b.encode_u32(0, T_INT | (1 << 16))
				b.encode_s64(4, v)
		TYPE_FLOAT:
			b.resize(12)
			b.encode_u32(0, T_FLOAT | (1 << 16))
			b.encode_double(4, v)
		_:
			var s: PackedByteArray = str(v).to_utf8_buffer()
			var pad := posmod(-s.size(), 4)
			b.resize(8)
			b.encode_u32(0, T_STRING)
			b.encode_u32(4, s.size())
			b.append_array(s)
			var z := PackedByteArray()
			z.resize(pad)
			b.append_array(z)
	return b


func keys() -> PackedStringArray:
	var k := PackedStringArray()
	for it in items:
		k.append(it[0])
	return k


func set_value(key: String, value) -> void:
	var raw := encode(value)
	for it in items:
		if it[0] == key:
			it[1] = raw
			return
	items.append([key, raw])


func remove(key: String) -> void:
	items = items.filter(func(it): return it[0] != key)


func insert_before(before_key: String, key: String, value) -> void:
	remove(key)
	var idx := items.size()
	for i in items.size():
		if items[i][0] == before_key:
			idx = i
			break
	items.insert(idx, [key, encode(value)])


func to_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array("ECFG".to_ascii_buffer())
	var n := PackedByteArray()
	n.resize(4)
	n.encode_u32(0, items.size())
	out.append_array(n)
	for it in items:
		var kb: PackedByteArray = it[0].to_utf8_buffer()
		var l := PackedByteArray()
		l.resize(4)
		l.encode_u32(0, kb.size())
		out.append_array(l)
		out.append_array(kb)
		var raw: PackedByteArray = it[1]
		var l2 := PackedByteArray()
		l2.resize(4)
		l2.encode_u32(0, raw.size())
		out.append_array(l2)
		out.append_array(raw)
	return out

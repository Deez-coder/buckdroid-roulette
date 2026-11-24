## Buckdroid Roulette converter - Godot PCK (pack format 2) reader and writer. Original code, GPL-3.0-or-later.
## GDScript port of tools/gdpck.py; see that file for the format. Reads a standalone .pck or the one embedded at the end
## of the game's .exe, and writes a new pack that copies, replaces and adds entries (streamed in 1 MB chunks).
extends RefCounted

const MAGIC := "GDPC"
const ALIGN := 32
const CHUNK := 1 << 20

var path := ""
var f: FileAccess
var start := 0
var engine := [0, 0, 0]
var file_base := 0
var entries: Array[Dictionary] = []   # {path, offset (absolute), size, md5 (PackedByteArray), flags}
var by_path := {}
var error := ""


## Opens a standalone .pck or a game .exe with an embedded pack; check error afterwards.
func open_path(p: String) -> void:
	path = p
	f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		error = "cannot open the file"
		return
	start = _find_start()
	if start < 0:
		error = "neither a .pck nor an executable with an embedded game pack"
		return
	f.seek(start)
	if f.get_buffer(4).get_string_from_ascii() != MAGIC:
		error = "no game pack found"
		return
	var pack_version := f.get_32()
	engine = [f.get_32(), f.get_32(), f.get_32()]
	if pack_version != 2:
		error = "pack format %d is not supported" % pack_version
		return
	var pack_flags := f.get_32()
	var fb := f.get_64()
	if pack_flags & 1:
		error = "the game pack directory is encrypted"
		return
	f.get_buffer(64)
	file_base = fb if (start == 0 or fb > start) else start + fb
	var count := f.get_32()
	for i in count:
		var n := f.get_32()
		var raw := f.get_buffer(n)
		var zero := raw.find(0)
		var ep := (raw.slice(0, zero) if zero >= 0 else raw).get_string_from_utf8()
		var off := f.get_64()
		var size := f.get_64()
		var md5 := f.get_buffer(16)
		var fl := f.get_32()
		var e := {"path": ep, "offset": file_base + off, "size": size, "md5": md5, "flags": fl}
		entries.append(e)
		by_path[ep] = e


func _find_start() -> int:
	f.seek(0)
	if f.get_buffer(4).get_string_from_ascii() == MAGIC:
		return 0
	var length := f.get_length()
	f.seek(length - 12)
	var size := f.get_64()
	if f.get_buffer(4).get_string_from_ascii() != MAGIC:
		return -1
	return length - 12 - size


func read(p: String) -> PackedByteArray:
	var e: Dictionary = by_path[p]
	f.seek(e.offset)
	return f.get_buffer(e.size)


func has(p: String) -> bool:
	return by_path.has(p)


## Writes a format-2 pack. items: Array of {path, size, data (PackedByteArray)} or {path, size, entry (from a source
## pack)}. progress: Callable(done: int, total: int) or an empty Callable. Returns "" or an error message.
static func write(out_path: String, engine_version: Array, items: Array, sources: Dictionary, progress := Callable()) -> String:
	var dir_size := 4
	for it in items:
		var b: int = it.path.to_utf8_buffer().size()
		dir_size += 4 + b + posmod(-b, 4) + 8 + 8 + 16 + 4
	var header := 20 + 12 + 64
	var fb := header + dir_size
	fb += posmod(-fb, ALIGN)
	var offsets := []
	var cur := 0
	for it in items:
		offsets.append(cur)
		cur += it.size + posmod(-it.size, ALIGN)
	var tmp := out_path + ".part"
	var out := FileAccess.open(tmp, FileAccess.WRITE)
	if out == null:
		return "cannot write %s" % tmp
	var zeros := PackedByteArray()
	zeros.resize(fb)
	out.store_buffer(zeros)
	var md5s := []
	for i in items.size():
		var it: Dictionary = items[i]
		out.seek(fb + offsets[i])
		var h := HashingContext.new()
		h.start(HashingContext.HASH_MD5)
		if it.has("data"):
			out.store_buffer(it.data)
			h.update(it.data)
		else:
			var src = sources[it.source]
			src.f.seek(it.entry.offset)
			var left: int = it.entry.size
			while left > 0:
				var chunk: PackedByteArray = src.f.get_buffer(mini(left, CHUNK))
				out.store_buffer(chunk)
				h.update(chunk)
				left -= chunk.size()
		md5s.append(h.finish())
		var pad := posmod(-it.size, ALIGN)
		if pad > 0:
			var p := PackedByteArray()
			p.resize(pad)
			out.store_buffer(p)
		if progress.is_valid():
			progress.call(i + 1, items.size())
	out.seek(0)
	out.store_buffer(MAGIC.to_ascii_buffer())
	out.store_32(2)
	for v in engine_version:
		out.store_32(v)
	out.store_32(0)
	out.store_64(fb)
	var reserved := PackedByteArray()
	reserved.resize(64)
	out.store_buffer(reserved)
	out.store_32(items.size())
	for i in items.size():
		var b: PackedByteArray = items[i].path.to_utf8_buffer()
		var pad := posmod(-b.size(), 4)
		out.store_32(b.size() + pad)
		out.store_buffer(b)
		if pad > 0:
			var z := PackedByteArray()
			z.resize(pad)
			out.store_buffer(z)
		out.store_64(offsets[i])
		out.store_64(items[i].size)
		out.store_buffer(md5s[i])
		out.store_32(0)
	out.close()
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(out_path)
	var err := DirAccess.rename_absolute(tmp, out_path)
	return "" if err == OK else "cannot rename %s (%d)" % [tmp, err]

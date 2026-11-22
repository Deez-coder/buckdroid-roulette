## transcode_etc2 - original code, part of Buckdroid Roulette. PC reference for the installer's texture step.
##
## Converts the game's desktop-only VRAM textures (S3TC/BPTC/RGTC inside .ctex files) to ETC2, which every
## Vulkan / OpenGL ES 3 phone supports. Run with the official Godot 4.1.1 *editor* binary (it contains the etcpak
## compressor), headless, with the game's PCK mounted:
##
##   godot --headless --main-pack <patched.pck> -s tools/transcode_etc2.gd -- --out=<folder> [--max-size=2048] [--only=<substring>]
##
## For every texture whose .import remap has a path.s3tc entry it writes <out>/<same res path with .etc2.ctex>.
## build_patched_pck.py then adds those files and points the remaps' path.etc2 at them. Output never leaves the
## developer's machine.
##
## .ctex layout (Godot 4.1, CompressedTexture2D): "GST2", u32 version, u32 width, u32 height, u32 flags,
## i32 mipmap_limit, 3 x u32 reserved (36 bytes), then u32 data_format (0 = raw image), u16 width, u16 height,
## u32 mipmap count, u32 Image.Format, raw data for all mip levels.
extends SceneTree

const HEADER_SIZE := 36
const DATA_FORMAT_IMAGE := 0

var out_dir := ""
var max_size := 0
var only := ""


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--max-size="):
			max_size = int(arg.trim_prefix("--max-size="))
		elif arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	if out_dir.is_empty():
		printerr("usage: -s transcode_etc2.gd -- --out=<folder>")
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var sources := _collect_s3tc_paths("res://")
	print("textures to convert: ", sources.size())
	var done := 0
	var failed := 0
	var bytes_in := 0
	var bytes_out := 0
	for src in sources:
		if not only.is_empty() and not src.contains(only):
			continue
		var r := _convert(src)
		if r.is_empty():
			failed += 1
			continue
		done += 1
		bytes_in += r[0]
		bytes_out += r[1]
		if done % 50 == 0:
			print("  %d/%d  %.0f s" % [done, sources.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	print("converted %d, failed %d, %.0f MB -> %.0f MB in %.1f s" % [done, failed, bytes_in / 1e6, bytes_out / 1e6,
			(Time.get_ticks_msec() - t0) / 1000.0])
	quit(0 if failed == 0 else 2)


## Every path.s3tc target named by a .import remap anywhere in the pack.
func _collect_s3tc_paths(dir: String) -> PackedStringArray:
	var found := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return found
	d.include_hidden = true
	for sub in d.get_directories():
		if sub == ".godot":
			continue
		found.append_array(_collect_s3tc_paths(dir.path_join(sub)))
	for f in d.get_files():
		if not f.ends_with(".import"):
			continue
		var text := FileAccess.get_file_as_string(dir.path_join(f))
		for line in text.split("\n"):
			if line.begins_with("path.s3tc="):
				found.append(line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\""))
	return found


## Returns [input bytes, output bytes], or [] on failure.
func _convert(src: String) -> Array:
	var data := FileAccess.get_file_as_bytes(src)
	if data.size() < HEADER_SIZE + 16 or data.slice(0, 4).get_string_from_ascii() != "GST2":
		printerr("not a ctex: ", src)
		return []
	var p := HEADER_SIZE
	var data_format := data.decode_u32(p)
	if data_format != DATA_FORMAT_IMAGE:
		printerr("not a raw VRAM image (data format %d): %s" % [data_format, src])
		return []
	var w := data.decode_u16(p + 4)
	var h := data.decode_u16(p + 6)
	var mipmaps := data.decode_u32(p + 8)
	var fmt: Image.Format = data.decode_u32(p + 12)
	var img := Image.create_from_data(w, h, mipmaps > 0, fmt, data.slice(p + 16))
	if img == null or img.is_empty():
		printerr("could not read image: ", src)
		return []
	var source := Image.COMPRESS_SOURCE_GENERIC
	if fmt == Image.FORMAT_DXT5_RA_AS_RG:
		source = Image.COMPRESS_SOURCE_NORMAL
	img.decompress()
	if fmt == Image.FORMAT_DXT5_RA_AS_RG and img.get_format() == Image.FORMAT_RGBA8:
		# Desktop normal maps store X in red and Y in alpha ("RA as RG"). If decompression left that layout as
		# RGBA, rebuild a plain RG normal so the ETC2 normal path can re-pack it its own way.
		img = _ra_to_rg(img)
	if max_size > 0 and maxi(w, h) > max_size:
		var s := float(max_size) / maxi(w, h)
		img.resize(maxi(1, int(w * s)), maxi(1, int(h * s)), Image.INTERPOLATE_LANCZOS)
	if mipmaps > 0 and not img.has_mipmaps():
		img.generate_mipmaps(source == Image.COMPRESS_SOURCE_NORMAL)
	var err := img.compress(Image.COMPRESS_ETC2, source)
	if err != OK:
		printerr("ETC2 compression failed (%d): %s" % [err, src])
		return []
	var out := PackedByteArray()
	out.append_array(data.slice(0, HEADER_SIZE))
	out.encode_u32(8, img.get_width())    # header width / height follow the (possibly resized) image
	out.encode_u32(12, img.get_height())
	var sect := PackedByteArray()
	sect.resize(16)
	sect.encode_u32(0, DATA_FORMAT_IMAGE)
	sect.encode_u16(4, img.get_width())
	sect.encode_u16(6, img.get_height())
	# Mip levels below the base image (Godot goes down to 1x1). The loader only checks whether this is non-zero.
	var mip_count := 0
	if img.has_mipmaps():
		mip_count = int(floor(log(maxi(img.get_width(), img.get_height())) / log(2.0)))
	sect.encode_u32(8, mip_count)
	sect.encode_u32(12, img.get_format())
	out.append_array(sect)
	out.append_array(img.get_data())
	var dst := out_dir.path_join(etc2_name(src).trim_prefix("res://"))
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		printerr("cannot write ", dst)
		return []
	f.store_buffer(out)
	return [data.size(), out.size()]


static func etc2_name(s3tc_path: String) -> String:
	return s3tc_path.trim_suffix(".s3tc.ctex") + ".etc2.ctex"


func _ra_to_rg(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var bytes := img.get_data()
	for i in range(0, bytes.size(), 4):
		bytes[i + 1] = bytes[i + 3]   # Y from alpha into green
		bytes[i + 2] = 0
		bytes[i + 3] = 255
	return Image.create_from_data(img.get_width(), img.get_height(), img.has_mipmaps(), Image.FORMAT_RGBA8, bytes)

## Buckdroid Roulette converter - texture conversion. Original code, GPL-3.0-or-later. From tools/transcode_etc2.gd.
##
## The game's textures are desktop-only VRAM formats (S3TC/BPTC/RGTC inside Godot .ctex files). Phones need ETC2.
## to_etc2() takes the bytes of one .ctex and returns an ETC2 .ctex with the same header, or an empty array on failure.
## Pure function of its input, so several textures can be converted on worker threads at once.
##
## .ctex layout: "GST2", u32 version, u32 width, u32 height, u32 flags, i32 mipmap_limit, 3 x u32 reserved (36 bytes),
## then u32 data_format (0 = raw image), u16 width, u16 height, u32 mipmap count, u32 Image.Format, data for all mips.
extends RefCounted

const HEADER_SIZE := 36
const DATA_FORMAT_IMAGE := 0


static func to_etc2(data: PackedByteArray) -> PackedByteArray:
	if data.size() < HEADER_SIZE + 16 or data.slice(0, 4).get_string_from_ascii() != "GST2":
		return PackedByteArray()
	var p := HEADER_SIZE
	if data.decode_u32(p) != DATA_FORMAT_IMAGE:
		return PackedByteArray()
	var w := data.decode_u16(p + 4)
	var h := data.decode_u16(p + 6)
	var mipmaps := data.decode_u32(p + 8)
	var fmt: Image.Format = data.decode_u32(p + 12)
	var img := Image.create_from_data(w, h, mipmaps > 0, fmt, data.slice(p + 16))
	if img == null or img.is_empty():
		return PackedByteArray()
	var source := Image.COMPRESS_SOURCE_GENERIC
	if fmt == Image.FORMAT_DXT5_RA_AS_RG:
		source = Image.COMPRESS_SOURCE_NORMAL
	img.decompress()
	if fmt == Image.FORMAT_DXT5_RA_AS_RG and img.get_format() == Image.FORMAT_RGBA8:
		img = _ra_to_rg(img)
	if mipmaps > 0 and not img.has_mipmaps():
		img.generate_mipmaps(source == Image.COMPRESS_SOURCE_NORMAL)
	if img.compress(Image.COMPRESS_ETC2, source) != OK:
		return PackedByteArray()
	var out := PackedByteArray()
	out.append_array(data.slice(0, HEADER_SIZE))
	out.encode_u32(8, img.get_width())
	out.encode_u32(12, img.get_height())
	var sect := PackedByteArray()
	sect.resize(16)
	sect.encode_u32(0, DATA_FORMAT_IMAGE)
	sect.encode_u16(4, img.get_width())
	sect.encode_u16(6, img.get_height())
	var mip_count := 0
	if img.has_mipmaps():
		mip_count = int(floor(log(maxi(img.get_width(), img.get_height())) / log(2.0)))
	sect.encode_u32(8, mip_count)
	sect.encode_u32(12, img.get_format())
	out.append_array(sect)
	out.append_array(img.get_data())
	return out


static func _ra_to_rg(img: Image) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var bytes := img.get_data()
	for i in range(0, bytes.size(), 4):
		bytes[i + 1] = bytes[i + 3]
		bytes[i + 2] = 0
		bytes[i + 3] = 255
	return Image.create_from_data(img.get_width(), img.get_height(), img.has_mipmaps(), Image.FORMAT_RGBA8, bytes)


## The .import remap's path.s3tc target, or "".
static func s3tc_target(import_text: String) -> String:
	for line in import_text.split("\n"):
		if line.begins_with("path.s3tc="):
			return line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""


## Adds path.etc2=<target> right after the path.s3tc line (replacing an existing path.etc2 line).
static func add_etc2_remap(import_text: String, target: String) -> String:
	var lines := import_text.split("\n")
	var out := PackedStringArray()
	for line in lines:
		if line.begins_with("path.etc2="):
			continue
		out.append(line)
		if line.begins_with("path.s3tc="):
			out.append("path.etc2=\"%s\"" % target)
	return "\n".join(out)

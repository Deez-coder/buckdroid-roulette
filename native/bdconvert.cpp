/* bdconvert - Buckdroid Roulette's texture converter for the launcher. Original code, GPL-3.0-or-later.
 *
 * Converts one Godot .ctex texture with desktop compression (S3TC: DXT1, DXT5, DXT5_RA_AS_RG) into the same texture
 * with ETC2 compression, which every phone GPU supports. It reproduces what Godot 4.6 does when it runs
 * converter/textures.gd (Image.decompress, then Image.compress(COMPRESS_ETC2)), following Godot's own code:
 * modules/bcdec/image_decompress_bcdec.cpp, core/io/image.cpp (mipmap layout, detect_used_channels) and
 * modules/etcpak/image_compress_etcpak.cpp (Godot Engine, MIT license, (c) Godot Engine contributors), with the
 * decoder bcdec (MIT / Unlicense, Sergii Kudlai) and the encoder etcpak (BSD-3-Clause, Bartosz Taudul).
 *
 * Built twice: into libbdconvert.so for the launcher (JNI entry below), and into a PC test tool (BDCONVERT_CLI).
 */
#include <cstdint>
#include <cstring>
#include <vector>

#define BCDEC_IMPLEMENTATION
#include "bcdec.h"
#include "ProcessRGB.hpp"

namespace {

enum Format : uint32_t {   // Godot's Image::Format values used here
	F_RGBA8 = 5,
	F_DXT1 = 17,
	F_DXT5 = 19,
	F_ETC2_R11 = 26,
	F_ETC2_RG11 = 28,
	F_ETC2_RGB8 = 30,
	F_ETC2_RGBA8 = 31,
	F_DXT5_RA_AS_RG = 34,
};

const size_t HEADER = 36;   // "GST2" + version, width, height, flags, mipmap limit, 3 reserved

/* Bytes per pixel as (pixel size, right shift), and the block edge, as in Image::get_format_pixel_size/_rshift/
 * get_format_block_size. */
void format_layout(uint32_t f, int &pixsize, int &shift, int &block) {
	switch (f) {
		case F_RGBA8: pixsize = 4; shift = 0; block = 1; break;
		case F_DXT1: case F_ETC2_R11: case F_ETC2_RGB8: pixsize = 1; shift = 1; block = 4; break;
		default: pixsize = 1; shift = 0; block = 4; break;   // DXT5, DXT5_RA_AS_RG, ETC2_RG11, ETC2_RGBA8
	}
}

/* Image::_get_dst_image_size: offset of mipmap `level` and its size, for a chain that goes down to 1x1. */
int64_t mip_offset(int w, int h, uint32_t f, int level, int &mw, int &mh) {
	int pixsize, shift, block;
	format_layout(f, pixsize, shift, block);
	int64_t ofs = 0;
	for (int i = 0; i < level; i++) {
		int bw = w % block ? w + (block - w % block) : w;
		int bh = h % block ? h + (block - h % block) : h;
		ofs += ((int64_t)bw * bh * pixsize) >> shift;
		w = w > 1 ? w >> 1 : 1;
		h = h > 1 ? h >> 1 : 1;
	}
	mw = w;
	mh = h;
	return ofs;
}

int required_mipmaps(int w, int h) {   // Image::get_image_required_mipmaps (minimum size 1x1)
	int mm = 0;
	while (!(w == 1 && h == 1)) {
		w = w > 1 ? w >> 1 : 1;
		h = h > 1 ? h >> 1 : 1;
		mm++;
	}
	return mm;
}

int64_t data_size(int w, int h, uint32_t f, bool mipmaps) {
	int mw, mh;
	return mip_offset(w, h, f, mipmaps ? required_mipmaps(w, h) + 1 : 1, mw, mh);
}

/* modules/bcdec: one mipmap, with the "safe" path for sizes that are not multiples of 4. */
template <void (*DEC)(const void *, void *, int), int BLOCK>
void decompress_mip(int width, int height, const uint8_t *src, uint8_t *dst) {
	const int pixel = 4;
	if ((width & 3) == 0 && (height & 3) == 0) {
		size_t s = 0, d = 0;
		for (int y = 0; y < height; y += 4) {
			for (int x = 0; x < width; x += 4) {
				DEC(&src[s], &dst[d], width * pixel);
				s += BLOCK;
				d += 4 * pixel;
			}
			d += 3 * (size_t)width * pixel;
		}
		return;
	}
	uint8_t tmp[4 * 4 * pixel];
	const int wd = width - (width & ~3), hd = height - (height & ~3);
	const int wb = (width & ~3) / 4, hb = (height & ~3) / 4;
	const int pitch = width * pixel, bpitch = 4 * pixel, odd = wd * pixel;
	size_t s = 0, d = 0;
	for (int y = 0; y < hb; y++) {
		for (int x = 0; x < wb; x++) {
			DEC(&src[s], &dst[d], pitch);
			s += BLOCK;
			d += bpitch;
		}
		if (wd > 0) {
			DEC(&src[s], tmp, bpitch);
			for (int i = 0; i < 4; i++) memcpy(&dst[d + i * pitch], &tmp[i * bpitch], odd);
			s += BLOCK;
			d += odd;
		}
		d += 3 * (size_t)pitch;
	}
	if (hd > 0) {
		for (int x = 0; x < wb; x++) {
			DEC(&src[s], tmp, bpitch);
			for (int i = 0; i < hd; i++) memcpy(&dst[d + i * pitch], &tmp[i * bpitch], bpitch);
			s += BLOCK;
			d += bpitch;
		}
		if (wd > 0) {
			DEC(&src[s], tmp, bpitch);
			for (int i = 0; i < hd; i++) memcpy(&dst[d + i * pitch], &tmp[i * bpitch], odd);
		}
	}
}

enum Used { L, LA, R, RG, RGB, RGBA };

/* Image::detect_used_channels on the base level of an RGBA8 image (GENERIC source). */
Used detect_used(const uint8_t *px, int w, int h) {
	bool r = false, g = false, b = false, a = false, c = false;
	const int64_t n = (int64_t)w * h;
	for (int64_t i = 0; i < n; i++) {
		const uint8_t *p = px + i * 4;
		if (!r && p[0] / 255.0f > 0.001f) r = true;
		if (!g && p[1] / 255.0f > 0.001f) g = true;
		if (!b && p[2] / 255.0f > 0.001f) b = true;
		if (!a && p[3] / 255.0f < 0.999f) a = true;
		if (p[0] != p[2] || p[0] != p[1] || p[2] != p[1]) c = true;
		if (r && g && b && c && a) break;
	}
	if (!c) return a ? LA : L;
	if (a) return RGBA;
	if (b) return RGB;
	if (g) return RG;
	return R;
}

void put32(std::vector<uint8_t> &v, size_t at, uint32_t x) { memcpy(&v[at], &x, 4); }
void put16(std::vector<uint8_t> &v, size_t at, uint16_t x) { memcpy(&v[at], &x, 2); }
uint32_t get32(const uint8_t *p) { uint32_t x; memcpy(&x, p, 4); return x; }
uint16_t get16(const uint8_t *p) { uint16_t x; memcpy(&x, p, 2); return x; }

} // namespace

/* Returns true and fills `out` with an ETC2 .ctex, or false if the input is not a supported S3TC .ctex. */
bool bd_ctex_to_etc2(const uint8_t *in, size_t n, std::vector<uint8_t> &out) {
	if (n < HEADER + 16 || memcmp(in, "GST2", 4) != 0) return false;
	const uint8_t *sect = in + HEADER;
	if (get32(sect) != 0) return false;   // raw VRAM image data only
	const int w = get16(sect + 4), h = get16(sect + 6);
	const bool mipmaps = get32(sect + 8) > 0;
	const uint32_t fmt = get32(sect + 12);
	const uint8_t *src = sect + 16;
	if (fmt != F_DXT1 && fmt != F_DXT5 && fmt != F_DXT5_RA_AS_RG) return false;
	if (n - HEADER - 16 < (size_t)data_size(w, h, fmt, mipmaps)) return false;

	// Decompress every level to RGBA8.
	const int mm = mipmaps ? required_mipmaps(w, h) : 0;
	std::vector<uint8_t> rgba((size_t)data_size(w, h, F_RGBA8, mipmaps));
	for (int i = 0; i <= mm; i++) {
		int mw, mh;
		int64_t so = mip_offset(w, h, fmt, i, mw, mh);
		int64_t d0 = mip_offset(w, h, F_RGBA8, i, mw, mh);
		if (fmt == F_DXT1) decompress_mip<bcdec_bc1, BCDEC_BC1_BLOCK_SIZE>(mw, mh, src + so, &rgba[d0]);
		else decompress_mip<bcdec_bc3, BCDEC_BC3_BLOCK_SIZE>(mw, mh, src + so, &rgba[d0]);
	}
	bool normal = fmt == F_DXT5_RA_AS_RG;
	if (normal) {   // Image::convert_ra_rgba8_to_rg
		for (size_t i = 0; i < rgba.size(); i += 4) {
			rgba[i + 1] = rgba[i + 3];
			rgba[i + 2] = 0;
			rgba[i + 3] = 255;
		}
	}

	// Choose the ETC2 flavour (_determine_etc_type).
	Used used = normal ? RG : detect_used(rgba.data(), w, h);
	uint32_t target;
	switch (used) {
		case L: case RGB: target = F_ETC2_RGB8; break;
		case R: target = F_ETC2_R11; break;
		case RG: target = F_ETC2_RG11; break;
		default: target = F_ETC2_RGBA8; break;
	}
	for (size_t i = 0; i < rgba.size(); i += 4) {   // etcpak expects BGRA for ETC formats
		uint8_t t = rgba[i];
		rgba[i] = rgba[i + 2];
		rgba[i + 2] = t;
	}

	int tw = w, th = h;
	if (tw % 4 != 0 || th % 4 != 0) {
		tw = tw <= 2 ? tw : (tw + 3) & ~3;
		th = th <= 2 ? th : (th + 3) & ~3;
	}
	std::vector<uint8_t> dest((size_t)data_size(tw, th, target, mipmaps));
	const int tmm = mipmaps ? required_mipmaps(tw, th) : 0;
	std::vector<uint32_t> padded;
	for (int i = 0; i <= tmm; i++) {
		int dw, dh, sw, sh;
		int64_t dofs = mip_offset(tw, th, target, i, dw, dh);
		if (dofs % 8 != 0) return false;
		dw = (dw + 3) & ~3;
		dh = (dh + 3) & ~3;
		const uint32_t blocks = dw * dh / 16;
		int64_t sofs = mip_offset(w, h, F_RGBA8, i, sw, sh);
		const uint32_t *sp = reinterpret_cast<const uint32_t *>(&rgba[sofs]);
		if (dw != sw || dh != sh) {   // pad to whole blocks by smearing, as Godot does
			padded.assign((size_t)dw * dh, 0);
			int x = 0, y = 0;
			for (y = 0; y < sh; y++) {
				for (x = 0; x < sw; x++) padded[dw * y + x] = sp[sw * y + x];
				for (; x < dw; x++) padded[dw * y + x] = padded[dw * y + x - 1];
			}
			for (; y < dh; y++)
				for (x = 0; x < dw; x++) padded[dw * y + x] = padded[dw * y + x - dw];
			sp = padded.data();
		}
		uint64_t *dp = reinterpret_cast<uint64_t *>(&dest[dofs]);
		switch (target) {
			case F_ETC2_RGB8: CompressEtc2Rgb(sp, dp, blocks, dw, true); break;
			case F_ETC2_RGBA8: CompressEtc2Rgba(sp, dp, blocks, dw, true); break;
			case F_ETC2_R11: CompressEacR(sp, dp, blocks, dw); break;
			default: CompressEacRg(sp, dp, blocks, dw); break;
		}
	}

	// The .ctex: same header (with the size of the compressed image), then the image section.
	out.assign(in, in + HEADER);
	put32(out, 8, tw);
	put32(out, 12, th);
	size_t s = out.size();
	out.resize(s + 16);
	put32(out, s, 0);
	put16(out, s + 4, (uint16_t)tw);
	put16(out, s + 6, (uint16_t)th);
	int mip_count = 0;   // levels below the base (the loader only checks for non-zero), as converter/textures.gd writes
	if (mipmaps) {
		int m = tw > th ? tw : th;
		while (m > 1) { m >>= 1; mip_count++; }
	}
	put32(out, s + 8, mip_count);
	put32(out, s + 12, target);
	out.insert(out.end(), dest.begin(), dest.end());
	return true;
}

#ifdef BDCONVERT_CLI
/* PC test tool: bdconvert <in.ctex> <out.ctex>
 *           or: bdconvert --psnr <s3tc.ctex> <etc2.ctex>   (base level, RGB: PSNR of the ETC2 image against the S3TC one) */
#include <cmath>
#include <cstdio>
#include "DecodeRGB.hpp"
static std::vector<uint8_t> read_file(const char *p) {
	std::vector<uint8_t> v;
	FILE *f = fopen(p, "rb");
	if (!f) return v;
	uint8_t buf[1 << 16];
	for (size_t r; (r = fread(buf, 1, sizeof buf, f)) > 0;) v.insert(v.end(), buf, buf + r);
	fclose(f);
	return v;
}
static int psnr(const char *a, const char *b) {
	std::vector<uint8_t> s = read_file(a), e = read_file(b);
	const uint8_t *ss = s.data() + HEADER, *es = e.data() + HEADER;
	int w = get16(ss + 4), h = get16(ss + 6);
	uint32_t sf = get32(ss + 12), ef = get32(es + 12);
	if (w % 4 || h % 4 || (ef != F_ETC2_RGB8 && ef != F_ETC2_RGBA8) || (sf != F_DXT1 && sf != F_DXT5)) { printf("skip\n"); return 0; }
	std::vector<uint8_t> ref((size_t)w * h * 4), dec((size_t)w * h * 4);
	if (sf == F_DXT1) decompress_mip<bcdec_bc1, BCDEC_BC1_BLOCK_SIZE>(w, h, ss + 16, ref.data());
	else decompress_mip<bcdec_bc3, BCDEC_BC3_BLOCK_SIZE>(w, h, ss + 16, ref.data());
	const uint8_t *ep = es + 16;
	const int bs = ef == F_ETC2_RGB8 ? 8 : 16;
	for (int y = 0; y < h; y += 4)
		for (int x = 0; x < w; x += 4) {
			uint8_t *d = &dec[((size_t)y * w + x) * 4];
			if (ef == F_ETC2_RGB8) DecodeRGBBlock(ep, d, w); else DecodeRGBABlock(ep, d, w);
			ep += bs;
		}
	double se = 0;
	for (size_t i = 0; i < ref.size(); i += 4)
		for (int c = 0; c < 3; c++) { double d = (double)ref[i + c] - dec[i + c]; se += d * d; }
	double mse = se / ((double)w * h * 3);
	printf("%.3f\n", mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99.0);
	return 0;
}
int main(int argc, char **argv) {
	if (argc == 4 && strcmp(argv[1], "--psnr") == 0) return psnr(argv[2], argv[3]);
	if (argc != 3) { fprintf(stderr, "usage: bdconvert in.ctex out.ctex\n"); return 2; }
	FILE *f = fopen(argv[1], "rb");
	if (!f) return 3;
	std::vector<uint8_t> in;
	uint8_t buf[1 << 16];
	for (size_t r; (r = fread(buf, 1, sizeof buf, f)) > 0;) in.insert(in.end(), buf, buf + r);
	fclose(f);
	std::vector<uint8_t> out;
	if (!bd_ctex_to_etc2(in.data(), in.size(), out)) { fprintf(stderr, "not a supported texture\n"); return 1; }
	f = fopen(argv[2], "wb");
	if (!f) return 4;
	fwrite(out.data(), 1, out.size(), f);
	fclose(f);
	return 0;
}
#else
/* JNI: byte[] com.buckdroid.roulette.NativeConvert.ctexToEtc2(byte[] ctex) -> ETC2 .ctex, or null. */
#include <jni.h>
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_buckdroid_roulette_NativeConvert_ctexToEtc2(JNIEnv *env, jclass, jbyteArray in) {
	jsize n = env->GetArrayLength(in);
	std::vector<uint8_t> src((size_t)n);
	env->GetByteArrayRegion(in, 0, n, reinterpret_cast<jbyte *>(src.data()));
	std::vector<uint8_t> out;
	if (!bd_ctex_to_etc2(src.data(), src.size(), out)) return nullptr;
	jbyteArray r = env->NewByteArray((jsize)out.size());
	if (r) env->SetByteArrayRegion(r, 0, (jsize)out.size(), reinterpret_cast<const jbyte *>(out.data()));
	return r;
}
#endif

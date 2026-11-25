"""package_apk - builds the Buckdroid Roulette app (the launcher APK, the only file this project publishes).
Original code, part of Buckdroid Roulette (GPL-3.0-or-later).

Takes our engine template APK (engine/build_android46.bat: Godot 4.6.3 + patches + the launcher), adds:
  res/mipmap*/icon*.webp our app icon (launcher/icon) in place of Godot's
Privacy: the developer's user name, profile path and git identity are blanked in every file (compilers embed source
paths into native libraries) and the build stops if any remain.
  assets/_cl_            the engine command line: --main-pack <app folder>/game.pck (the game converted on the phone)
  assets/payload/        what the launcher's converter (Converter.java) injects into the game: the Buckdroid scripts
                         (src/), versions.json and autoloads.json (patches/). This project's own code only
then zip-aligns and signs it. The APK never contains game content.

    python tools/package_apk.py <out.apk> [--keystore K --ks-pass P]   (default: the local debug key in .cache/android)
"""
from __future__ import annotations

import argparse
import glob
import io
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build_converter_pck  # noqa: E402

PACKAGE = "com.buckdroid.roulette"
TEMPLATE = os.path.join(ROOT, "engine", "godot46", "bin", "android_debug.apk")
BUILD_TOOLS = os.path.join(ROOT, ".cache", "android", "android-14")


def cl_blob(args: list[str]) -> bytes:
    out = struct.pack("<i", len(args))
    for a in args:
        b = a.encode("utf-8")
        out += struct.pack("<i", len(b)) + b
    return out


def private_strings() -> list[bytes]:
    """Things about the developer's machine that must never end up in a published APK: the Windows user name, the
    user-profile path and the git identity. Compilers embed source paths (for error messages) into native libraries."""
    found = set()
    user = os.environ.get("USERNAME") or os.environ.get("USER") or ""
    profile = os.environ.get("USERPROFILE") or os.path.expanduser("~")
    for v in (user, profile, profile.replace("\\", "/")):
        if v and len(v) >= 3:
            found.add(v)
    for key in ("user.name", "user.email"):
        try:
            v = subprocess.run(["git", "config", key], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        except OSError:
            v = ""
        if v and len(v) >= 3:
            found.add(v)
    return sorted({f.encode("utf-8") for f in found}, key=len, reverse=True)


def scrub(data: bytes, secrets: list[bytes]) -> bytes:
    """Blanks private strings with the same number of 'x' (offsets inside binaries stay the same; the strings are only
    used in messages)."""
    for sec in secrets:
        if sec in data:
            data = data.replace(sec, b"x" * len(sec))
    return data


def icons(src: zipfile.ZipFile) -> dict[str, bytes]:
    """Our app icon (launcher/icon, drawn by tools/make_icon.py) in place of Godot's, at each density the template has."""
    from PIL import Image
    pics = {"icon": "legacy.png", "icon_foreground": "foreground.png", "icon_monochrome": "monochrome.png",
            "icon_background": "foreground.png"}
    out = {}
    for n in src.namelist():
        base = os.path.basename(n)[:-5] if n.startswith("res/mipmap") and n.endswith(".webp") else None
        if base not in pics:
            continue
        with Image.open(io.BytesIO(src.read(n))) as old:
            size, mode = old.size, old.mode
        with Image.open(os.path.join(ROOT, "launcher", "icon", pics[base])) as im:
            buf = io.BytesIO()
            im.convert(mode).resize(size, Image.LANCZOS).save(buf, "WEBP", lossless=True)
        out[n] = buf.getvalue()
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--template", default=TEMPLATE)
    ap.add_argument("--keystore", default=os.path.join(ROOT, ".cache", "android", "debug.keystore"))
    ap.add_argument("--ks-pass", default="android")
    a = ap.parse_args()

    secrets = private_strings()
    files = {"assets/payload/" + p[len("res://payload/"):]: d
             for p, d in build_converter_pck.collect().items() if p.startswith("res://payload/")}
    with tempfile.TemporaryDirectory() as tmp:
        args = ["--main-pack", f"/storage/emulated/0/Android/data/{PACKAGE}/files/game.pck", "--use_immersive"]
        unsigned = os.path.join(tmp, "unsigned.apk")
        with zipfile.ZipFile(a.template) as src, zipfile.ZipFile(unsigned, "w") as dst:
            for i in src.infolist():
                n = i.filename
                if n.startswith("META-INF/") and n.endswith((".SF", ".RSA", ".MF", ".EC", ".DSA")):
                    continue
                if n in ("assets/_cl_", "assets/converter.pck") or n.startswith("assets/payload/") or n in files                         or (n.startswith("res/mipmap") and n.endswith(".webp")):
                    continue
                dst.writestr(i, scrub(src.read(n), secrets))
            dst.writestr(zipfile.ZipInfo("assets/_cl_"), cl_blob(args))
            for n, d in icons(src).items():
                dst.writestr(zipfile.ZipInfo(n), d)
            for n, d in sorted(files.items()):
                dst.writestr(zipfile.ZipInfo(n), d, compress_type=zipfile.ZIP_DEFLATED)
            if "lib/arm64-v8a/libbdconvert.so" not in src.namelist():
                sys.exit("the template has no libbdconvert.so: run native/build_android.bat, then engine/build_android46.bat")
        # Nothing private may remain (also checked case-insensitively for the user name).
        with zipfile.ZipFile(unsigned) as chk:
            for n in chk.namelist():
                d = chk.read(n)
                for sec in secrets:
                    if sec in d or (len(sec) <= 32 and sec.lower() in d.lower()):
                        sys.exit(f"refusing to package: private text found in {n}")
        aligned = os.path.join(tmp, "aligned.apk")
        subprocess.run([os.path.join(BUILD_TOOLS, "zipalign.exe"), "-f", "-p", "4", unsigned, aligned], check=True)
        jdk = glob.glob(os.path.join(ROOT, ".cache", "jdk17", "jdk-17*"))[0]
        if os.path.exists(a.out):
            os.remove(a.out)
        subprocess.run([os.path.join(jdk, "bin", "java.exe"), "-jar", os.path.join(BUILD_TOOLS, "lib", "apksigner.jar"),
                        "sign", "--ks", a.keystore, "--ks-pass", "pass:" + a.ks_pass, "--out", a.out, aligned], check=True)
    print(f"wrote {a.out} ({os.path.getsize(a.out) / 1e6:.1f} MB), payload {len(files)} files, command line {args}")


if __name__ == "__main__":
    main()

"""package_apk - builds the Buckdroid Roulette app (the launcher APK, the only file this project publishes).
Original code, part of Buckdroid Roulette (GPL-3.0-or-later).

Takes our engine template APK (engine/build_android46.bat: Godot 4.6.3 + patches + the launcher), adds:
  assets/_cl_            the engine command line: --main-pack <app folder>/game.pck (the game converted on the phone)
  assets/converter.pck   the converter package (tools/build_converter_pck.py), this project's own code only
then zip-aligns and signs it. The APK never contains game content.

    python tools/package_apk.py <out.apk> [--keystore K --ks-pass P]   (default: the local debug key in .cache/android)
"""
from __future__ import annotations

import argparse
import glob
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build_converter_pck  # noqa: E402
from gdpck import bytes_writer, write_pck  # noqa: E402

PACKAGE = "com.buckdroid.roulette"
TEMPLATE = os.path.join(ROOT, "engine", "godot46", "bin", "android_debug.apk")
BUILD_TOOLS = os.path.join(ROOT, ".cache", "android", "android-14")


def cl_blob(args: list[str]) -> bytes:
    out = struct.pack("<i", len(args))
    for a in args:
        b = a.encode("utf-8")
        out += struct.pack("<i", len(b)) + b
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--template", default=TEMPLATE)
    ap.add_argument("--keystore", default=os.path.join(ROOT, ".cache", "android", "debug.keystore"))
    ap.add_argument("--ks-pass", default="android")
    a = ap.parse_args()

    files = build_converter_pck.collect()
    with tempfile.TemporaryDirectory() as tmp:
        conv = os.path.join(tmp, "converter.pck")
        write_pck(conv, build_converter_pck.ENGINE, [(p, len(d), bytes_writer(d)) for p, d in files.items()])
        args = ["--main-pack", f"/storage/emulated/0/Android/data/{PACKAGE}/files/game.pck", "--use_immersive"]
        unsigned = os.path.join(tmp, "unsigned.apk")
        with zipfile.ZipFile(a.template) as src, zipfile.ZipFile(unsigned, "w") as dst:
            for i in src.infolist():
                n = i.filename
                if n.startswith("META-INF/") and n.endswith((".SF", ".RSA", ".MF", ".EC", ".DSA")):
                    continue
                if n in ("assets/_cl_", "assets/converter.pck"):
                    continue
                dst.writestr(i, src.read(n))
            dst.writestr(zipfile.ZipInfo("assets/_cl_"), cl_blob(args))
            info = zipfile.ZipInfo("assets/converter.pck")
            info.compress_type = zipfile.ZIP_STORED
            with open(conv, "rb") as f:
                dst.writestr(info, f.read())
        aligned = os.path.join(tmp, "aligned.apk")
        subprocess.run([os.path.join(BUILD_TOOLS, "zipalign.exe"), "-f", "-p", "4", unsigned, aligned], check=True)
        jdk = glob.glob(os.path.join(ROOT, ".cache", "jdk17", "jdk-17*"))[0]
        if os.path.exists(a.out):
            os.remove(a.out)
        subprocess.run([os.path.join(jdk, "bin", "java.exe"), "-jar", os.path.join(BUILD_TOOLS, "lib", "apksigner.jar"),
                        "sign", "--ks", a.keystore, "--ks-pass", "pass:" + a.ks_pass, "--out", a.out, aligned], check=True)
    print(f"wrote {a.out} ({os.path.getsize(a.out) / 1e6:.1f} MB), converter {len(files)} files, command line {args}")


if __name__ == "__main__":
    main()

"""make_test_apk - developer-only Android test build. Original code, part of Buckdroid Roulette.

Takes the official Godot export template APK (same engine version as the game), adds an assets/_cl_ file with the
command line "--main-pack <path on the phone>", and re-signs it with a local debug key. The game data is never
put inside the APK: the patched PCK is pushed to the app's own storage on the phone. Not for distribution.

    python tools/make_test_apk.py <template.apk> <out.apk> <pck path on phone> [extra args...]
"""
import struct, sys, zipfile

def cl_blob(args):
    out = struct.pack("<i", len(args))
    for a in args:
        b = a.encode("utf-8")
        out += struct.pack("<i", len(b)) + b
    return out

def main():
    template, out, pck_path, *extra = sys.argv[1:]
    args = ["--main-pack", pck_path] + extra
    with zipfile.ZipFile(template) as src, zipfile.ZipFile(out, "w") as dst:
        for i in src.infolist():
            n = i.filename
            if n.startswith("META-INF/") and n.endswith((".SF", ".RSA", ".MF", ".EC", ".DSA")):
                continue  # old signature; apksigner signs again
            dst.writestr(i, src.read(n))
        dst.writestr(zipfile.ZipInfo("assets/_cl_"), cl_blob(args))
    print("wrote", out, "args:", args)

if __name__ == "__main__":
    main()

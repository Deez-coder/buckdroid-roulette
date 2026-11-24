"""check_bdconvert - developer check: converts every S3TC texture of the game with the native converter's PC build
(.work/bdconvert.exe, native/build_pc_test.bat) and compares the result with Godot 4.6's own conversion (a pack written
by converter/converter.gd). Original code, part of Buckdroid Roulette (GPL-3.0-or-later). Local files only.

    python tools/check_bdconvert.py <game .exe or source .pck> <reference .pck from converter.gd>
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdpck import Pck  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    src, ref = Pck(sys.argv[1]), Pck(sys.argv[2])
    exe = os.path.join(ROOT, ".work", "bdconvert.exe")
    same = differ = failed = 0
    examples = []
    with tempfile.TemporaryDirectory() as tmp:
        a, b = os.path.join(tmp, "in.ctex"), os.path.join(tmp, "out.ctex")
        for e in src.entries:
            if not e.path.endswith(".s3tc.ctex") or e.path not in ref.by_path:
                continue
            with open(a, "wb") as f:
                f.write(src.read(e.path))
            if subprocess.run([exe, a, b], capture_output=True).returncode != 0:
                failed += 1
                examples.append(("failed", e.path))
                continue
            with open(b, "rb") as f:
                out = f.read()
            if out == ref.read(e.path):
                same += 1
            else:
                differ += 1
                if len(examples) < 5:
                    examples.append(("differs", e.path))
    print(f"identical: {same}, different: {differ}, failed: {failed}")
    for kind, p in examples:
        print(" ", kind, p)


if __name__ == "__main__":
    main()

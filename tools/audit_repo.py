"""audit_repo - fails if game content or secrets are about to enter the repository. Original code, part of Buckdroid Roulette.

    python tools/audit_repo.py            # checks files staged for commit (git diff --cached)
    python tools/audit_repo.py --all      # checks every tracked file (for CI)

Checks every file for:
  - forbidden extensions (game data, Godot exports, binaries, keystores)
  - Godot binary headers (PCK "GDPC", project settings "ECFG", resources "RSRC"/"RSCC", textures "GST2"),
    audio/image containers that the project never ships (Ogg, WAV)
  - size over MAX_BYTES
  - folders that must stay local (.work, .cache, recovered)
Prints every problem and exits 1 if there is one. Run it in CI and before every commit.
"""
import os
import subprocess
import sys

MAX_BYTES = 512 * 1024
FORBIDDEN_EXT = {".pck", ".exe", ".dll", ".so", ".ctex", ".scn", ".res", ".oggvorbisstr", ".fontdata", ".sample",
                 ".remap", ".import", ".binary", ".shell", ".ogg", ".wav", ".mp3", ".glb", ".gltf", ".fbx", ".obj",
                 ".keystore", ".jks", ".apk", ".aab", ".zip", ".tpz"}
FORBIDDEN_DIRS = (".work/", ".cache/", "recovered/")
MAGIC = {b"GDPC": "Godot PCK", b"ECFG": "Godot project settings", b"RSRC": "Godot binary resource",
         b"RSCC": "Godot compressed resource", b"GST2": "Godot texture", b"OggS": "Ogg audio", b"RIFF": "RIFF (WAV/WebP)"}


def files(all_tracked: bool):
    cmd = ["git", "ls-files"] if all_tracked else ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [l for l in out.splitlines() if l]


def check(path: str):
    problems = []
    norm = path.replace("\\", "/")
    if norm.startswith(FORBIDDEN_DIRS):
        problems.append("lives in a local-only folder")
    if os.path.splitext(norm)[1].lower() in FORBIDDEN_EXT:
        problems.append("forbidden file type")
    if os.path.isfile(path):
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            problems.append(f"too large ({size // 1024} KB)")
        with open(path, "rb") as f:
            head = f.read(4)
        if head in MAGIC:
            problems.append(f"looks like {MAGIC[head]}")
    return problems


def main():
    all_tracked = "--all" in sys.argv
    bad = 0
    checked = files(all_tracked)
    for p in checked:
        for problem in check(p):
            print(f"FAIL {p}: {problem}")
            bad += 1
    print(f"audit: {len(checked)} files checked, {bad} problem(s)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

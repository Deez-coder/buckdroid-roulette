"""build_patched_pck - PC reference implementation of the install pipeline. Original code, part of Buckdroid Roulette.

    python tools/build_patched_pck.py "<Steam folder>/Buckshot Roulette.exe" .work/patched.pck [--android]

Steps (the same ones the on-device installer performs):
  1. open the user's .exe or .pck and check it against patches/versions.json
  2. copy every original file, unchanged unless a step below replaces it
  3. add our own code from src/ under res://buckdroid/
  4. rewrite project.binary: our autoloads go first, then the settings overrides for the target
  5. write the new PCK (output never leaves the developer's machine; it is gitignored)

Texture transcoding (--android) is added in a later phase; desktop test builds keep the S3TC textures.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))
from gdpck import Pck, bytes_writer, write_pck  # noqa: E402
from ecfg import ProjectBinary  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
RES_PREFIX = "res://buckdroid/"

# Our autoloads, in order. They are placed before the game's own so the Steam stub exists when the game's
# Steam autoload starts. "*" marks them as global singletons (callable by name from scripts).
AUTOLOADS = [
    ("BuckdroidSettings", "core/settings.gd"),
    ("BuckdroidCompat", "compat/newer_engine.gd"),
    ("BuckdroidPlatform", "platform/platform.gd"),
    ("Steam", "platform/steam_stub.gd"),
    ("BuckdroidBoot", "core/boot.gd"),
    ("BuckdroidTouch", "input/touch_adapter.gd"),
    ("BuckdroidTransparencyFallback", "render/transparency_fallback.gd"),
    ("BuckdroidRender", "render/render_settings.gd"),
    ("BuckdroidPerfOverlay", "render/perf_overlay.gd"),
    ("BuckdroidIdlePacing", "render/idle_pacing.gd"),
    ("BuckdroidTelemetry", "core/telemetry.gd"),
]


def load_versions():
    with open(os.path.join(ROOT, "patches", "versions.json"), encoding="utf-8") as f:
        return json.load(f)


def identify(pck: Pck, versions: dict):
    """Cheap identification by the size and md5 of project.binary, then (optionally) a full region hash."""
    pb = pck.by_path.get("res://project.binary")
    if pb is None:
        return None
    for v in versions["supported"]:
        if v["engine"] == ".".join(map(str, pck.engine)) and pb.md5.hex() == v["project_binary_md5"]:
            return v
    return None


def s3tc_target(import_file: bytes) -> str | None:
    for line in import_file.rstrip(b"\0").decode("utf-8").split("\n"):
        if line.startswith("path.s3tc="):
            return line.split("=", 1)[1].strip('"')
    return None


def add_etc2_remap(import_file: bytes, etc2_path: str | None) -> bytes | None:
    """Adds a path.etc2= line to a texture's .import remap, next to its path.s3tc= line.
    etc2_path None reuses the S3TC file (dev smoke test). Returns None when the file has no S3TC entry."""
    text = import_file.rstrip(b"\0").decode("utf-8")
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("path.s3tc="):
            target = etc2_path if etc2_path else line.split("=", 1)[1].strip('"')
            lines = [l for l in lines if not l.startswith("path.etc2=")]
            lines.insert(i + 1, f'path.etc2="{target}"')
            return "\n".join(lines).encode("utf-8") + b"\0"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("out")
    ap.add_argument("--android", action="store_true", help="apply the Android settings overrides")
    ap.add_argument("--full-hash", action="store_true", help="also check the SHA-256 of the whole PCK")
    ap.add_argument("--dev", action="store_true", help="add the dev-only test driver (src_dev/); never for users")
    ap.add_argument("--dev-set", action="append", default=[], metavar="KEY=VALUE",
                    help="dev experiments only: set a project setting (int, float, true/false or text)")
    ap.add_argument("--dev-renderer", choices=["forward_plus", "mobile", "gl_compatibility"],
                    help="dev experiments only: force a renderer on every platform")
    ap.add_argument("--etc2-dir", help="folder written by tools/transcode_etc2.gd; adds the ETC2 textures, points "
                    "the remaps at them, and (with --android) leaves the desktop S3TC copies out")
    ap.add_argument("--dev-s3tc-fallback", action="store_true",
                    help="dev smoke test only: let mobile load the desktop S3TC textures (decoded in software)")
    ap.add_argument("--skip-version-check", action="store_true", help="development only")
    ap.add_argument("--target-engine", choices=["4.6", "4.1"], default="4.6",
                    help="engine the patched data will run on: 4.6 (Buckdroid's Godot 4.6.3 build, default) or 4.1 "
                         "(the game's own engine version)")
    a = ap.parse_args()

    t0 = time.time()
    pck = Pck(a.source)
    versions = load_versions()
    ver = identify(pck, versions)
    if ver is None and not a.skip_version_check:
        sys.exit("Unsupported game version (project.binary does not match patches/versions.json).")
    print(f"game: {ver['name'] if ver else 'UNKNOWN'}  engine {'.'.join(map(str, pck.engine))}  {len(pck.entries)} files")
    if a.full_hash and ver:
        h = pck.region_sha256()
        if h != ver["pck_sha256"]:
            sys.exit(f"PCK hash mismatch: {h}")
        print("full PCK hash ok")

    # 3. our files
    ours: dict[str, bytes] = {}
    for base, _, files in os.walk(SRC):
        for fn in files:
            if fn.endswith((".gd", ".tscn", ".tres", ".png", ".svg", ".json", ".cfg")):
                full = os.path.join(base, fn)
                rel = os.path.relpath(full, SRC).replace(os.sep, "/")
                with open(full, "rb") as f:
                    ours[RES_PREFIX + rel] = f.read()

    autoloads = list(AUTOLOADS)
    if a.dev:
        with open(os.path.join(ROOT, "src_dev", "test_driver.gd"), "rb") as f:
            ours[RES_PREFIX + "dev/test_driver.gd"] = f.read()
        autoloads.append(("BuckdroidTestDriver", "dev/test_driver.gd"))

    # 4. project settings
    pb = ProjectBinary(pck.read("res://project.binary"))
    first_game_autoload = next(k for k in pb.keys() if k.startswith("autoload/"))
    for name, rel in autoloads:
        pb.insert_before(first_game_autoload, f"autoload/{name}", "*" + RES_PREFIX + rel)
    overrides = versions["overrides"]["common"] | (versions["overrides"]["android"] if a.android else {})
    for k, v in overrides.items():
        pb.set(k, v)
    for kv in a.dev_set:
        key, _, val = kv.partition("=")
        v = True if val == "true" else False if val == "false" else int(val) if val.lstrip("-").isdigit() else val
        try:
            v = float(val) if not isinstance(v, (bool, int)) and "." in val else v
        except ValueError:
            pass
        pb.set(key, v)
        print(f"dev setting {key} = {v!r}")
    if a.dev_renderer:
        pb.set("rendering/renderer/rendering_method", a.dev_renderer)
        pb.set("rendering/renderer/rendering_method.mobile", a.dev_renderer)
        print(f"renderer forced to {a.dev_renderer} (dev)")
    replaced = {"res://project.binary": pb.to_bytes()}
    dropped = set()
    if a.etc2_dir:
        added = 0
        for e in pck.entries:
            if not e.path.endswith(".import"):
                continue
            raw = pck.read(e.path)
            s3tc = s3tc_target(raw)
            if s3tc is None:
                continue
            etc2 = s3tc[:-len(".s3tc.ctex")] + ".etc2.ctex"
            local = os.path.join(a.etc2_dir, etc2.replace("res://", ""))
            if not os.path.exists(local):
                sys.exit(f"missing ETC2 texture for {s3tc} (run tools/transcode_etc2.gd)")
            with open(local, "rb") as f:
                etc2_data = f.read()
            if a.android:
                # Phones never use the S3TC data, and some scenes point at the .s3tc.ctex file by name instead of
                # through the remap. So the ETC2 data takes the S3TC file's place (the .ctex header carries the
                # real format) and the remap's path.etc2 points at that same file.
                replaced[s3tc] = etc2_data
                replaced[e.path] = add_etc2_remap(raw, s3tc)
            else:
                ours[etc2] = etc2_data
                replaced[e.path] = add_etc2_remap(raw, etc2)
            added += 1
        print(f"etc2: {added} textures " + ("written in place of the S3TC data" if a.android else "added"))
    if a.target_engine != "4.1":
        # Godot 4.4+ expects "is_abstract" and "is_tool" in every entry of the global class list; without them the
        # game's class_name types are unknown and most scripts fail to parse.
        key = "res://.godot/global_script_class_cache.cfg"
        text = pck.read(key).decode("utf-8")
        text = text.replace('"icon": "",', '"icon": "",' + chr(10) + '"is_abstract": false,' + chr(10) + '"is_tool": false,')
        replaced[key] = text.encode("utf-8")
        # Godot 4.2+ rejects Node-typed @export in a Resource script (4.1 accepted it); the multiplayer-only item
        # resource has four. Dropping the @export keeps the variables; their values are assigned in code.
        key = "res://multiplayer/scripts/user scripts/MP_ItemResource_User.gd"
        src = pck.read(key).decode("utf-8")
        for side in ("R", "L"):
            for part in ("hand", "mesh"):
                src = src.replace(f"@export var {side}_assigned_{part} : Node3D", f"var {side}_assigned_{part} : Node3D")
        replaced[key] = src.encode("utf-8")
        print(f"target engine {a.target_engine}: global class list adapted, 4 Node exports in a Resource script relaxed")
    if a.dev_s3tc_fallback and not a.etc2_dir:
        for e in pck.entries:
            if e.path.endswith(".import"):
                new = add_etc2_remap(pck.read(e.path), None)
                if new is not None:
                    replaced[e.path] = new
        print(f"s3tc fallback: {len(replaced) - 1} texture remaps point mobile at the S3TC data")

    # 5. write
    items = []
    for e in pck.entries:
        if e.path in replaced:
            data = replaced.pop(e.path)
            items.append((e.path, len(data), bytes_writer(data)))
        elif e.path not in ours and e.path not in dropped:
            items.append((e.path, e.size, (lambda e: lambda out, md5: pck.copy_to(e, out, md5))(e)))
    for p, data in ours.items():
        items.append((p, len(data), bytes_writer(data)))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    write_pck(a.out, pck.engine, items)
    print(f"wrote {a.out}: {len(items)} files, {os.path.getsize(a.out) / 1e6:.0f} MB in {time.time() - t0:.1f} s")


if __name__ == "__main__":
    main()

"""build_converter_pck - builds converter.pck, the small package the launcher runs on the phone to convert the player's
own game file. Original code, part of Buckdroid Roulette (GPL-3.0-or-later).

The package contains only this project's own code: the converter (converter/), the Buckdroid scripts it injects into
the game (src/, as res://payload/buckdroid/), and the identification data and autoload list (patches/). No game content.

    python tools/build_converter_pck.py <out.pck>
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdpck import bytes_writer, write_pck  # noqa: E402
from ecfg import ProjectBinary, encode  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = (4, 6, 3)
PAYLOAD_EXT = (".gd", ".tscn", ".tres", ".png", ".svg", ".json", ".cfg", ".gdextension")  # same filter as build_patched_pck.py

MAIN_SCENE = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://converter/converter.gd" id="1"]

[node name="Converter" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
grow_horizontal = 2
grow_vertical = 2
script = ExtResource("1")
"""


def project_binary() -> bytes:
    pb = ProjectBinary(b"ECFG" + b"\0\0\0\0")
    settings = {
        "application/config/name": "Buckdroid Roulette converter",
        "application/run/main_scene": "res://converter/main.tscn",
        "application/boot_splash/minimum_display_time": 0,
        "application/boot_splash/bg_color": None,
        "rendering/renderer/rendering_method": "mobile",
        "rendering/renderer/rendering_method.mobile": "mobile",
        "rendering/textures/vram_compression/import_etc2_astc": True,
        "display/window/size/viewport_width": 1280,
        "display/window/size/viewport_height": 720,
        "display/window/stretch/mode": "canvas_items",
        "display/window/handheld/orientation": 4,
        "application/config/quit_on_go_back": False,
        "display/window/frame_pacing/android/enable_frame_pacing": False,
    }
    for k, v in settings.items():
        if v is not None:
            pb.set(k, v)
    return pb.to_bytes()


def collect() -> dict[str, bytes]:
    files: dict[str, bytes] = {"res://project.binary": project_binary(),
                               "res://converter/main.tscn": MAIN_SCENE.encode("utf-8")}
    for fn in sorted(os.listdir(os.path.join(ROOT, "converter"))):
        if fn.endswith(".gd"):
            with open(os.path.join(ROOT, "converter", fn), "rb") as f:
                files["res://converter/" + fn] = f.read()
    src = os.path.join(ROOT, "src")
    for base, _, names in os.walk(src):
        for fn in sorted(names):
            if fn.endswith(PAYLOAD_EXT):
                full = os.path.join(base, fn)
                rel = os.path.relpath(full, src).replace(os.sep, "/")
                with open(full, "rb") as f:
                    files["res://payload/buckdroid/" + rel] = f.read()
    for fn in ("versions.json", "autoloads.json"):
        with open(os.path.join(ROOT, "patches", fn), "rb") as f:
            files["res://payload/" + fn] = f.read()
    return files


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    files = collect()
    items = [(p, len(d), bytes_writer(d)) for p, d in files.items()]
    write_pck(sys.argv[1], ENGINE, items)
    print(f"wrote {sys.argv[1]}: {len(items)} files, {os.path.getsize(sys.argv[1]) / 1024:.0f} KB")


if __name__ == "__main__":
    main()

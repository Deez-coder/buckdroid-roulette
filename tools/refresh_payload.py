"""refresh_payload - developer tool: swaps this project's own scripts (src/, versions.json, autoloads.json) into an
already converted game pack, without converting it again. Original code, part of Buckdroid Roulette (GPL-3.0-or-later).

The game's files are copied unchanged; only res://buckdroid/* and the extension list are replaced, and the autoload
entries are rewritten from patches/autoloads.json (ours first, before the game's own). For testing on a developer's own
phone: pull the converted game.pck, refresh it, push it back. The output never leaves the developer's devices.

    python tools/refresh_payload.py <converted game.pck> <out.pck> [--dev]
"""
from __future__ import annotations

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from gdpck import Pck, bytes_writer, write_pck  # noqa: E402
from ecfg import ProjectBinary  # noqa: E402
import build_converter_pck  # noqa: E402

RES = "res://buckdroid/"
EXTENSION_LIST = "res://.godot/extension_list.cfg"


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dev = "--dev" in sys.argv          # also the dev test driver (src_dev/test_driver.gd), for tests on the own phone
    src, out = args[0], args[1]
    pck = Pck(src)
    payload = build_converter_pck.collect()
    ours = {RES + p[len("res://payload/buckdroid/"):]: d for p, d in payload.items() if p.startswith("res://payload/buckdroid/")}
    for name in ("versions.json", "autoloads.json"):
        ours[RES + name] = payload["res://payload/" + name]
    ours[EXTENSION_LIST] = (RES + "net/webrtc.gdextension\n").encode("utf-8")

    pb = ProjectBinary(pck.read("res://project.binary"))
    for k in [k for k in pb.keys() if k.startswith("autoload/") and str(pb.get(k)).lstrip("*").startswith(RES)]:
        pb.remove(k)
    first_game = next(k for k in pb.keys() if k.startswith("autoload/"))
    for a in json.loads(payload["res://payload/autoloads.json"])["autoloads"]:
        pb.insert_before(first_game, "autoload/" + a["name"], "*" + RES + a["script"])
    if dev:
        with open(os.path.join(ROOT, "src_dev", "test_driver.gd"), "rb") as f:
            ours[RES + "dev/test_driver.gd"] = f.read()
        pb.insert_before(first_game, "autoload/BuckdroidTestDriver", "*" + RES + "dev/test_driver.gd")
    ours["res://project.binary"] = pb.to_bytes()

    items = []
    for e in pck.entries:
        if e.path in ours or e.path.startswith(RES):
            continue
        items.append((e.path, e.size, (lambda e: lambda f, md5: pck.copy_to(e, f, md5))(e)))
    for p, d in ours.items():
        items.append((p, len(d), bytes_writer(d)))
    write_pck(out, pck.engine, items)
    print(f"wrote {out}: {len(items)} files, {len(ours)} of ours")


if __name__ == "__main__":
    main()

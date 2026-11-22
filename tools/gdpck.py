"""gdpck - read and write Godot 4.1 PCK files (pack format 2). Original code, part of Buckdroid Roulette.

PC-side developer tool. It reads the PCK either from a standalone .pck or from the one embedded at the end of a
Godot .exe, and writes a new PCK that copies the original entries (streamed, never fully loaded into memory),
replaces some of them and adds new ones. The on-device installer implements the same format; this file is the
reference it is tested against.

Format 2 (Godot 4.0-4.2), all little endian:
    header : "GDPC", u32 pack_version=2, u32 major, u32 minor, u32 patch, u32 pack_flags,
             u64 file_base (absolute offset of the data area), 16 x u32 reserved
    dir    : u32 count, then per file: u32 path_len (padded to 4), path bytes (NUL padded),
             u64 offset (relative to file_base), u64 size, 16 B md5, u32 file_flags
    data   : file contents
Embedded in an .exe the PCK ends with: u64 pck_size, "GDPC"; the PCK starts at end - 12 - pck_size.
"""
from __future__ import annotations

import hashlib
import os
import struct
import sys
from dataclasses import dataclass
from typing import BinaryIO, Callable, Iterable

MAGIC = b"GDPC"
ALIGN = 32  # data alignment used by Godot's own packer


@dataclass
class Entry:
    path: str        # "res://..."
    offset: int      # absolute offset in the source file
    size: int
    md5: bytes
    flags: int


class Pck:
    def __init__(self, path: str):
        self.path = path
        self.f: BinaryIO = open(path, "rb")
        self.start = self._find_start()
        self.f.seek(self.start)
        magic, self.pack_version, *self.engine = struct.unpack("<4sIIII", self.f.read(20))
        if magic != MAGIC:
            raise ValueError(f"{path}: no PCK found")
        if self.pack_version != 2:
            raise ValueError(f"{path}: pack format {self.pack_version} is not supported (need 2, Godot 4.0-4.2)")
        self.pack_flags, file_base = struct.unpack("<IQ", self.f.read(12))
        if self.pack_flags & 1:
            raise ValueError(f"{path}: the PCK directory is encrypted")
        self.f.read(64)
        # Godot treats file_base as absolute in exported executables and as relative to the PCK start in
        # standalone files that start at 0; both reduce to the same thing when start == 0.
        self.file_base = file_base if self.start == 0 or file_base > self.start else self.start + file_base
        (count,) = struct.unpack("<I", self.f.read(4))
        self.entries: list[Entry] = []
        for _ in range(count):
            (n,) = struct.unpack("<I", self.f.read(4))
            p = self.f.read(n).rstrip(b"\0").decode("utf-8")
            off, size = struct.unpack("<QQ", self.f.read(16))
            md5 = self.f.read(16)
            (fl,) = struct.unpack("<I", self.f.read(4))
            self.entries.append(Entry(p, self.file_base + off, size, md5, fl))
        self.by_path = {e.path: e for e in self.entries}

    def _find_start(self) -> int:
        self.f.seek(0)
        if self.f.read(4) == MAGIC:
            return 0
        self.f.seek(-12, os.SEEK_END)
        size, magic = struct.unpack("<Q4s", self.f.read(12))
        if magic != MAGIC:
            raise ValueError(f"{self.path}: neither a .pck nor an executable with an embedded PCK")
        return self.f.seek(0, os.SEEK_END) - 12 - size

    @property
    def end(self) -> int:
        """Offset one past the PCK (for hashing the embedded region)."""
        e = max(self.entries, key=lambda x: x.offset)
        return e.offset + e.size

    def read(self, path: str) -> bytes:
        e = self.by_path[path]
        self.f.seek(e.offset)
        return self.f.read(e.size)

    def copy_to(self, e: Entry, out: BinaryIO, md5) -> None:
        self.f.seek(e.offset)
        left = e.size
        while left:
            chunk = self.f.read(min(left, 1 << 20))
            out.write(chunk)
            md5.update(chunk)
            left -= len(chunk)

    def region_sha256(self) -> str:
        """SHA-256 of the PCK bytes alone, so the .exe and an extracted .pck give the same answer."""
        h = hashlib.sha256()
        self.f.seek(self.start)
        left = self.end - self.start
        while left:
            chunk = self.f.read(min(left, 1 << 20))
            h.update(chunk)
            left -= len(chunk)
        return h.hexdigest()


def write_pck(out_path: str, engine: Iterable[int], items: list[tuple[str, int, Callable[[BinaryIO, object], None]]],
              progress: Callable[[int, int], None] | None = None) -> None:
    """items: (res path, size, writer(out, md5)). Writes a format-2 PCK with aligned data."""
    items = list(items)
    dir_size = 4
    for p, _, _ in items:
        b = len(p.encode("utf-8"))
        dir_size += 4 + b + (-b % 4) + 8 + 8 + 16 + 4
    header = 20 + 12 + 64
    file_base = header + dir_size
    file_base += -file_base % ALIGN
    offsets, cur = [], 0
    for _, size, _ in items:
        offsets.append(cur)
        cur += size + (-size % ALIGN)
    md5s = []
    tmp = out_path + ".part"
    with open(tmp, "wb") as out:
        out.write(b"\0" * file_base)
        for i, (p, size, writer) in enumerate(items):
            out.seek(file_base + offsets[i])
            h = hashlib.md5()
            writer(out, h)
            md5s.append(h.digest())
            out.write(b"\0" * (-size % ALIGN))
            if progress:
                progress(i + 1, len(items))
        out.seek(0)
        out.write(struct.pack("<4sIIII", MAGIC, 2, *engine))
        out.write(struct.pack("<IQ", 0, file_base))
        out.write(b"\0" * 64)
        out.write(struct.pack("<I", len(items)))
        for (p, size, _), off, md5 in zip(items, offsets, md5s):
            b = p.encode("utf-8")
            pad = -len(b) % 4
            out.write(struct.pack("<I", len(b) + pad) + b + b"\0" * pad)
            out.write(struct.pack("<QQ", off, size) + md5 + struct.pack("<I", 0))
    os.replace(tmp, out_path)


def bytes_writer(data: bytes):
    def w(out, md5):
        out.write(data)
        md5.update(data)
    return w


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="List, hash or extract a Godot 4.1 PCK (or .exe with one embedded).")
    ap.add_argument("file")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--hash", action="store_true", help="SHA-256 of the PCK region")
    ap.add_argument("--extract", metavar="OUTDIR")
    ap.add_argument("--match", default="", help="substring filter for --list/--extract")
    a = ap.parse_args()
    pck = Pck(a.file)
    print(f"engine {'.'.join(map(str, pck.engine))}, {len(pck.entries)} files, PCK at {pck.start}", file=sys.stderr)
    if a.hash:
        print(pck.region_sha256())
    for e in pck.entries:
        if a.match not in e.path:
            continue
        if a.list:
            print(f"{e.size}\t{e.path}")
        if a.extract:
            dst = os.path.join(a.extract, e.path.replace("res://", ""))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "wb") as o:
                o.write(pck.read(e.path))

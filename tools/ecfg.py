"""ecfg - read and edit Godot's binary project settings (project.binary, "ECFG"). Original code, part of Buckdroid Roulette.

Values we do not touch are kept as their raw encoded bytes, so complex settings (input maps, arrays) survive an
edit exactly. New or replaced values may be bool, int, float or str, which is all the overrides need.

Layout: "ECFG", u32 count, then per setting: u32 key_len, key, u32 value_len, value (Godot Variant encoding).
Settings are applied in file order, which also decides autoload order.
"""
from __future__ import annotations

import struct

T_NIL, T_BOOL, T_INT, T_FLOAT, T_STRING = 0, 1, 2, 3, 4


def encode(v) -> bytes:
    if v is None:
        return struct.pack("<I", T_NIL)
    if isinstance(v, bool):
        return struct.pack("<II", T_BOOL, int(v))
    if isinstance(v, int):
        if -2**31 <= v < 2**31:
            return struct.pack("<Ii", T_INT, v)
        return struct.pack("<Iq", T_INT | (1 << 16), v)
    if isinstance(v, float):
        return struct.pack("<Id", T_FLOAT | (1 << 16), v)
    if isinstance(v, str):
        b = v.encode("utf-8")
        return struct.pack("<II", T_STRING, len(b)) + b + b"\0" * (-len(b) % 4)
    raise TypeError(f"cannot encode {type(v).__name__}")


def decode_simple(raw: bytes):
    """Decodes bool/int/float/string; other types come back as None."""
    (t,) = struct.unpack("<I", raw[:4])
    base, wide = t & 0xFFFF, t >> 16
    if base == T_BOOL:
        return bool(struct.unpack("<I", raw[4:8])[0])
    if base == T_INT:
        return struct.unpack("<q" if wide else "<i", raw[4:12 if wide else 8])[0]
    if base == T_FLOAT:
        return struct.unpack("<d" if wide else "<f", raw[4:12 if wide else 8])[0]
    if base == T_STRING:
        (n,) = struct.unpack("<I", raw[4:8])
        return raw[8:8 + n].decode("utf-8")
    return None


class ProjectBinary:
    def __init__(self, data: bytes):
        if data[:4] != b"ECFG":
            raise ValueError("not a project.binary")
        (n,) = struct.unpack("<I", data[4:8])
        p = 8
        self.items: list[list] = []  # [key, raw value bytes]
        for _ in range(n):
            (kl,) = struct.unpack("<I", data[p:p + 4]); key = data[p + 4:p + 4 + kl].decode("utf-8"); p += 4 + kl
            (vl,) = struct.unpack("<I", data[p:p + 4]); raw = data[p + 4:p + 4 + vl]; p += 4 + vl
            self.items.append([key, raw])

    def keys(self):
        return [k for k, _ in self.items]

    def get(self, key, default=None):
        for k, raw in self.items:
            if k == key:
                return decode_simple(raw)
        return default

    def set(self, key: str, value, first: bool = False) -> None:
        raw = encode(value)
        for item in self.items:
            if item[0] == key:
                item[1] = raw
                return
        if first:
            self.items.insert(0, [key, raw])
        else:
            self.items.append([key, raw])

    def remove(self, key: str) -> None:
        self.items = [i for i in self.items if i[0] != key]

    def insert_before(self, before_key: str, key: str, value) -> None:
        self.remove(key)
        idx = next((i for i, it in enumerate(self.items) if it[0] == before_key), len(self.items))
        self.items.insert(idx, [key, encode(value)])

    def to_bytes(self) -> bytes:
        out = [b"ECFG", struct.pack("<I", len(self.items))]
        for k, raw in self.items:
            kb = k.encode("utf-8")
            out += [struct.pack("<I", len(kb)), kb, struct.pack("<I", len(raw)), raw]
        return b"".join(out)


if __name__ == "__main__":
    import sys
    pb = ProjectBinary(open(sys.argv[1], "rb").read())
    for k, raw in pb.items:
        v = decode_simple(raw)
        print(k, "=", v if v is not None else f"<{len(raw)} bytes>")

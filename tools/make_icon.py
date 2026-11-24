"""make_icon - draws the Buckdroid Roulette app icon (original art: a red shotgun shell with a brass base on a dark
round backdrop, tilted). Original code, part of Buckdroid Roulette (GPL-3.0-or-later).

Writes launcher/icon/foreground.png (adaptive icon foreground, opaque: it carries its own backdrop), monochrome.png
(themed icon) and legacy.png (the round pre-Android-8 icon), all 1024 px. tools/package_apk.py scales them into the APK.

    python tools/make_icon.py
"""
from __future__ import annotations

import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "launcher", "icon")
S = 1024          # output size
SS = 4            # supersampling

BG_IN, BG_OUT = (44, 50, 62), (12, 14, 18)
HULL, HULL_DARK, HULL_LIGHT = (214, 48, 49), (120, 22, 26), (246, 110, 100)
BRASS, BRASS_DARK, BRASS_LIGHT = (205, 160, 74), (120, 86, 34), (250, 220, 140)


def backdrop(n: int) -> Image.Image:
    """A radial dark gradient: a soft light behind the shell, as from a lamp over a table."""
    img = Image.new("RGB", (n, n))
    px = img.load()
    c = n / 2
    for y in range(n):
        for x in range(n):
            d = min(1.0, math.hypot(x - c, (y - c * 0.85)) / (n * 0.62))
            t = d * d
            px[x, y] = tuple(int(BG_IN[i] * (1 - t) + BG_OUT[i] * t) for i in range(3))
    return img


def shell(n: int, mono: bool = False) -> Image.Image:
    """The shell, upright, centred, on a transparent n x n layer. Heights in parts of n; the adaptive icon's safe zone is
    the middle 61%, so the shell stays within about 56%."""
    L = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(L)
    cx = n / 2
    w = n * 0.15                      # hull width
    top, hull_bot, base_bot = n * 0.26, n * 0.63, n * 0.73
    def col(c):
        return (255, 255, 255, 255) if mono else c + (255,)
    # hull: a rounded column with a crimped top
    d.rounded_rectangle([cx - w / 2, top, cx + w / 2, hull_bot + n * 0.02], radius=w * 0.22, fill=col(HULL))
    if not mono:
        # shading: dark right edge, light stripe on the left
        d.rectangle([cx + w * 0.22, top + w * 0.2, cx + w / 2 - 1, hull_bot], fill=HULL_DARK + (255,))
        d.rounded_rectangle([cx - w * 0.36, top + w * 0.25, cx - w * 0.18, hull_bot - n * 0.01], radius=w * 0.08,
                            fill=HULL_LIGHT + (255,))
        # crimp: the folded star at the top, drawn as three short dark lines
        for k in (-1, -0.33, 0.33, 1):
            d.line([cx + k * w * 0.36, top + w * 0.06, cx, top + w * 0.34], fill=HULL_DARK + (255,), width=max(1, int(n * 0.01)))
    # brass base: a band, then the wider rim
    bw = w * 1.04
    d.rectangle([cx - bw / 2, hull_bot - n * 0.005, cx + bw / 2, base_bot - n * 0.035], fill=col(BRASS))
    rw = w * 1.24
    d.rounded_rectangle([cx - rw / 2, base_bot - n * 0.04, cx + rw / 2, base_bot], radius=n * 0.008, fill=col(BRASS))
    if not mono:
        d.rectangle([cx + bw * 0.22, hull_bot, cx + bw / 2, base_bot - n * 0.035], fill=BRASS_DARK + (255,))
        d.rectangle([cx - bw * 0.36, hull_bot + n * 0.006, cx - bw * 0.2, base_bot - n * 0.04], fill=BRASS_LIGHT + (255,))
        d.rectangle([cx + rw * 0.22, base_bot - n * 0.04, cx + rw / 2 - n * 0.004, base_bot - n * 0.002], fill=BRASS_DARK + (255,))
        # the line where hull meets brass
        d.line([cx - bw / 2, hull_bot - n * 0.005, cx + bw / 2, hull_bot - n * 0.005], fill=BRASS_DARK + (255,),
               width=max(1, int(n * 0.008)))
    return L.rotate(-18, resample=Image.BICUBIC, center=(cx, n * 0.5))


def compose(n: int) -> Image.Image:
    img = backdrop(256).resize((n, n), Image.BICUBIC).convert("RGBA")
    sh = shell(n)
    # a soft shadow under the shell
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    shadow.putalpha(sh.getchannel("A").point(lambda a: int(a * 0.55)))
    shadow = shadow.transform((n, n), Image.AFFINE, (1, 0, n * 0.02, 0, 1, -n * 0.03)).filter(ImageFilter.GaussianBlur(n * 0.02))
    img.alpha_composite(shadow)
    img.alpha_composite(sh)
    return img


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    big = S * SS
    fg = compose(big).resize((S, S), Image.LANCZOS)
    fg.save(os.path.join(OUT, "foreground.png"))
    shell(big, mono=True).resize((S, S), Image.LANCZOS).save(os.path.join(OUT, "monochrome.png"))
    # legacy: the same picture in a circle (the middle 72% of the adaptive canvas, as launchers crop it)
    crop = int(S * 0.14)
    circ = fg.crop((crop, crop, S - crop, S - crop)).resize((S, S), Image.LANCZOS)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, big - 1, big - 1], fill=255)
    circ.putalpha(mask.resize((S, S), Image.LANCZOS))
    circ.save(os.path.join(OUT, "legacy.png"))
    print("wrote", OUT)


if __name__ == "__main__":
    main()

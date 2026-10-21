#!/usr/bin/env python3
"""Renders the MacGuard icon: flat ink body, open paper-white gauge ring, peach needle and hub.
Run: python3 tools/make_icon.py  (needs Pillow). Writes Resources/AppIcon.iconset/*.png"""
import math, os
from PIL import Image, ImageDraw

INK, PAPER, PEACH = (23, 25, 28, 255), (255, 255, 255, 255), (251, 225, 209, 255)
S = 4
N = 1024 * S
cx = cy = N / 2

def pol(r, deg):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)

def ring(d, r_mid, width, a0, a1, color, steps=600):
    ro, ri = r_mid + width / 2, r_mid - width / 2
    outer = [pol(ro, a0 + (a1 - a0) * i / steps) for i in range(steps + 1)]
    inner = [pol(ri, a1 - (a1 - a0) * i / steps) for i in range(steps + 1)]
    d.polygon(outer + inner, fill=color)
    for deg in (a0, a1):                                  # round caps
        x, y = pol(r_mid, deg)
        d.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=color)

img = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

body = 824 * S                                            # macOS icon body size on a 1024 canvas
m = (N - body) / 2
d.rounded_rectangle([m, m, m + body, m + body], radius=int(184 * S), fill=INK)

# 270 degree gauge, opening at the bottom (angles clockwise from 3 o'clock)
ring(d, 238 * S, 70 * S, 135, 405, PAPER)

# needle + hub
nx, ny = pol(150 * S, 300)
d.line([(cx, cy), (nx, ny)], fill=PEACH, width=int(46 * S))
for (x, y, r) in ((nx, ny, 23 * S), (cx, cy, 60 * S)):
    d.ellipse([x - r, y - r, x + r, y + r], fill=PEACH)

base = img.resize((1024, 1024), Image.LANCZOS)
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon.iconset")
os.makedirs(out, exist_ok=True)
for size in (16, 32, 128, 256, 512):
    base.resize((size, size), Image.LANCZOS).save(f"{out}/icon_{size}x{size}.png")
    base.resize((size * 2, size * 2), Image.LANCZOS).save(f"{out}/icon_{size}x{size}@2x.png")
base.save(os.path.join(out, "..", "icon_preview.png"))
print("ok")

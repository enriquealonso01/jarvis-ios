#!/usr/bin/env python3
"""Generate the JARVIS app icon (arc-reactor mark) reproducibly.

Run: python3 scripts/gen_app_icon.py
Writes ios/JarvisApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png
Requires Pillow on the JARVIS box (installed).
"""
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "ios", "JarvisApp", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

S = 1024
GOLD = (255, 199, 89)
HOT = (255, 240, 210)
BG = (10, 11, 15)

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)
cx = cy = S // 2
for i in range(60, 0, -1):          # subtle radial depth
    r = int(S * 0.75 * i / 60)
    shade = int(12 + 8 * (1 - i / 60))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(shade, shade + 1, shade + 4))

R_OUT, RING_W = int(S * 0.36), int(S * 0.055)
R_MID, R_CORE = int(S * 0.24), int(S * 0.16)

def reactor(draw):
    draw.ellipse([cx - R_OUT, cy - R_OUT, cx + R_OUT, cy + R_OUT], outline=GOLD, width=RING_W)
    for k in range(12):
        a = math.radians(k * 30)
        r1, r2 = R_OUT + int(S * 0.02), R_OUT + int(S * 0.055)
        draw.line([cx + r1 * math.cos(a), cy + r1 * math.sin(a),
                   cx + r2 * math.cos(a), cy + r2 * math.sin(a)], fill=GOLD, width=int(S * 0.018))
    draw.ellipse([cx - R_MID, cy - R_MID, cx + R_MID, cy + R_MID], outline=GOLD, width=int(S * 0.02))
    draw.ellipse([cx - R_CORE, cy - R_CORE, cx + R_CORE, cy + R_CORE], fill=GOLD)
    hot = int(S * 0.07)
    draw.ellipse([cx - hot, cy - hot, cx + hot, cy + hot], fill=HOT)

glow = Image.new("RGB", (S, S), (0, 0, 0))
reactor(ImageDraw.Draw(glow))
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.02))
img = ImageChops.add(img, glow.point(lambda p: int(p * 0.55)))
reactor(ImageDraw.Draw(img))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT, "PNG")
print("wrote", OUT)

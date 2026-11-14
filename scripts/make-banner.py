#!/usr/bin/env python3
"""Compose the ReOculus banner from the REAL Quest 2 product photo.

The hero photo is the real Quest 2 product shot Anthony uploaded,
headset plus both controllers, with genuine transparency (no cleanup
needed). An earlier photo had its checkerboard baked into the pixels;
clean_photo() below strips that one if it is ever used again, but the
current banner does not need it. The headset pixels are the real photo,
no AI redraw.
Source photo: workspace/user/media_library/image/Oculus-Quest-2-PNG-Image-HD.png
Run: python3 scripts/make-banner.py  (writes assets/banner.png)
"""
from collections import deque as _dq

def clean_photo(src, out):
    from PIL import Image, ImageFilter
    im = Image.open(src).convert('RGB')
    w, h = im.size
    px = im.load()
    WHITE = (255, 255, 255); GRAY = (230, 230, 231)
    mask = [[1 if px[x, y] in (WHITE, GRAY) else 0 for x in range(w)] for y in range(h)]
    seen = [[False]*w for _ in range(h)]
    q = _dq()
    def seed(x, y):
        if 0 <= x < w and 0 <= y < h and mask[y][x] and not seen[y][x]:
            seen[y][x] = True; q.append((x, y))
    for x in range(w):
        seed(x, 0); seed(x, h-1)
    for y in range(h):
        seed(0, y); seed(w-1, y)
    for sx, sy in [(500, 90), (620, 110), (450, 420), (550, 430), (650, 410), (350, 400), (700, 430), (550, 100)]:
        seed(sx, sy)
    while q:
        x, y = q.popleft()
        for nx, ny in ((x+1,y),(x-1,y),(x,y+1),(x,y-1)):
            if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not seen[ny][nx]:
                seen[ny][nx] = True; q.append((nx, ny))
    alpha = Image.new('L', (w, h), 255)
    ap = alpha.load()
    for y in range(h):
        for x in range(w):
            if seen[y][x]:
                ap[x, y] = 0
    # exact checker squares left under the headset (blocked by the glow),
    # and the lavender glow itself: both only under the headset, where the
    # headset body and strap never reach, so no real pixels are touched.
    # (Both writes go to the same alpha image; the earlier version wrote the
    # glow removal to the RGBA copy and then overwrote it with putalpha.)
    for y in range(340, 459):
        for x in range(280, 820):
            if px[x, y] in (WHITE, GRAY):
                ap[x, y] = 0
            else:
                r, g, b = px[x, y]
                if r > 185 and g > 185 and b > 185 and b >= r and (max(r, g, b) - min(r, g, b)) <= 40:
                    ap[x, y] = 0
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.8))
    out_im = im.convert('RGBA')
    out_im.putalpha(alpha)
    out_im.save(out)

import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops

W, H = 1280, 640
BG_TOP = (11, 20, 36)
BG_BOT = (7, 11, 20)
CYAN = (56, 189, 248)
CYAN_LT = (125, 211, 252)
TITLE_C = (214, 243, 255)
SRC_PHOTO = '/home/hatch/workspace/user/media_library/image/Oculus-Quest-2-PNG-Image-HD.png'
_old = '/home/hatch/workspace/user/media_library/image/png-transparent-oculus-quest-2-electronics-vr-headsets.png'
# The HD shot has real transparency, use it as-is. A photo whose
# "transparency" is a baked-in checkerboard goes through clean_photo().
_check = Image.open(SRC_PHOTO).convert('RGBA')
PHOTO = SRC_PHOTO if _check.split()[3].getextrema()[0] == 0 else '/tmp/quest2-clean.png'
if PHOTO != SRC_PHOTO:
    clean_photo(SRC_PHOTO, PHOTO)
ROBOTO = '/home/hatch/workspace/flutter-sdk/bin/cache/artifacts/material_fonts/Roboto-{}.ttf'
OUT = '/home/hatch/workspace/quest-companion/assets/banner.png'

# ---- background: vertical gradient ---------------------------------------
bg = Image.new('RGB', (W, H))
top = Image.new('RGB', (1, H))
for y in range(H):
    t = y / (H - 1)
    top.putpixel((0, y), tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
bg = top.resize((W, H))
overlay = Image.new('RGBA', (W, H), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)

# ---- faint hex grid (top-left and edges) ----------------------------------
def hex_points(cx, cy, r):
    return [(cx + r * math.cos(math.radians(60 * k - 30)),
             cy + r * math.sin(math.radians(60 * k - 30))) for k in range(6)]

for row in range(-1, 7):
    for col in range(-1, 12):
        cx = col * 78 + (39 if row % 2 else 0)
        cy = row * 68
        od.line(hex_points(cx, cy, 42) + [hex_points(cx, cy, 42)[0]],
               fill=CYAN + (14,), width=1)

# ---- circuit traces -------------------------------------------------------
def trace(points, dot=True):
    od.line(points, fill=CYAN + (70,), width=2, joint='curve')
    if dot:
        x, y = points[-1]
        od.ellipse([x - 5, y - 5, x + 5, y + 5], outline=CYAN + (110,), width=2)

trace([(980, 30), (980, 90), (1060, 90), (1060, 150)])
trace([(70, 30), (150, 30), (150, 80), (230, 80)])
trace([(1150, 560), (1150, 480), (1070, 480), (1070, 430)])
trace([(300, 610), (300, 560), (380, 560)])
trace([(1180, 200), (1120, 200), (1120, 260)])

# soft cyan glow top-right, behind where the headset goes
glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([780, -60, 1330, 640], fill=(34, 150, 220, 60))
glow = glow.filter(ImageFilter.GaussianBlur(90))
overlay = Image.alpha_composite(overlay, glow)
bg = Image.alpha_composite(bg.convert('RGBA'), overlay)

# ---- the real headset, with a cyan rim glow -------------------------------
hs = Image.open(PHOTO).convert('RGBA')
hs = hs.resize((480, 600), Image.LANCZOS)  # tall shot: headset on top, controllers below
mask = hs.split()[3]
halo = Image.new('RGBA', hs.size, (0, 0, 0, 0))
halo.putalpha(mask.filter(ImageFilter.GaussianBlur(14)))
halo = ImageChops.multiply(halo, Image.new('RGBA', hs.size, (56, 189, 248, 170)))
bg.alpha_composite(halo, (736, 16))
bg.alpha_composite(hs, (740, 20))

# ---- shield (preservation) -------------------------------------------------
d = ImageDraw.Draw(bg)
cx, top = 110, 405  # left column, clear of the headset
shield = [(cx - 40, top), (cx + 40, top), (cx + 40, top + 48),
          (cx, top + 92), (cx - 40, top + 48)]
d.line(shield + [shield[0]], fill=CYAN, width=4, joint='curve')
d.line([(cx - 20, top + 42), (cx - 5, top + 58), (cx + 22, top + 26)],
       fill=CYAN, width=6, joint='curve')

# ---- text -------------------------------------------------------------------
title_font = ImageFont.truetype(ROBOTO.format('Bold'), 118)
tag_font = ImageFont.truetype(ROBOTO.format('Regular'), 34)
support_font = ImageFont.truetype(ROBOTO.format('Medium'), 26)
support_list_font = ImageFont.truetype(ROBOTO.format('Regular'), 24)
pill_font = ImageFont.truetype(ROBOTO.format('Medium'), 24)
d.text((70, 195), 'ReOculus', font=title_font, fill=TITLE_C)
d.text((73, 330), 'Keep your Quest alive on Linux.', font=tag_font, fill=CYAN_LT)
# Supported headsets, to the right of the shield.
d.text((190, 410), 'Supported headsets:', font=support_font, fill=TITLE_C)
d.text((190, 445), 'Quest 1  •  Quest 2  •  Quest 3', font=support_list_font, fill=CYAN_LT)
d.text((190, 478), 'Quest 3S  •  Quest Pro', font=support_list_font, fill=CYAN_LT)

x = 70
for label in ('No ads', 'No account', 'No telemetry'):
    tw = d.textlength(label, font=pill_font)
    w = int(tw) + 48
    d.rounded_rectangle([x, 545, x + w, 591], radius=23,
                        outline=CYAN, width=2)
    d.text((x + 24, 556), label, font=pill_font, fill=CYAN_LT)
    x += w + 24

bg.convert('RGB').save(OUT, 'PNG')
print('wrote', OUT)

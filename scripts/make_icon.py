#!/usr/bin/env python3
# Scribe app icon (0.7 "Night Sky"): a lavender sound wave of rounded capsule bars with a quiet
# field of four-point sparkles on a matte near-black squircle tile (macOS grid: 1024 canvas,
# 824 body). This is variant E from the 0.7 icon exploration (dark, starry).
#
# REQUIRES: Python 3 + Pillow + numpy  (pip install pillow numpy)
#
# Usage:
#   python3 scripts/make_icon.py --appiconset Resources/Assets.xcassets/AppIcon.appiconset
#   python3 scripts/make_icon.py out.png            # one 1024 px PNG
#   python3 scripts/make_icon.py --size 32 out.png  # one native size (<= 32 px uses a bolder small profile)
#
# The sparkle is the superellipse |x|^0.42 + |y|^0.42 <= 1 (star_mask below); the app draws
# the same shape in Views/Brand/Sparkle.swift.
#
# ---- icon kit (shared by every Scribe icon variant) ---------------------------------
# macOS 26 grid: 1024 canvas, 824 body (100 inset), continuous-corner squircle.
# Every size is rendered natively (not downscaled from 1024): shapes are drawn as masks
# at SS x supersampling, box-reduced, then composited in float. Sizes <= 32 px use a
# "small" profile (bolder glyph, fewer fine details) so the icon stays crisp in lists.
# Requires Pillow + numpy.
import math, os, sys, json
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

INSET, BODY = 100, 824

class Ctx:
    def __init__(self, size):
        self.size = size
        self.ss = max(4, int(math.ceil(2048 / size)))   # mask supersampling
        self.R = size * self.ss
        self.k = self.R / 1024.0          # 1024-unit -> mask px
        self.px = size / 1024.0           # 1024-unit -> output px
        self.small = size <= 32
        self.mid = size <= 64

    # -- masks (float 0..1 at output size) --
    def blank(self):
        img = Image.new("L", (self.R, self.R), 0)
        return img, ImageDraw.Draw(img)

    def done(self, img):
        return np.asarray(img.reduce(self.ss), dtype=np.float32) / 255.0

    def P(self, pts):
        return [(x * self.k, y * self.k) for x, y in pts]

def squircle(c, inset=INSET, n=5.0):
    # Superellipse |x|^n + |y|^n = 1 : Apple-style continuous corners.
    R = c.R
    a = (1024 - 2 * inset) / 2.0 * c.k
    ctr = 512 * c.k
    ys, xs = np.mgrid[0:R, 0:R].astype(np.float32)
    x = np.abs(xs + 0.5 - ctr) / a; y = np.abs(ys + 0.5 - ctr) / a
    v = (x ** n + y ** n)
    m = (v <= 1.0).astype(np.uint8) * 255
    return c.done(Image.fromarray(m))

def poly_mask(c, pts):
    img, d = c.blank(); d.polygon(c.P(pts), fill=255); return c.done(img)

def stroke_mask(c, pts, width):
    img, d = c.blank()
    w = width * c.k
    P = c.P(pts)
    d.line(P, fill=255, width=max(1, int(round(w))), joint="curve")
    for (x, y) in (P[0], P[-1]):
        d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=255)
    return c.done(img)

def capsule_mask(c, x0, y0, x1, y1):
    img, d = c.blank()
    r = min(x1 - x0, y1 - y0) / 2.0
    d.rounded_rectangle([x0 * c.k, y0 * c.k, x1 * c.k, y1 * c.k], radius=r * c.k, fill=255)
    return c.done(img)

def rrect_mask(c, x0, y0, x1, y1, r):
    img, d = c.blank()
    d.rounded_rectangle([x0 * c.k, y0 * c.k, x1 * c.k, y1 * c.k], radius=r * c.k, fill=255)
    return c.done(img)

def union(*ms):
    out = ms[0].copy()
    for m in ms[1:]:
        out = 1 - (1 - out) * (1 - m)
    return out

def blur(m, radius_units, c):
    r = radius_units * c.px
    if r < 0.3: return m
    img = Image.fromarray(np.clip(m * 255, 0, 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(r)), dtype=np.float32) / 255.0

def shift(m, dx_units, dy_units, c):
    dx = dx_units * c.px; dy = dy_units * c.px
    img = Image.fromarray(np.clip(m * 255, 0, 255).astype(np.uint8))
    img = img.transform(img.size, Image.AFFINE, (1, 0, -dx, 0, 1, -dy), resample=Image.BILINEAR)
    return np.asarray(img, dtype=np.float32) / 255.0

# -- color fields --
def rgb(t):
    return np.array(t[:3], dtype=np.float32) / 255.0

def vgrad(c, top, bot, y0=INSET, y1=1024 - INSET):
    s = c.size
    y = (np.arange(s, dtype=np.float32) + 0.5) / c.px
    t = np.clip((y - y0) / (y1 - y0), 0, 1)[:, None, None]
    col = rgb(top)[None, None, :] * (1 - t) + rgb(bot)[None, None, :] * t
    return np.broadcast_to(col, (s, s, 3)).copy()

def radial(c, cx, cy, r):
    s = c.size
    ys, xs = np.mgrid[0:s, 0:s].astype(np.float32)
    d = np.hypot((xs + 0.5) / c.px - cx, (ys + 0.5) / c.px - cy) / r
    return np.clip(1 - d, 0, 1) ** 2

class Canvas:
    def __init__(self, c):
        self.c = c
        self.rgb = np.zeros((c.size, c.size, 3), np.float32)
        self.a = np.zeros((c.size, c.size), np.float32)

    def over(self, color, alpha):
        # color: (3,) or (H,W,3) in 0..1 ; alpha: (H,W)
        col = color if getattr(color, "ndim", 1) == 3 else np.asarray(color, np.float32)[None, None, :]
        a = np.clip(alpha, 0, 1)
        out_a = a + self.a * (1 - a)
        num = col * a[..., None] + self.rgb * (self.a * (1 - a))[..., None]
        self.rgb = np.where(out_a[..., None] > 1e-6, num / np.maximum(out_a, 1e-6)[..., None], 0)
        self.a = out_a

    def image(self):
        arr = np.dstack([np.clip(self.rgb, 0, 1) * 255, np.clip(self.a, 0, 1) * 255])
        return Image.fromarray((arr + 0.5).astype(np.uint8), "RGBA")

def tile(cv, body, top, bot, glow=0.18, rim=0.55, inner_shadow=0.18, drop=0.28):
    """The squircle tile: soft drop shadow, vertical gradient, top glow, specular top rim,
    soft inner shade along the bottom edge."""
    c = cv.c
    if not c.small and drop > 0:
        sh = shift(blur(body, 18, c), 0, 12, c)
        cv.over((0, 0, 0), sh * drop)
    col = vgrad(c, top, bot)
    if glow > 0:
        g = radial(c, 512, 150, 620)[..., None] * glow
        col = col * (1 - g) + g
    cv.over(col, body)
    if c.small:
        return   # no rims/inner shadow at 16/32 px: they only muddy the edge
    # specular rim: top edge band, fading downward
    band = np.clip(body - shift(body, 0, 7, c), 0, 1)
    fade = np.clip(1 - ((np.arange(c.size) + 0.5) / c.px - INSET) / 520, 0, 1)[:, None]
    cv.over((1, 1, 1), blur(band, 1.2, c) * fade * rim)
    # side rims (very faint) - glass edge
    side = np.clip(body - shift(body, 4, 0, c) * shift(body, -4, 0, c), 0, 1)
    cv.over((1, 1, 1), blur(side, 1.0, c) * fade * rim * 0.35)
    # inner shadow at the bottom
    if inner_shadow > 0:
        bb = np.clip(body - shift(body, 0, -16, c), 0, 1)
        cv.over((0, 0, 0), blur(bb, 10, c) * body * inner_shadow)

def glassy(cv, m, body, fill_top, fill_bot, shadow=0.30, shadow_col=(10, 10, 40), lift=14,
           hl=0.65, shade=0.10, clip=True):
    """A soft foreground glyph: cast shadow, vertical fill, specular top edge, soft lower shade."""
    c = cv.c
    clipm = body if clip else 1.0
    if shadow > 0:
        r = 3 if c.small else (8 if c.mid else 16)
        s = shift(blur(m, r, c), 0, lift * (0.5 if c.small else 1), c)
        cv.over(rgb(shadow_col), s * shadow * clipm)
    y0, y1 = bbox_y(m, c)
    cv.over(vgrad(c, fill_top, fill_bot, y0, y1), m)
    if c.small: return
    if hl > 0:
        e = np.clip(m - shift(m, 0, 5, c), 0, 1)
        cv.over((1, 1, 1), blur(e, 0.8, c) * hl)
    if shade > 0:
        e = np.clip(m - shift(m, 0, -10, c), 0, 1)
        cv.over((0, 0, 0), blur(e, 4, c) * m * shade)

def bbox_y(m, c):
    rows = np.where(m.max(axis=1) > 0.05)[0]
    if len(rows) == 0: return INSET, 1024 - INSET
    return rows[0] / c.px, rows[-1] / c.px

# -- output ------------------------------------------------------------------------------
ICONSET = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

def write_appiconset(render, outdir):
    os.makedirs(outdir, exist_ok=True)
    cache = {}
    images = []
    for pt, sc in ICONSET:
        px = pt * sc
        if px not in cache: cache[px] = render(px)
        name = f"icon_{pt}x{pt}{'' if sc == 1 else '@2x'}.png"
        cache[px].save(os.path.join(outdir, name))
        images.append({"idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}", "filename": name})
    with open(os.path.join(outdir, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)

def main(render):
    # python make_icon.py [out.png]             -> one 1024 px PNG (same as before)
    # python make_icon.py --appiconset DIR      -> every .iconset size + Contents.json
    # python make_icon.py --size N out.png      -> one size, rendered natively
    a = sys.argv[1:]
    if a and a[0] in ("-h", "--help"):
        print("usage: make_icon.py [out.png] | --size N out.png | --appiconset DIR  (needs Pillow + numpy)")
        return
    if a and a[0] == "--appiconset":
        write_appiconset(render, a[1] if len(a) > 1 else "Resources/Assets.xcassets/AppIcon.appiconset")
    elif a and a[0] == "--size":
        render(int(a[1])).save(a[2])
    else:
        render(1024).save(a[0] if a else "icon_1024.png")

def stamp_mask(c, pts, radii):
    """A smooth variable-width stroke: discs stamped densely along a polyline."""
    img, d = c.blank()
    dense = []
    for (p, r), (q, s) in zip(zip(pts, radii), zip(pts[1:], radii[1:])):
        L = math.hypot(q[0] - p[0], q[1] - p[1]) * c.k
        n = max(1, int(L / 1.5))
        for j in range(n):
            t = j / n
            dense.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, r + (s - r) * t))
    dense.append((pts[-1][0], pts[-1][1], radii[-1]))
    for x, y, r in dense:
        x *= c.k; y *= c.k; r *= c.k
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return c.done(img)

# ---- Variant E: "Night Sky" -------------------------------------------------------------------------
# Matte near-black tile, a lavender capsule sound wave across the middle, sparkles around it.


def star_mask(c, cx, cy, r, p=0.42, round_=0.035):
    """4-point sparkle with rounded tips: superellipse |x|^p+|y|^p<=1 (p<1), tips softened."""
    R = c.R
    ys, xs = np.mgrid[0:R, 0:R].astype(np.float32)
    x = np.abs(xs + 0.5 - cx * c.k) / (r * c.k); y = np.abs(ys + 0.5 - cy * c.k) / (r * c.k)
    v = (x ** p + y ** p)
    m = (v <= 1.0).astype(np.uint8) * 255
    img = Image.fromarray(m)
    rr = round_ * r * c.k
    if rr >= 1:
        img = img.filter(ImageFilter.GaussianBlur(rr)).point(lambda t: 255 if t > 110 else 0)
    return c.done(img)

STARS = [  # (x, y, radius, opacity) in 1024 units, kept off the waveform
    (250, 236, 62, 0.95), (784, 258, 40, 0.8), (812, 772, 52, 0.9), (214, 784, 32, 0.65),
    (376, 170, 20, 0.55), (676, 166, 24, 0.6), (870, 520, 22, 0.55), (156, 508, 20, 0.5),
    (640, 856, 16, 0.5), (400, 868, 12, 0.4), (300, 690, 10, 0.35), (742, 380, 9, 0.35),
]

def render(size):
    c = Ctx(size)
    cv = Canvas(c)
    body = squircle(c)
    tile(cv, body, (30, 30, 34), (6, 6, 8), glow=0.0, rim=0.35, inner_shadow=0.0, drop=0.40)
    if not c.small:
        # hairline edge so the light tile holds its shape on light backgrounds
        edge = np.clip(body - shift(body, 0, -3, c) * shift(body, 0, 3, c) * shift(body, 3, 0, c) * shift(body, -3, 0, c), 0, 1)
        cv.over(rgb((255, 255, 255)), edge * 0.10)
    else:
        edge = np.clip(body - shift(body, 0, -24, c) * shift(body, 0, 24, c) * shift(body, 24, 0, c) * shift(body, -24, 0, c), 0, 1)
        cv.over(rgb((90, 90, 100)), edge * 0.6)

    if not c.small:
        for (sx, sy, sr, op) in STARS:
            sm = star_mask(c, sx, sy, sr) * body
            if sr >= 24:
                cv.over(rgb((170, 160, 255)), blur(sm, sr * 0.5, c) * 0.45 * op)   # soft glow
            cv.over(vgrad(c, (250, 248, 255), (200, 196, 255)), sm * op)
    L, Rr = 232, 792
    if c.small: L, Rr = 212, 812
    if size <= 16:
        hs, w, cy = [200, 420, 280], 150, 512
    elif c.small:
        hs, w, cy = [180, 380, 520, 340, 200], 96, 512
    else:
        hs, w, cy = [120, 250, 400, 540, 330, 460, 230, 130], 50, 512
    n = len(hs)
    step = (Rr - L - w) / (n - 1)
    ms = []
    for i, h in enumerate(hs):
        x = L + w / 2 + i * step
        ms.append(capsule_mask(c, x - w / 2, cy - h / 2, x + w / 2, cy + h / 2))
    wave = union(*ms)
    glassy(cv, wave, body, (186, 188, 255), (134, 128, 246), shadow=0.30, shadow_col=(0, 0, 0),
           lift=10, hl=0.38, shade=0.0)
    return cv.image()

if __name__ == "__main__":
    main(render)

# Scribe 0.4 app icon: a fountain-pen nib on a deep indigo rounded square (macOS grid:
# 1024 canvas, 824 body, ~185 corner). Pure vector math rendered with 4x supersampling.
from PIL import Image, ImageDraw, ImageFilter
import math, sys
S = 4
N = 1024 * S

def bez(p0, p1, p2, p3, n=60):
    out = []
    for i in range(n + 1):
        t = i / n; u = 1 - t
        out.append((u**3*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t**3*p3[0],
                    u**3*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t**3*p3[1]))
    return out

def quad(p0, c, p1, n=20):
    return [((1-t)**2*p0[0] + 2*(1-t)*t*c[0] + t*t*p1[0], (1-t)**2*p0[1] + 2*(1-t)*t*c[1] + t*t*p1[1])
            for t in [i/n for i in range(n+1)]]

# Nib in a 100x100 box, tip at the bottom (same numbers as NibShape.swift).
def nib_outline():
    pts = []
    pts += bez((50, 96), (45, 82), (27, 64), (27, 47))          # tip -> left shoulder
    pts += [(28.5, 24)]
    pts += quad((28.5, 24), (29, 15), (38, 15))
    pts += [(62, 15)]
    pts += quad((62, 15), (71, 15), (71.5, 24))
    pts += [(73, 47)]
    pts += bez((73, 47), (73, 64), (55, 82), (50, 96))
    return pts

def transform(pts, cx, cy, scale, angle):
    a = math.radians(angle); ca, sa = math.cos(a), math.sin(a)
    out = []
    for x, y in pts:
        x -= 50; y -= 55
        out.append((cx + scale * (x*ca - y*sa), cy + scale * (x*sa + y*ca)))
    return out

def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m

def render(out_path):
    inset = 100 * S; radius = 185 * S
    # Background: deep indigo, very subtle top-to-bottom gradient.
    top, bot = (76, 81, 191), (44, 46, 128)
    grad = Image.new("RGB", (1, N))
    for y in range(N):
        t = y / (N - 1)
        grad.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    grad = grad.resize((N, N))
    icon = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    body = squircle_mask(N, inset, radius)
    # Soft drop shadow under the tile (like first-party icons).
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    shm = squircle_mask(N, inset, radius).filter(ImageFilter.GaussianBlur(14 * S))
    sh.putalpha(shm.point(lambda v: int(v * 0.30)))
    sh = sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -10 * S))
    icon.alpha_composite(sh)
    tile = grad.convert("RGBA"); tile.putalpha(body)
    icon.alpha_composite(tile)
    # Hairline top highlight inside the tile.
    hl = Image.new("L", (N, N), 0)
    ImageDraw.Draw(hl).rounded_rectangle([inset, inset, N - inset, N - inset], radius=radius, outline=255, width=3 * S)
    hl = Image.composite(hl, Image.new("L", (N, N), 0), Image.linear_gradient("L").rotate(180).resize((N, N)))
    white = Image.new("RGBA", (N, N), (255, 255, 255, 0)); white.putalpha(hl.point(lambda v: int(v * 0.25)))
    icon.alpha_composite(white)

    cx, cy, sc, ang = 482 * S, 545 * S, 5.8 * S, 45
    outline = transform(nib_outline(), cx, cy, sc, ang)
    nib = Image.new("L", (N, N), 0)
    d = ImageDraw.Draw(nib)
    d.polygon(outline, fill=255)
    # Slit + breather hole cut out.
    hole_c = transform([(50, 52)], cx, cy, sc, ang)[0]
    r = 5.2 * sc
    d.ellipse([hole_c[0] - r, hole_c[1] - r, hole_c[0] + r, hole_c[1] + r], fill=0)
    slit = transform([(48.9, 56), (51.1, 56), (50.6, 93), (49.4, 93)], cx, cy, sc, ang)
    d.polygon(slit, fill=0)
    # Collar line across the top of the nib.
    collar = transform([(28.6, 27), (71.4, 27), (71.5, 29.6), (28.5, 29.6)], cx, cy, sc, ang)
    d.polygon(collar, fill=0)
    # Nib shadow.
    nsh = nib.filter(ImageFilter.GaussianBlur(10 * S)).point(lambda v: int(v * 0.35))
    shadow = Image.new("RGBA", (N, N), (10, 10, 40, 0)); shadow.putalpha(nsh)
    shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -12 * S))
    icon.alpha_composite(shadow)
    # Two-tone nib: lit left facet white, right facet a cool light gray (split along the slit).
    face = Image.new("RGBA", (N, N), (246, 247, 255, 255))
    right = Image.new("L", (N, N), 0)
    half = transform([(50, 0), (120, 0), (120, 120), (50, 120)], cx, cy, sc, ang)
    ImageDraw.Draw(right).polygon(half, fill=255)
    shade = Image.new("RGBA", (N, N), (214, 218, 240, 255))
    face = Image.composite(shade, face, right)
    face.putalpha(Image.composite(nib, Image.new("L", (N, N), 0), body))
    icon.alpha_composite(face)
    icon = icon.resize((1024, 1024), Image.LANCZOS)
    icon.save(out_path)

render(sys.argv[1] if len(sys.argv) > 1 else "icon_1024.png")

#!/usr/bin/env python3
# Scribe 0.7.2 app icon as an Icon Composer document (Resources/AppIcon.icon) so macOS 26 can
# switch it with the Mac's look:
#   Default (light) -> "Waves": warm paper tile, indigo-lavender capsule wave, faint sparkles (icon D)
#   Dark            -> "Night Sky": near-black tile, lavender wave, bright sparkles      (icon E)
#   Tinted / Clear  -> white wave + white sparkles on glass                              (icon F)
# The tile color is the document's background fill (one per appearance); the wave and the
# sparkles are two image layers with one picture per appearance (image-name-specializations).
# Older macOS (14/15) keeps using Resources/Assets.xcassets/AppIcon.appiconset (scripts/make_icon.py).
#
# REQUIRES: Python 3 + Pillow + numpy.   Usage: python3 scripts/make_icon_composer.py [Resources/AppIcon.icon]
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 1024            # Icon Composer canvas = the icon body (the system adds the shape + margins)
SS = 2              # supersampling

def body_to_canvas(v):
    """The 0.7 generators draw on a 1024 grid whose body is 824 px wide starting at 100."""
    return (v - 100) * S / 824.0

def capsule(d, x0, y0, x1, y1):
    r = min(x1 - x0, y1 - y0) / 2.0
    d.rounded_rectangle([x0 * SS, y0 * SS, x1 * SS, y1 * SS], radius=r * SS, fill=255)

def wave_mask():
    img = Image.new("L", (S * SS, S * SS), 0)
    d = ImageDraw.Draw(img)
    L, R = 232, 792
    hs, w, cy = [120, 250, 400, 540, 330, 460, 230, 130], 50, 512
    step = (R - L - w) / (len(hs) - 1)
    for i, h in enumerate(hs):
        x = L + w / 2 + i * step
        capsule(d, body_to_canvas(x - w / 2), body_to_canvas(cy - h / 2), body_to_canvas(x + w / 2), body_to_canvas(cy + h / 2))
    return np.asarray(img.resize((S, S), Image.LANCZOS), dtype=np.float32) / 255.0

STARS = [  # (x, y, radius, opacity) on the 0.7 grid, kept off the wave
    (250, 236, 62, 0.95), (784, 258, 40, 0.8), (812, 772, 52, 0.9), (214, 784, 32, 0.65),
    (376, 170, 20, 0.55), (676, 166, 24, 0.6), (870, 520, 22, 0.55), (156, 508, 20, 0.5),
    (640, 856, 16, 0.5), (400, 868, 12, 0.4), (300, 690, 10, 0.35), (742, 380, 9, 0.35),
]

def star_alpha(cx, cy, r, p=0.42):
    ys, xs = np.mgrid[0:S * SS, 0:S * SS].astype(np.float32)
    k = S * SS / 824.0
    X = np.abs(xs + 0.5 - body_to_canvas(cx) * SS) / (r * k)
    Y = np.abs(ys + 0.5 - body_to_canvas(cy) * SS) / (r * k)
    m = ((X ** p + Y ** p) <= 1.0).astype(np.uint8) * 255
    return np.asarray(Image.fromarray(m).resize((S, S), Image.LANCZOS), dtype=np.float32) / 255.0

def stars_alpha(scale):
    a = np.zeros((S, S), np.float32)
    for (x, y, r, op) in STARS:
        a = np.maximum(a, star_alpha(x, y, r) * op * scale)
    return a

def vgrad(top, bottom):
    t = np.linspace(0, 1, S, dtype=np.float32)[:, None, None]
    return np.array(top, np.float32)[None, None, :] * (1 - t) + np.array(bottom, np.float32)[None, None, :] * t

def rgba(color_img, alpha):
    rgb = np.broadcast_to(color_img, (S, S, 3))
    out = np.dstack([rgb, alpha[..., None] * 255]).clip(0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")

def srgb(r, g, b):
    return "extended-srgb:%.5f,%.5f,%.5f,1.00000" % (r / 255, g / 255, b / 255)

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.icon"
    assets = os.path.join(out, "Assets")
    os.makedirs(assets, exist_ok=True)
    wave = wave_mask()
    s_light, s_dark, s_tint = stars_alpha(0.55), stars_alpha(1.0), stars_alpha(0.9)
    rgba(vgrad((112, 116, 234), (60, 58, 164)), wave).save(os.path.join(assets, "wave-light.png"))
    rgba(vgrad((186, 188, 255), (134, 128, 246)), wave).save(os.path.join(assets, "wave-dark.png"))
    rgba(vgrad((255, 255, 255), (236, 238, 250)), wave).save(os.path.join(assets, "wave-tinted.png"))
    rgba(vgrad((130, 124, 236), (96, 90, 210)), s_light).save(os.path.join(assets, "stars-light.png"))
    rgba(vgrad((250, 248, 255), (200, 196, 255)), s_dark).save(os.path.join(assets, "stars-dark.png"))
    rgba(vgrad((255, 255, 255), (236, 238, 250)), s_tint).save(os.path.join(assets, "stars-tinted.png"))

    def layer(name):
        return {
            "name": name,
            "image-name-specializations": [
                {"value": f"{name}-light.png"},
                {"appearance": "dark", "value": f"{name}-dark.png"},
                {"appearance": "tinted", "value": f"{name}-tinted.png"},
            ],
            "glass": False,
        }
    doc = {
        "fill-specializations": [
            {"value": {"linear-gradient": [srgb(255, 253, 249), srgb(236, 228, 216)]}},
            {"appearance": "dark", "value": {"linear-gradient": [srgb(30, 30, 34), srgb(6, 6, 8)]}},
        ],
        "groups": [
            {
                "name": "Night Sky",
                "layers": [layer("stars"), layer("wave")],   # bottom → top
                "shadow": {"kind": "neutral", "opacity": 0.25},
                "specular": False,
                "translucency": {"enabled": False, "value": 0.5},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(out, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
    print("wrote", out)

if __name__ == "__main__":
    main()

"""Build Scribe.ico from the Mac app icon PNG (falls back to a drawn icon)."""
import sys
from pathlib import Path

from PIL import Image

here = Path(__file__).resolve().parent
src = here.parents[1] / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_256x256.png"
out = here / "Scribe.ico"
if src.exists():
    img = Image.open(src).convert("RGBA")
else:
    sys.path.insert(0, str(here.parent))
    from scribe.app import make_tray_image

    img = make_tray_image().resize((256, 256))
img.save(out, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("wrote", out)

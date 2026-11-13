"""The in-app rebrand's raster assets on Buzz 1.0 (cone-buzz-infra Slice 51;
the method of Slice 36's script in ConeDigital/cone-buzz).

Run from the repository root (uv from hermit, or any uv):
  uv run --with resvg-py==0.5.0 --with Pillow==12.2.0 python cone/rebrand/make-rebrand-assets.py

Inputs (tracked):
  cone/rebrand/wordmark.svg      the Cone wordmark as delivered (777x326, white rect, lettering top-left)
  cone/icons/icon-1024.png       the app icon tile (Slice 29)

Outputs (tracked, under cone/rebrand/files/, each replacing the upstream file of the same path):
  public/buzz-wordmark.png       the wordmark's glyphs fitted to upstream's 777x326 box, dark on
                                 transparent: the welcome screen recolours its alpha in a shader
                                 and uses it as a mask (src/features/identity/OnboardingWordmark.tsx)
  public/app-icon.png            the app icon at 512 px (the centre of the pairing QR code, src-tauri/src/qr.rs)

The SVG replacements (public/buzz-mark.svg, buzz-loading-mark.svg, welcome-bee.svg) are written by
hand from cone/rebrand/mark.svg.
"""

from __future__ import annotations

import io
import re
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "cone" / "rebrand"
FILES = HERE / "files"
WORDMARK_SVG = HERE / "wordmark.svg"
ICON_1024 = ROOT / "cone" / "icons" / "icon-1024.png"

BOX = (777, 326)  # upstream's public/buzz-wordmark.png
MARGIN = (28, 22)  # upstream's glyphs leave about this much on each side
INK = "#231E1F"


def render(svg: str, width: int) -> Image.Image:
    png = resvg_py.svg_to_bytes(svg_string=svg, width=width)
    return Image.open(io.BytesIO(bytes(png))).convert("RGBA")


def wordmark_png() -> None:
    svg = WORDMARK_SVG.read_text()
    svg = re.sub(r'<rect width="777" height="326" fill="white"\s*/>', "", svg)
    svg = svg.replace('fill="#241F1F"', f'fill="{INK}"')
    probe = render(svg, 7770)  # 10x, for a tight crop
    bbox = probe.getchannel("A").getbbox()
    assert bbox, "wordmark renders empty"
    x0, y0, x1, y1 = (v / 10 for v in bbox)
    w, h = x1 - x0, y1 - y0
    inner = (BOX[0] - 2 * MARGIN[0], BOX[1] - 2 * MARGIN[1])
    scale = min(inner[0] / w, inner[1] / h)
    # A viewBox the box's aspect, the glyphs centred in it at `scale`.
    vw, vh = BOX[0] / scale, BOX[1] / scale
    vx, vy = x0 - (vw - w) / 2, y0 - (vh - h) / 2
    vb = f"{vx:.2f} {vy:.2f} {vw:.2f} {vh:.2f}"
    svg = re.sub(r'width="777" height="326" viewBox="0 0 777 326"', f'viewBox="{vb}"', svg)
    assert f'viewBox="{vb}"' in svg, "viewBox not rewritten"
    out = render(svg, BOX[0])
    assert out.size == BOX, out.size
    target = FILES / "public" / "buzz-wordmark.png"
    target.parent.mkdir(parents=True, exist_ok=True)
    out.save(target, optimize=True)
    print(f"wordmark: {target.relative_to(ROOT)} {out.size}, viewBox {vb}")


def app_icon() -> None:
    tile = Image.open(ICON_1024).convert("RGBA")
    target = FILES / "public" / "app-icon.png"
    tile.resize((512, 512), Image.LANCZOS).save(target, optimize=True)
    print(f"app icon: {target.relative_to(ROOT)} 512px")


if __name__ == "__main__":
    wordmark_png()
    app_icon()

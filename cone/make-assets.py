"""Cone Desktop image assets, from cone/icons/source.png (Slice 29 decision 4;
carried unchanged to the Buzz 1.0 base by Slice 48).

Run from the repository root:  bin/uv run --with Pillow==12.2.0 python cone/make-assets.py
then:                          bin/pnpm tauri icon cone/icons/icon-1024.png -o cone/icons
then once more (`tauri icon` writes its own icon.ico from the macOS tile):
                               bin/uv run --with Pillow==12.2.0 python cone/make-assets.py ico

Writes cone/icons/icon-1024.png — the artwork on a white tile, 824 px with
185 px corners on a 1024 px canvas, the inset upstream's
scripts/generate-macos-icon.py uses — and cone/icons/dmg-background.png at
the size and layout of upstream's (1320x1000, the white panel where Finder
draws the app and Applications icons).

`ico` writes cone/icons/icon.ico alone: the Windows icon (the exe, the
installer, the taskbar, the window), the mark full-bleed on transparency —
Windows draws no tile, so the macOS tile's inset would show a small mark —
in the frames and order `tauri icon` writes (32, 16, 24, 48, 64, 256 px, each
a PNG). Only Windows reads the .ico.
"""
import io
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

S = 4
ICONS = "cone/icons"
ORANGE, PURPLE, INK = (249, 115, 22), (118, 31, 107), (28, 25, 23)


def tile():
    with Image.open(f"{ICONS}/source.png") as im:
        art = im.convert("RGBA")
    bg = Image.new("RGBA", art.size, (255, 255, 255, 255))
    bg.alpha_composite(art)
    t = bg.resize((824 * S, 824 * S), Image.Resampling.LANCZOS)
    mask = Image.new("L", t.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, t.width - 1, t.height - 1), radius=185 * S, fill=255)
    canvas = Image.new("RGBA", (1024 * S, 1024 * S))
    canvas.paste(t, (100 * S, 100 * S), mask)
    canvas.resize((1024, 1024), Image.Resampling.LANCZOS).save(f"{ICONS}/icon-1024.png")


def windows_icon():
    with Image.open(f"{ICONS}/source.png") as im:
        art = im.convert("RGBA")
    art = art.crop(art.getchannel("A").getbbox())
    side = 1024
    scale = side * 0.96 / max(art.size)
    art = art.resize((round(art.width * scale), round(art.height * scale)), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (side, side))
    canvas.alpha_composite(art, ((side - art.width) // 2, (side - art.height) // 2))
    frames = []
    for size in (32, 16, 24, 48, 64, 256):
        buf = io.BytesIO()
        canvas.resize((size, size), Image.Resampling.LANCZOS).save(buf, "PNG", optimize=True)
        frames.append((size, buf.getvalue()))
    out = struct.pack("<HHH", 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    for size, data in frames:
        out += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(f"{ICONS}/icon.ico", "wb") as f:
        f.write(out + b"".join(data for _, data in frames))


def font(size, bold):
    for path in ("/System/Library/Fonts/HelveticaNeue.ttc", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size, index=1 if bold else 0)
        except OSError:
            continue
    return ImageFont.load_default()


def dmg_background():
    w, h = 1320, 1000
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        f = y / (h - 1)
        top = tuple(int(255 - (255 - c) * 0.22) for c in ORANGE)
        bottom = tuple(int(255 - (255 - c) * 0.16) for c in PURPLE)
        row = tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3))
        for x in range(w):
            px[x, y] = row
    d = ImageDraw.Draw(img)
    with Image.open(f"{ICONS}/source.png") as im:
        mark = im.convert("RGBA").resize((150, 150), Image.Resampling.LANCZOS)
    img.paste(mark, ((w - 150) // 2, 60), mark)
    title, sub = font(92, True), font(40, False)
    for text, f, y in (("Cone", title, 215), ("Drag Cone to Applications", sub, 330)):
        tw = d.textlength(text, font=f)
        d.text(((w - tw) / 2, y), text, font=f, fill=INK)
    d.rounded_rectangle((108, 408, 1212, 935), radius=56, fill=(255, 255, 255))
    img.save(f"{ICONS}/dmg-background.png")


if __name__ == "__main__":
    if sys.argv[1:] == ["ico"]:
        windows_icon()
    else:
        tile()
        dmg_background()

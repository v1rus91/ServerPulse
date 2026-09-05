"""Іконка ServerPulse: скляний squircle з градієнтом і пульсом (ЕКГ) над сервером."""
import shutil, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
HERE = Path(__file__).parent; OUT = HERE.parent / "Resources"; SIZE = 1024
def mask(size, r=0.225):
    m = Image.new("L", (size, size), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * r), fill=255); return m
def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size)); px = img.load()
    for y in range(size):
        t = y / (size - 1); row = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size): px[x, y] = row
    return img
def render(size=SIZE):
    inner = int(size * 0.82); off = (size - inner) // 2
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sh = Image.new("RGBA", (inner, inner), (0, 0, 0, 110)); sh.putalpha(mask(inner))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0)); shadow.paste(sh, (off, off + int(size * 0.02)), sh)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(size * 0.02)))
    body = gradient(inner, (20, 160, 110), (10, 70, 120)).convert("RGBA"); body.putalpha(mask(inner)); canvas.alpha_composite(body, (off, off))
    d = ImageDraw.Draw(canvas); cx, cy = size / 2, size / 2; u = inner; white = (255, 255, 255, 255); glass = (255, 255, 255, 60)
    # стійка сервера (два юніти)
    for i, yy in enumerate((0.02, 0.19)):
        y = cy + u * yy
        d.rounded_rectangle((cx - u * 0.30, y, cx + u * 0.30, y + u * 0.13), radius=int(u * 0.03), fill=glass, outline=white, width=int(u * 0.022))
        d.ellipse((cx + u * 0.20, y + u * 0.045, cx + u * 0.24, y + u * 0.085), fill=(120, 255, 170, 255) if i == 0 else (255, 210, 90, 255))
        for k in range(3): d.rounded_rectangle((cx - u * 0.26 + k * u * 0.055, y + u * 0.05, cx - u * 0.23 + k * u * 0.055, y + u * 0.08), radius=int(u*0.01), fill=white)
    # пульс (ЕКГ) над стійкою
    pts = [(cx - u * 0.34, cy - u * 0.14), (cx - u * 0.16, cy - u * 0.14), (cx - u * 0.10, cy - u * 0.30), (cx - u * 0.03, cy - u * 0.02), (cx + u * 0.04, cy - u * 0.36), (cx + u * 0.10, cy - u * 0.14), (cx + u * 0.34, cy - u * 0.14)]
    d.line(pts, fill=white, width=int(u * 0.045), joint="curve")
    return canvas
iconset = HERE / "ServerPulse.iconset"; shutil.rmtree(iconset, ignore_errors=True); iconset.mkdir()
m = render(); m.save(OUT / "icon_1024.png")
for px in (16, 32, 128, 256, 512):
    m.resize((px, px), Image.LANCZOS).save(iconset / f"icon_{px}x{px}.png"); m.resize((px * 2, px * 2), Image.LANCZOS).save(iconset / f"icon_{px}x{px}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT / "ServerPulse.icns")], check=True); shutil.rmtree(iconset)
print("icon ->", OUT / "ServerPulse.icns")

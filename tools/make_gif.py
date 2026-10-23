"""Build a side-by-side GIF of the PPM frames written by `zig build run`.

Usage: python3 tools/make_gif.py [out_dir] [gif_path] [mode ...]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("out")
gif_path = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("comparison.gif")
modes = sys.argv[3:] or ["baseline", "stabilized"]

frame_names = sorted(p.name for p in (out_dir / modes[0]).glob("frame_*.ppm"))
gap, label_h = 16, 28
frames = []
for name in frame_names:
    panels = [Image.open(out_dir / m / name).convert("RGB") for m in modes]
    w, h = panels[0].size
    canvas = Image.new("RGB", (len(modes) * w + (len(modes) - 1) * gap, h + label_h), (20, 18, 26))
    draw = ImageDraw.Draw(canvas)
    for i, (mode, panel) in enumerate(zip(modes, panels)):
        x = i * (w + gap)
        canvas.paste(panel, (x, label_h))
        draw.text((x + 6, 8), mode, fill=(230, 230, 230))
    frames.append(canvas.quantize(colors=256))

frames[0].save(gif_path, save_all=True, append_images=frames[1:], duration=120, loop=0, optimize=True)
print(f"wrote {gif_path} ({len(frames)} frames)")

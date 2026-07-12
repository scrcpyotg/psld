#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
OUT_DIR = Path("PSLScanner/Assets.xcassets/AppIcon.appiconset")
PNG_PATH = OUT_DIR / "AppIcon-1024.png"


def clamp(value: int) -> int:
    return max(0, min(255, value))


pixels = bytearray(SIZE * SIZE * 4)

for y in range(SIZE):
    for x in range(SIZE):
        dx = (x - SIZE * 0.5) / SIZE
        dy = (y - SIZE * 0.44) / SIZE
        radius = math.sqrt(dx * dx + dy * dy)
        glow = max(0.0, 1.0 - radius * 2.2)
        vertical = 1.0 - y / SIZE
        r = clamp(int(5 + glow * 10 + vertical * 3))
        g = clamp(int(8 + glow * 20 + vertical * 5))
        b = clamp(int(12 + glow * 18 + vertical * 8))
        i = (y * SIZE + x) * 4
        pixels[i:i + 4] = bytes((r, g, b, 255))


def blend(x: int, y: int, color: tuple[int, int, int, int]) -> None:
    if not (0 <= x < SIZE and 0 <= y < SIZE):
        return
    i = (y * SIZE + x) * 4
    alpha = color[3] / 255.0
    inverse = 1.0 - alpha
    pixels[i] = clamp(int(pixels[i] * inverse + color[0] * alpha))
    pixels[i + 1] = clamp(int(pixels[i + 1] * inverse + color[1] * alpha))
    pixels[i + 2] = clamp(int(pixels[i + 2] * inverse + color[2] * alpha))
    pixels[i + 3] = 255


def disc(cx: int, cy: int, radius: int, color: tuple[int, int, int, int]) -> None:
    rr = radius * radius
    for py in range(cy - radius, cy + radius + 1):
        for px in range(cx - radius, cx + radius + 1):
            if (px - cx) ** 2 + (py - cy) ** 2 <= rr:
                blend(px, py, color)


def line(x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int, int], width: int = 4) -> None:
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    for step in range(steps + 1):
        t = step / steps
        x = round(x0 + (x1 - x0) * t)
        y = round(y0 + (y1 - y0) * t)
        disc(x, y, max(1, width // 2), color)


def polyline(points: list[tuple[int, int]], color: tuple[int, int, int, int], width: int = 4, closed: bool = False) -> None:
    pairs = list(zip(points, points[1:]))
    if closed and len(points) > 2:
        pairs.append((points[-1], points[0]))
    for start, end in pairs:
        line(start[0], start[1], end[0], end[1], color, width)


lime = (137, 255, 63, 235)
lime_soft = (110, 230, 50, 120)
mesh = (190, 235, 205, 110)
white = (242, 247, 245, 220)

# Scan corners.
corner = 165
length = 132
thickness = 22
line(corner, corner, corner + length, corner, lime, thickness)
line(corner, corner, corner, corner + length, lime, thickness)
line(SIZE - corner, corner, SIZE - corner - length, corner, lime, thickness)
line(SIZE - corner, corner, SIZE - corner, corner + length, lime, thickness)
line(corner, SIZE - corner, corner + length, SIZE - corner, lime, thickness)
line(corner, SIZE - corner, corner, SIZE - corner - length, lime, thickness)
line(SIZE - corner, SIZE - corner, SIZE - corner - length, SIZE - corner, lime, thickness)
line(SIZE - corner, SIZE - corner, SIZE - corner, SIZE - corner - length, lime, thickness)

# Stylized 3D face outline.
outline = [
    (512, 215), (415, 232), (347, 285), (314, 370), (320, 485),
    (344, 602), (395, 720), (461, 795), (512, 822), (563, 795),
    (629, 720), (680, 602), (704, 485), (710, 370), (677, 285), (609, 232),
]
polyline(outline, white, 7, closed=True)

# Horizontal mesh arcs.
mesh_rows = [
    [(375, 316), (438, 291), (512, 282), (586, 291), (649, 316)],
    [(337, 400), (414, 374), (512, 365), (610, 374), (687, 400)],
    [(328, 492), (408, 470), (512, 462), (616, 470), (696, 492)],
    [(347, 586), (421, 574), (512, 570), (603, 574), (677, 586)],
    [(389, 684), (450, 693), (512, 701), (574, 693), (635, 684)],
]
for row in mesh_rows:
    polyline(row, mesh, 4)

# Vertical and diagonal mesh lines.
for top, bottom in [
    ((512, 215), (512, 822)),
    ((415, 232), (461, 795)),
    ((609, 232), (563, 795)),
    ((347, 285), (395, 720)),
    ((677, 285), (629, 720)),
]:
    line(top[0], top[1], bottom[0], bottom[1], mesh, 4)

for start, end in [
    ((375, 316), (616, 470)), ((649, 316), (408, 470)),
    ((337, 400), (603, 574)), ((687, 400), (421, 574)),
    ((347, 586), (574, 693)), ((677, 586), (450, 693)),
]:
    line(start[0], start[1], end[0], end[1], lime_soft, 4)

# Eyes, nose and mouth.
polyline([(377, 426), (421, 408), (461, 425), (421, 443), (377, 426)], white, 7)
polyline([(563, 425), (603, 408), (647, 426), (603, 443), (563, 425)], white, 7)
disc(421, 426, 12, lime)
disc(603, 426, 12, lime)
polyline([(512, 405), (486, 535), (512, 558), (538, 535)], white, 7)
polyline([(438, 628), (480, 646), (512, 650), (544, 646), (586, 628)], white, 7)
polyline([(449, 646), (512, 669), (575, 646)], lime_soft, 5)

# Central scan axes and points.
line(512, 186, 512, 846, lime_soft, 3)
line(300, 492, 724, 492, lime_soft, 3)
for x, y in [(512, 282), (421, 374), (603, 374), (512, 462), (408, 470), (616, 470), (512, 570), (421, 574), (603, 574), (512, 701)]:
    disc(x, y, 8, lime)


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


raw = bytearray()
stride = SIZE * 4
for y in range(SIZE):
    raw.append(0)
    raw.extend(pixels[y * stride:(y + 1) * stride])

png = bytearray(b"\x89PNG\r\n\x1a\n")
png.extend(png_chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)))
png.extend(png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
png.extend(png_chunk(b"IEND", b""))

OUT_DIR.mkdir(parents=True, exist_ok=True)
PNG_PATH.write_bytes(png)

contents = {
    "images": [
        {
            "filename": PNG_PATH.name,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024"
        }
    ],
    "info": {"author": "xcode", "version": 1}
}
(OUT_DIR / "Contents.json").write_text(json.dumps(contents, indent=2), encoding="utf-8")

assets_root = OUT_DIR.parent
(assets_root / "Contents.json").write_text(
    json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2),
    encoding="utf-8"
)

print(f"Generated {PNG_PATH}")

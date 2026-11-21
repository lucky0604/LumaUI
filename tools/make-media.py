"""Generates LumaUI's own textures (no third-party media).

Run with the bundled Python; writes uncompressed 32-bit TGA files into Media/.
Everything here is produced from scratch: gradients, a soft vignette, a
sub-pixel edge and a quiet inset wash, all in neutral values so the theme
colours tint them at run time.

Usage:
    python tools/make-media.py [--output DIR]

--output writes the same images to DIR instead of Media/, so the shipped files
can be regenerated and compared without touching the release folder.
"""

import argparse
import os
from PIL import Image

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def save(image, name, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    image = image.convert("RGBA")
    image.save(path, format="TGA")
    return path


def panel(size=128):
    """Vertical gradient, light at the top, with a soft inner vignette."""
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        # 1.0 at the top fading to 0.68 at the bottom.
        vertical = 1.0 - (y / (size - 1)) * 0.32
        for x in range(size):
            # A gentle horizontal falloff towards both edges.
            edge = min(x, size - 1 - x) / (size / 2)
            horizontal = 0.82 + 0.18 * min(1.0, edge * 2)
            value = int(255 * vertical * horizontal)
            pixels[x, y] = (value, value, value, 255)
    return image


def bar(size=64):
    """Vertical shading for status bars: bright top, darker bottom."""
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        t = y / (size - 1)
        value = int(255 * (1.0 - 0.35 * t))
        for x in range(size):
            pixels[x, y] = (value, value, value, 255)
    return image


def rule(width=128, height=8):
    """A fade-out strip used for header bands: opaque left, clear right."""
    image = Image.new("RGBA", (width, height))
    pixels = image.load()
    for x in range(width):
        alpha = int(255 * (1.0 - x / (width - 1)) ** 1.6)
        for y in range(height):
            pixels[x, y] = (255, 255, 255, alpha)
    return image


def glow(size=64):
    """A soft radial glow for the active tab and hover highlights."""
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    centre = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            dx, dy = (x - centre) / centre, (y - centre) / centre
            distance = min(1.0, (dx * dx + dy * dy) ** 0.5)
            alpha = int(255 * (1.0 - distance) ** 2)
            pixels[x, y] = (255, 255, 255, alpha)
    return image


def inset(size=64):
    """A quiet vertical wash for embedded regions inside a window.

    Lighter at the top, a few percent darker at the bottom, with a very soft
    horizontal falloff so a flat rectangle does not read as a second window.
    Alpha stays opaque; the theme tint supplies the colour and the role opacity.
    """
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        vertical = 1.0 - (y / (size - 1)) * 0.16
        for x in range(size):
            edge = min(x, size - 1 - x) / (size / 2)
            horizontal = 0.94 + 0.06 * min(1.0, edge * 2)
            value = int(255 * vertical * horizontal)
            pixels[x, y] = (value, value, value, 255)
    return image


def main():
    parser = argparse.ArgumentParser(description="Generate LumaUI's own textures.")
    parser.add_argument("--output", default=os.path.join(ROOT, "Media"),
                        help="target directory (defaults to Media/)")
    args = parser.parse_args()
    out_dir = os.path.abspath(args.output)
    written = [
        save(panel(), "panel.tga", out_dir),
        save(bar(), "bar.tga", out_dir),
        save(rule(), "rule.tga", out_dir),
        save(glow(), "glow.tga", out_dir),
        save(inset(), "inset.tga", out_dir),
    ]
    for path in written:
        print(path, os.path.getsize(path))


if __name__ == "__main__":
    main()

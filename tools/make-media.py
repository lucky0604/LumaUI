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
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def save(image, name, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    image = image.convert("RGBA")
    image.save(path, format="TGA")
    return path


# The two nine-slice textures below are built to a fixed layout that UI/Surface.lua
# mirrors: PLATE_SIZE/PLATE_RADIUS/PLATE_MARGIN and the shadow inset. Changing one
# side without the other makes the corners either clip or blur, so the numbers live
# in this comment as well as in the Lua constants.
#
# A nine-slice margin has to cover the whole shape it protects: for the plate that
# is the corner radius, for the shadow it is inset + radius + blur. A margin that
# is too small does not fail loudly, it cuts the arc and leaves a seam, so the
# assertions below are the cheapest possible regression test.
PLATE_SIZE = 32
PLATE_RADIUS = 8
PLATE_MARGIN = 10
assert PLATE_MARGIN >= PLATE_RADIUS + 1, "plate margin must contain the corner arc"

SHADOW_SIZE = 96
SHADOW_INSET = 16
SHADOW_RADIUS = 12
SHADOW_BLUR = 6.0
SHADOW_MARGIN = 36
assert SHADOW_SIZE - 2 * SHADOW_MARGIN > 0, "shadow margin must leave a middle band"
assert SHADOW_MARGIN >= SHADOW_INSET + SHADOW_RADIUS + SHADOW_BLUR, "shadow margin must contain arc and blur"

SUPERSAMPLE = 4


def coverage(size, radius, inset=0):
    """Antialiased rounded-rect coverage, drawn 4x and downsampled.

    The supersample is what keeps a 1-pixel corner ramp instead of a stair step,
    and it is the only reason the texture is not simply drawn at final size.
    """
    big = size * SUPERSAMPLE
    edge = inset * SUPERSAMPLE
    image = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle([edge, edge, big - 1 - edge, big - 1 - edge],
                           radius=radius * SUPERSAMPLE, fill=255)
    return image.resize((size, size), Image.LANCZOS)


def plate():
    """A rounded card fill: white with the corner in the alpha channel.

    No border is baked in. The reference design separates surfaces by fill value
    and a soft shadow, not by a hairline around every box, so the theme can tint
    this one texture for cards, buttons and inset regions alike.
    """
    image = Image.new("RGBA", (PLATE_SIZE, PLATE_SIZE), (255, 255, 255, 0))
    image.putalpha(coverage(PLATE_SIZE, PLATE_RADIUS))
    return image


def shadow():
    """A soft drop shadow: black with an alpha ramp, stretched behind a card.

    The rounded rectangle sits inset by SHADOW_INSET so the blur has room to fade
    inside the texture; UI/Surface.lua then offsets the texture by the same inset
    when it draws, which puts the shadow edge back on the card edge.
    """
    alpha = coverage(SHADOW_SIZE, SHADOW_RADIUS, inset=SHADOW_INSET)
    alpha = alpha.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    image = Image.new("RGBA", (SHADOW_SIZE, SHADOW_SIZE), (0, 0, 0, 0))
    image.putalpha(alpha)
    return image


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
        save(plate(), "plate.tga", out_dir),
        save(shadow(), "shadow.tga", out_dir),
    ]
    for path in written:
        print(path, os.path.getsize(path))


if __name__ == "__main__":
    main()

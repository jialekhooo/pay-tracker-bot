#!/usr/bin/env python3
"""Turn real simulator captures into App Store screenshot cards.

1. Capture the screens on a 6.9" simulator (iPhone Pro Max, 1320 x 2868):
     TEST_RUNNER_STORE_SHOTS_DIR=<captures> xcodebuild test -project ios/HowMuch.xcodeproj \
       -scheme HowMuch -destination 'id=<Pro Max simulator>' \
       -only-testing:HowMuchUITests/HowMuchUITests/testStoreScreenshots
2. python3 ios/scripts/make_store_cards.py <captures> <output folder>   (needs Pillow)

Writes opaque RGB PNGs at 6.9" (1320 x 2868) and 6.5" (1284 x 2778).
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROUNDED = "/System/Library/Fonts/SFNSRounded.ttf"
TEXT = "/System/Library/Fonts/SFNS.ttf"

INK = (24, 59, 55)
MUTED = (52, 92, 84)
BRAND = (184, 219, 203)  # Penny's light teal, the app icon background
BRAND_LIGHT = (226, 241, 233)
NIGHT = (14, 38, 34)
NIGHT_LIGHT = (24, 62, 55)

# (capture, headline, subline, dark card)
CARDS = [
    ("overview", "Know exactly\nwhat you're owed", "Paid, pending and booked, all in one place", False),
    ("paste-job", "Paste a job.\nShifts fill in.", "Dates, times and place from any job message", False),
    ("calendar", "Your month\nat a glance", "Every shift, and share when you're free", False),
    ("earnings", "Every event,\nevery dollar", "See what's paid and what's still to come", False),
    ("penny", "Meet Penny,\nyour pay pet", "She grows as you work and get paid", False),
    ("friend-visit", "Visit friends'\npets and say hi", "You both get coins. Shifts and pay stay private.", False),
    ("overview-dark", "Easy on the eyes\nat night", "Light, Dark, or match your iPhone", True),
]


def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    f.set_variation_by_name(weight)
    return f


def gradient(size, top, bottom):
    w, h = size
    column = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((w, h))


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return mask


def card(capture, headline, subline, dark, size):
    w, h = size
    s = w / 1320  # layout scale
    canvas = gradient(size, NIGHT_LIGHT if dark else BRAND, NIGHT if dark else BRAND_LIGHT)
    draw = ImageDraw.Draw(canvas)
    ink = (236, 246, 241) if dark else INK
    muted = (160, 205, 190) if dark else MUTED

    # Headline and subline, centred.
    title = font(ROUNDED, round(118 * s), "Bold")
    y = round(190 * s)
    for line in headline.split("\n"):
        box = draw.textbbox((0, 0), line, font=title)
        draw.text(((w - (box[2] - box[0])) / 2 - box[0], y), line, font=title, fill=ink)
        y += round(140 * s)
    sub = font(TEXT, round(50 * s), "Medium")
    box = draw.textbbox((0, 0), subline, font=sub)
    draw.text(((w - (box[2] - box[0])) / 2 - box[0], y + round(34 * s)), subline, font=sub, fill=muted)

    # Phone: the real capture inside a thin bezel, with a soft shadow.
    phone_top = round(700 * s)
    screen_h = h - phone_top - round(120 * s)
    shot = Image.open(capture).convert("RGB")
    screen_w = round(shot.width * screen_h / shot.height)
    shot = shot.resize((screen_w, screen_h), Image.LANCZOS)
    bezel = round(22 * s)
    radius = round(150 * s)
    frame = (screen_w + 2 * bezel, screen_h + 2 * bezel)
    x = (w - frame[0]) // 2

    shadow = Image.new("L", size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, phone_top + round(30 * s), x + frame[0], phone_top + frame[1] + round(30 * s)), radius + bezel, fill=110 if not dark else 160)
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(50 * s)))
    canvas.paste(Image.new("RGB", size, (8, 30, 26)), (0, 0), shadow)

    body = Image.new("RGB", frame, (16, 22, 21))
    canvas.paste(body, (x, phone_top), rounded_mask(frame, radius + bezel))
    canvas.paste(shot, (x + bezel, phone_top + bezel), rounded_mask((screen_w, screen_h), radius))
    edge = (64, 84, 80) if dark else (44, 58, 55)
    ImageDraw.Draw(canvas).rounded_rectangle((x, phone_top, x + frame[0] - 1, phone_top + frame[1] - 1), radius + bezel, outline=edge, width=max(2, round(4 * s)))
    return canvas


def main():
    captures, out = Path(sys.argv[1]), Path(sys.argv[2])
    for label, size in (("6.9in-1320x2868", (1320, 2868)), ("6.5in-1284x2778", (1284, 2778))):
        folder = out / label
        folder.mkdir(parents=True, exist_ok=True)
        for i, (name, headline, subline, dark) in enumerate(CARDS, 1):
            image = card(captures / f"{name}.png", headline, subline, dark, size)
            assert image.mode == "RGB" and image.size == size
            image.save(folder / f"{i:02d}-{name}.png", optimize=True)
        print(folder)


if __name__ == "__main__":
    main()

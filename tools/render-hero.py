#!/usr/bin/env python3
"""Setzt das Terminalfenster im Hero-Bild neu.

Das Hintergrundbild ist gestaltet und bleibt, wie es ist. Nur das Fenster wird neu
gezeichnet, damit der Text stimmt: Bildmodelle rendern dichten Monospace nicht
zuverlässig, und eine Statusline, die im Werbebild anders aussieht als im Terminal,
ist schlimmer als gar kein Bild.

Gerendert wird in doppelter Auflösung, sonst wird die längste Zeile zu klein zum Lesen.

    python3 tools/render-hero.py assets/hero-bg.png assets/hero.png
"""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FONT = "/Users/chris/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf"
FONT_BOLD = "/Users/chris/Library/Fonts/JetBrainsMonoNerdFont-Bold.ttf"

SCALE = 2
PANEL = (1420, 668, 3010, 1442)   # Fensterrechteck im 2x-Bild, deckt das alte ab
RADIUS = 44
PAD_X, PAD_TOP = 56, 158
FONT_SIZE = 34
LINE_H = 146

# Die dritte Beschriftung der Merkmalsleiste warb fuer die entfernten agt/skl-Segmente.
# Der Untergrund dort ist praktisch schwarz, ein Rechteck darauf faellt nicht auf.
LABEL_BOX = (1156, 1288, 1444, 1372)
LABEL_POS = (1164, 1306)
LABEL_TEXT = "Multi-account"
LABEL_FONT = "/System/Library/Fonts/Helvetica.ttc"
LABEL_SIZE = 40
LABEL_FG = (232, 232, 234)

BG = (14, 14, 16)
BAR = (30, 30, 34)
FRAME = (232, 122, 58)
DIM = (110, 110, 118)

CYAN = (94, 234, 255)
GREEN = (126, 231, 135)
MAGENTA = (226, 145, 240)
YELLOW = (240, 208, 108)
ORANGE = (232, 140, 74)
RED = (240, 112, 106)
WHITE = (228, 228, 232)

# Jede Zeile ist eine Folge aus (Text, Farbe, fett). "|" trennt Segmente wie im Skript.
SEP = (" | ", DIM, False)
LINES = [
    [("~/Sites/my-project", CYAN, True), SEP, (" main", GREEN, False)],
    [("Opus 5", MAGENTA, False), SEP, ("effort high", MAGENTA, False)],
    [("ctxQ A(92)", GREEN, False), SEP,
     ("ctx ", GREEN, False), ("BAR", 3, 10), (" 28% (280k/1M)", GREEN, False),
     SEP, ("cache 47m12s/1h", CYAN, False)],
    [("5h A 42% (1h58m) B free", GREEN, False), SEP,
     ("wk A 18% (5.1d) B 78% (0.9d)", YELLOW, False), SEP,
     ("rw 1.8d", GREEN, False), SEP, ("-> B", RED, True)],
]


def draw_bar(d, x, y, filled, cells):
    """Zeichnet den Kontextbalken als Zellen. Als Schattierungszeichen gesetzt
    verschwimmt er bei dieser Groesse zu einem Punktmuster."""
    w, h, gap = 26, 30, 6
    for i in range(cells):
        box = (x + i * (w + gap), y + 4, x + i * (w + gap) + w, y + 4 + h)
        if i < filled:
            d.rectangle(box, fill=ORANGE + (255,))
        else:
            d.rectangle(box, outline=(96, 96, 104, 255), width=2)
    return x + cells * (w + gap)


def repair_label_background(layer, base, box):
    """Fuellt den Bereich der alten Beschriftung mit einer Bildzeile von oberhalb.
    Der Untergrund hat dort einen Verlauf; eine feste Farbe wuerde als Kasten
    sichtbar bleiben."""
    x0, y0, x1, y1 = box
    strip = base.crop((x0, y0 - 26, x1, y0 - 22)).resize((x1 - x0, y1 - y0))
    layer.paste(strip.convert("RGBA"), (x0, y0))


def draw_panel(size, base):
    """Zeichnet Fenster samt Schein auf einer eigenen Ebene mit Alphakanal."""
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = PANEL

    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle(
        (x0 - 6, y0 - 6, x1 + 6, y1 + 6), RADIUS + 6, outline=FRAME + (220,), width=10)
    layer.alpha_composite(glow.filter(ImageFilter.GaussianBlur(14)))

    d.rounded_rectangle((x0, y0, x1, y1), RADIUS, fill=BG + (255,), outline=FRAME + (255,), width=4)
    d.rounded_rectangle((x0 + 4, y0 + 4, x1 - 4, y0 + 76), RADIUS - 8, fill=BAR + (255,))
    d.rectangle((x0 + 4, y0 + 48, x1 - 4, y0 + 80), fill=BAR + (255,))
    for i, col in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = x0 + 46 + i * 46
        d.ellipse((cx - 13, y0 + 27, cx + 13, y0 + 53), fill=col + (255,))

    font = ImageFont.truetype(FONT, FONT_SIZE)
    font_bold = ImageFont.truetype(FONT_BOLD, FONT_SIZE)
    for row, parts in enumerate(LINES):
        x = x0 + PAD_X
        y = y0 + PAD_TOP + row * LINE_H
        for text, colour, bold in parts:
            if text == "BAR":
                x = draw_bar(d, x, y, filled=colour, cells=bold)
                continue
            f = font_bold if bold else font
            d.text((x, y), text, font=f, fill=colour + (255,))
            x += d.textlength(text, font=f)
    repair_label_background(layer, base, LABEL_BOX)
    d.text(LABEL_POS, LABEL_TEXT, font=ImageFont.truetype(LABEL_FONT, LABEL_SIZE),
           fill=LABEL_FG + (255,))
    return layer


def main():
    src, dst = sys.argv[1], sys.argv[2]
    base = Image.open(src).convert("RGBA")
    big = base.resize((base.width * SCALE, base.height * SCALE), Image.LANCZOS)
    big.alpha_composite(draw_panel(big.size, big))
    # Auf eine Palette reduzieren: spart bei diesem Motiv rund 40 Prozent, ohne dass
    # der Text darunter leidet.
    out = big.convert("RGB").quantize(colors=255, method=Image.MEDIANCUT,
                                      dither=Image.FLOYDSTEINBERG)
    out.save(dst, optimize=True)
    print(f"{dst}: {big.width}x{big.height}")


if __name__ == "__main__":
    main()

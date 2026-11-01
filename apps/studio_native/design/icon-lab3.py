# icon-lab3.py - third pass: FLC mark = striker bar + spark (no flint slab), settings glyphs.
# 8x supersample -> LANCZOS down, so the 16/24 px tiles show the real limit.
import os, math
from PIL import Image, ImageDraw

S = 8
OUT = os.path.dirname(os.path.abspath(__file__))

BG       = (30, 30, 30)
PANEL    = (37, 37, 38)
SPARK    = (255, 176, 78)
SPARK_HI = (255, 242, 214)
STEEL    = (198, 210, 226)
STEEL_MID= (150, 162, 180)
STEEL_D  = (96, 106, 124)


def canvas(n=64):
    return Image.new("RGBA", (n * S, n * S), (0, 0, 0, 0))


def s(v):
    return int(round(v * S))


def poly(d, pts, fill):
    d.polygon([(s(p[0]), s(p[1])) for p in pts], fill=fill)


def star4(d, cx, cy, R, r, fill, rot=0.0):
    pts = []
    for i in range(8):
        a = rot + i * math.pi / 4
        rad = R if i % 2 == 0 else r
        pts.append((cx + rad * math.cos(a), cy + rad * math.sin(a)))
    poly(d, pts, fill)


def gear(d, cx, cy, r_out, r_ring, teeth, fill, hole=None, tooth_w=0.7):
    d.ellipse([s(cx - r_ring), s(cy - r_ring), s(cx + r_ring), s(cy + r_ring)], fill=fill)
    tw = (2 * math.pi * r_ring / teeth) * tooth_w
    for i in range(teeth):
        a = i * 2 * math.pi / teeth
        ca, sa = math.cos(a), math.sin(a)
        pa, pb = -sa, ca
        pts = [
            (cx + ca * (r_ring - 2.2) + pa * tw / 2, cy + sa * (r_ring - 2.2) + pb * tw / 2),
            (cx + ca * (r_ring - 2.2) - pa * tw / 2, cy + sa * (r_ring - 2.2) - pb * tw / 2),
            (cx + ca * r_out - pa * tw / 2, cy + sa * r_out - pb * tw / 2),
            (cx + ca * r_out + pa * tw / 2, cy + sa * r_out + pb * tw / 2),
        ]
        poly(d, pts, fill)
    if hole:
        d.ellipse([s(cx - hole), s(cy - hole), s(cx + hole), s(cy + hole)], fill=(0, 0, 0, 0))


def striker(d, tip, tail, w, bevel=True):
    """Steel bar from tail to tip with a bright bevel along its upper edge."""
    x0, y0 = tail
    x1, y1 = tip
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = -uy, ux                       # perpendicular
    hw = w / 2
    body = [(x0 + px * hw, y0 + py * hw), (x1 + px * hw, y1 + py * hw),
            (x1 - px * hw, y1 - py * hw), (x0 - px * hw, y0 - py * hw)]
    poly(d, body, STEEL_MID)
    if bevel:
        poly(d, [(x0 + px * hw, y0 + py * hw), (x1 + px * hw, y1 + py * hw),
                 (x1 + px * (hw - 0.22 * w), y1 + py * (hw - 0.22 * w)),
                 (x0 + px * (hw - 0.22 * w), y0 + py * (hw - 0.22 * w))], STEEL)
        poly(d, [(x0 - px * hw, y0 - py * hw), (x1 - px * hw, y1 - py * hw),
                 (x1 - px * (hw - 0.3 * w), y1 - py * (hw - 0.3 * w)),
                 (x0 - px * (hw - 0.3 * w), y0 - py * (hw - 0.3 * w))], STEEL_D)
    # beveled tip: a small bright triangle so the contact point looks sharp
    tl = 0.55 * w
    tipx = [(x1 + px * hw, y1 + py * hw), (x1 + ux * tl, y1 + uy * tl), (x1 - px * hw, y1 - py * hw)]
    poly(d, tipx, STEEL)


def logo_l1():
    """L1: striker hits the spark, two stray sparks (bare mark, no slab)."""
    im = canvas(); d = ImageDraw.Draw(im)
    striker(d, tip=(39, 41), tail=(60, 12), w=7.4)
    star4(d, 26, 44, 14.0, 3.6, SPARK)
    star4(d, 26, 44, 6.6, 1.8, SPARK_HI)
    star4(d, 47, 26, 4.6, 1.25, SPARK)
    star4(d, 20, 22, 3.2, 0.95, SPARK)
    return im


def logo_l2():
    """L2: icon-first - big spark left, short striker from the right, one stray spark."""
    im = canvas(); d = ImageDraw.Draw(im)
    striker(d, tip=(41, 39), tail=(61, 17), w=8.4)
    star4(d, 27, 36, 16.0, 4.0, SPARK)
    star4(d, 27, 36, 7.6, 2.0, SPARK_HI)
    star4(d, 17, 54, 3.4, 1.0, SPARK)
    return im


def logo_l3():
    """L3: hex badge - spark + chipped shard corner + striker notch."""
    im = canvas(); d = ImageDraw.Draw(im)
    cx, cy, R = 32, 32, 25
    pts = [(cx + R * math.cos(math.pi / 6 + i * math.pi / 3),
            cy + R * math.sin(math.pi / 6 + i * math.pi / 3)) for i in range(6)]
    poly(d, pts, (44, 50, 62))
    d.line([(s(p[0]), s(p[1])) for p in pts + [pts[0]]], fill=STEEL, width=s(3.4), joint="curve")
    star4(d, 30, 29, 12.0, 3.1, SPARK)
    star4(d, 30, 29, 5.4, 1.5, SPARK_HI)
    poly(d, [(38, 41), (46, 41), (43, 49), (36, 47)], (92, 101, 118))   # flint shard in the corner
    return im


def logo_l4():
    """L4: F built from steel with the spark as its middle arm (wordmark-friendly)."""
    im = canvas(); d = ImageDraw.Draw(im)
    d.rectangle([s(18), s(12), s(28), s(54)], fill=STEEL)      # stem
    d.rectangle([s(18), s(12), s(45), s(20)], fill=STEEL)      # top arm
    d.rectangle([s(18), s(32), s(40), s(40)], fill=STEEL)      # mid arm base
    star4(d, 45, 36, 9.0, 2.4, SPARK)                          # mid arm tip = spark
    star4(d, 45, 36, 4.0, 1.1, SPARK_HI)
    star4(d, 50, 14, 3.4, 1.0, SPARK)
    return im


# ---------- settings ----------

def set_gear_dot():
    im = Image.new("RGBA", (24 * S, 24 * S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    gear(d, 12, 12, 10.8, 7.2, 8, STEEL, hole=None, tooth_w=0.66)
    d.ellipse([s(9.4), s(9.4), s(14.6), s(14.6)], fill=(30, 30, 30, 255))
    d.ellipse([s(10.5), s(10.5), s(13.5), s(13.5)], fill=SPARK)
    return im


def set_gear_open():
    """outline gear: lighter weight for the sidebar / menu items."""
    im = Image.new("RGBA", (24 * S, 24 * S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    d.ellipse([s(5.6), s(5.6), s(18.4), s(18.4)], outline=STEEL, width=s(2.6))
    for i in range(8):
        a = i * math.pi / 4
        ca, sa = math.cos(a), math.sin(a)
        d.line([s(12 + ca * 6.0), s(12 + sa * 6.0), s(12 + ca * 10.6), s(12 + sa * 10.6)],
               fill=STEEL, width=s(3.2))
    d.ellipse([s(9.8), s(9.8), s(14.2), s(14.2)], fill=SPARK)
    return im


def set_sliders():
    im = Image.new("RGBA", (24 * S, 24 * S), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    for y, kx in ((6.6, 8.6), (12.0, 15.4), (17.4, 7.2)):
        d.rounded_rectangle([s(3.0), s(y - 1.2), s(21.0), s(y + 1.2)], radius=s(1.2),
                            fill=(128, 138, 154, 255))
        d.ellipse([s(kx - 3.2), s(y - 3.2), s(kx + 3.2), s(y + 3.2)], fill=STEEL)
        d.ellipse([s(kx - 1.3), s(y - 1.3), s(kx + 1.3), s(y + 1.3)], fill=SPARK)
    return im


def downsample(im, px):
    return im.resize((px, px), Image.LANCZOS)


def main():
    logos = [("L1 striker+spark", logo_l1()), ("L2 icon-first", logo_l2()),
             ("L3 hex badge", logo_l3()), ("L4 F + spark arm", logo_l4())]
    setts = [("gear+dot", set_gear_dot()), ("gear outline", set_gear_open()), ("sliders", set_sliders())]

    for name, im in logos:
        for px in (16, 20, 24, 32, 48, 64, 128):
            downsample(im, px).save(os.path.join(OUT, "v3-%s-%d.png" % (name.split()[0].lower(), px)))
    for name, im in setts:
        for px in (16, 20, 24, 32, 48, 64):
            downsample(im, px).save(os.path.join(OUT, "v3-set-%s-%d.png" % (name.split()[0].lower(), px)))

    W, H = 1080, 740
    sheet = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(sheet)
    d.text((26, 18), "FLC mark v3 - pick one for the title bar / About box", fill=(214, 222, 234))
    x, y = 26, 46
    for name, im in logos:
        d.rectangle([x, y, x + 250, y + 300], fill=PANEL)
        d.text((x + 10, y + 10), name, fill=(170, 180, 196))
        sheet.alpha_composite(downsample(im, 170), (x + 40, y + 34))
        for j, px in enumerate((64, 32, 24, 16)):
            tile = downsample(im, px)
            cx = x + 34 + j * 56
            d.rectangle([cx - 6, y + 218, cx + 54, y + 288], outline=(58, 62, 72))
            sheet.alpha_composite(tile, (cx, y + 224))
            d.text((cx + 10, y + 272), str(px), fill=(148, 156, 170))
        x += 262

    y = 400
    d.text((26, y - 26), "settings glyphs - gear sits in the title bar, opens the settings page", fill=(214, 222, 234))
    x = 26
    for name, im in setts:
        d.rectangle([x, y, x + 250, y + 300], fill=PANEL)
        d.text((x + 10, y + 10), name, fill=(170, 180, 196))
        for j, px in enumerate((64, 32, 24, 20, 16)):
            tile = downsample(im, px)
            cx = x + 18 + j * 46
            sheet.alpha_composite(tile, (cx, y + 60))
            d.text((cx + 8, y + 132), str(px), fill=(148, 156, 170))
        x += 262

    sheet.convert("RGB").save(os.path.join(OUT, "sheet-v3.png"))
    print("saved", os.path.join(OUT, "sheet-v3.png"))


if __name__ == "__main__":
    main()

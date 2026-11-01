# icon-lab4.py - final pass on the winner direction (spark + flat-tip striker + X-flash),
# then a hero banner pushed through the video-effects ffmpeg recipes (vignette + grain).
import os, math, importlib.util
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("lab3", os.path.join(HERE, "icon-lab3.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

S = lab.S
OUT = HERE
SPARK, SPARK_HI = lab.SPARK, lab.SPARK_HI
STEEL, STEEL_MID, STEEL_D = lab.STEEL, lab.STEEL_MID, lab.STEEL_D


def flat_striker(d, tip, tail, w):
    """Steel bar with a FLAT cut tip (the beveled tip read like a pencil) + warm contact rim."""
    x0, y0 = tail
    x1, y1 = tip
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = -uy, ux
    hw = w / 2
    body = [(x0 + px * hw, y0 + py * hw), (x1 + px * hw, y1 + py * hw),
            (x1 - px * hw, y1 - py * hw), (x0 - px * hw, y0 - py * hw)]
    lab.poly(d, body, STEEL_MID)
    # top bevel (lit) / bottom bevel (shadow), both inset
    lab.poly(d, [(x0 + px * hw, y0 + py * hw), (x1 + px * hw, y1 + py * hw),
                 (x1 + px * (hw - 0.26 * w), y1 + py * (hw - 0.26 * w)),
                 (x0 + px * (hw - 0.26 * w), y0 + py * (hw - 0.26 * w))], STEEL)
    lab.poly(d, [(x0 - px * hw, y0 - py * hw), (x1 - px * hw, y1 - py * hw),
                 (x1 - px * (hw - 0.34 * w), y1 - py * (hw - 0.34 * w)),
                 (x0 - px * (hw - 0.34 * w), y0 - py * (hw - 0.34 * w))], STEEL_D)
    # warm rim on the striking face
    lab.poly(d, [(x1 + px * hw, y1 + py * hw), (x1 - px * hw, y1 - py * hw),
                 (x1 - px * (hw - 0.14 * w) - ux * 0.06 * w, y1 - py * (hw - 0.14 * w) - uy * 0.06 * w),
                 (x1 + px * (hw - 0.14 * w) - ux * 0.06 * w, y1 + py * (hw - 0.14 * w) - uy * 0.06 * w)],
            (255, 214, 170))


def logo_mark(big=True):
    im = lab.canvas(); d = ImageDraw.Draw(im)
    flat_striker(d, tip=(41, 38), tail=(62, 15), w=8.6 if big else 9.4)
    lab.star4(d, 26, 37, 16.5 if big else 17.5, 4.1, SPARK)
    lab.star4(d, 26, 37, 7.8, 2.0, SPARK_HI)
    lab.star4(d, 15, 56, 3.4, 1.0, SPARK)
    lab.star4(d, 45, 57, 2.6, 0.8, SPARK)
    return im


def logo_xflash():
    """L5: spark with two short strike bars crossing behind it (X flash)."""
    im = lab.canvas(); d = ImageDraw.Draw(im)
    flat_striker(d, tip=(14, 12), tail=(40, 40), w=6.4)
    flat_striker(d, tip=(50, 10), tail=(24, 40), w=6.4)
    lab.star4(d, 30, 36, 15.0, 3.9, SPARK)
    lab.star4(d, 30, 36, 7.0, 1.9, SPARK_HI)
    return im


def gear_dot():
    return lab.set_gear_dot()


def save_all():
    mark = logo_mark()
    for px in (16, 20, 24, 32, 48, 64, 128, 256):
        lab.downsample(mark, px).save(os.path.join(OUT, "flc-mark-%d.png" % px))
    xf = logo_xflash()
    for px in (24, 32, 64, 128):
        lab.downsample(xf, px).save(os.path.join(OUT, "flc-xflash-%d.png" % px))
    g = gear_dot()
    for px in (16, 20, 24, 32, 64):
        lab.downsample(g, px).save(os.path.join(OUT, "flc-gear-%d.png" % px))
    return mark, xf, g


def big_sheet(mark, xf, g):
    W, H = 1040, 560
    sh = Image.new("RGBA", (W, H), lab.BG + (255,))
    d = ImageDraw.Draw(sh)
    d.text((26, 18), "final candidates - FLC mark (flat-tip striker) + X-flash + settings gear", fill=(214, 222, 234))
    tiles = [("mark", mark), ("xflash", xf), ("gear", g)]
    x = 26
    for name, im in tiles:
        d.rectangle([x, 46, x + 300, 520], fill=lab.PANEL)
        d.text((x + 12, 56), name, fill=(170, 180, 196))
        sh.alpha_composite(lab.downsample(im, 220), (x + 40, 80))
        for j, px in enumerate((64, 32, 24, 16)):
            cx = x + 26 + j * 68
            d.rectangle([cx - 8, 336, cx + 64, 408], outline=(58, 62, 72))
            sh.alpha_composite(lab.downsample(im, px), (cx, 342))
            d.text((cx + 14, 414), str(px), fill=(148, 156, 170))
        x += 328
    sh.convert("RGB").save(os.path.join(OUT, "sheet-final.png"))


def hero(mark, g):
    """Hero banner: mark + wordmark + FLC + tagline, 1280x420 (dark)."""
    W, H = 1280, 420
    im = Image.new("RGBA", (W, H), (22, 23, 26, 255))
    d = ImageDraw.Draw(im)
    # faint diagonal texture
    for i in range(-H, W, 26):
        d.line([(i, H), (i + H, 0)], fill=(255, 255, 255, 6), width=1)
    im.alpha_composite(lab.downsample(mark, 190), (60, 90))
    # wordmark
    try:
        f_big = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 92)
        f_mid = ImageFont.truetype("C:/Windows/Fonts/consolab.ttf", 40)
        f_sm = ImageFont.truetype("C:/Windows/Fonts/segoeui.ttf", 26)
    except Exception:
        f_big = f_mid = f_sm = ImageFont.load_default()
    d.text((288, 74), "FLINT", font=f_big, fill=(236, 240, 248))
    d.text((292, 190), "Steele spark, hand-cut tools.", font=f_sm, fill=(150, 158, 172))
    d.text((292, 232), "FLINT_CHAN", font=f_mid, fill=(255, 176, 78))
    d.text((292, 292), "language FLC  ·  compiler hlc  ·  .fl", font=f_sm, fill=(150, 158, 172))
    im.alpha_composite(lab.downsample(g, 40), (1180, 40))
    im.convert("RGB").save(os.path.join(OUT, "hero-raw.png"))


if __name__ == "__main__":
    mark, xf, g = save_all()
    big_sheet(mark, xf, g)
    hero(mark, g)
    print("saved sheet-final.png / hero-raw.png")

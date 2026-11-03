# ai_ref2sprite.py -- AI 参考图（棋盘格背景 JPEG/PNG）-> 像素精灵网格
#
# 用途：把 AI 生成的角色/道具参考图（带棋盘格"透明"背景）转成
#   32x32（或指定尺寸）的索引色像素图，交给 sprite2fl.js / sprite2fl2.js。
#
# 用法：
#   python tools\ai_ref2sprite.py <图> --size 32 --name hero --fixed-pal
#   python tools\ai_ref2sprite.py <图> --palette          # 只打印提取的调色板
#   python tools\ai_ref2sprite.py <图> --box 65,544,512,1574   # 只取指定区域
#
# 流程：棋盘格背景检测(两色) -> 前景掩码 -> 列投影切角色 -> 众数降采样
#       -> 每格取格内前景像素的众数索引 -> 写 ASCII 网格 + 放大预览 PNG
#
# --fixed-pal 用游戏固定 9 色板（与 lib\sprite.fl 的 sprite_pal_fill 对齐），
# 否则从图里 k-means 提取 9 色。

import sys
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 游戏固定调色板（索引 1..9），与 lib\sprite.fl:sprite_pal_fill 对齐
FIXED_PAL = [
    (0x0B, 0x0E, 0x1A),   # 1 深蓝黑：描边/头发
    (0x1B, 0x23, 0x40),   # 2 深蓝：和服主色/阴影
    (0xE8, 0xF0, 0xFF),   # 3 白：领口/袜/高光
    (0x7F, 0xD8, 0xE8),   # 4 青：眼/魔法/冲击波
    (0xE8, 0x66, 0x3C),   # 5 橙红：火焰/受伤
    (0xF2, 0xC1, 0x4E),   # 6 金：刀镡/腰带
    (0xF5, 0xD9, 0xB8),   # 7 肤色
    (0x8E, 0x9A, 0xB0),   # 8 灰蓝：金属/阴影
    (0xB0, 0x3A, 0x3A),   # 9 深红：绳/血
]


def load_rgb(path):
    im = Image.open(path)
    if im.mode == "RGBA":
        bg = Image.new("RGB", im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[3])
        im = bg
    else:
        im = im.convert("RGB")
    im = im.filter(ImageFilter.MedianFilter(3))   # 压掉 JPEG 棋盘格噪点
    return np.asarray(im).astype(np.int16)


def bg_colors(rgb, band=48):
    h, w = rgb.shape[:2]
    edge = np.concatenate([
        rgb[:band].reshape(-1, 3), rgb[-band:].reshape(-1, 3),
        rgb[:, :band].reshape(-1, 3), rgb[:, -band:].reshape(-1, 3),
    ])
    q = (edge // 8) * 8
    uniq, counts = np.unique(q, axis=0, return_counts=True)
    order = np.argsort(-counts)
    cols = []
    for i in order:
        c = uniq[i].astype(np.int16)
        if counts[i] < len(edge) * 0.02:
            break
        if all(np.abs(c - d).max() > 12 for d in cols):
            cols.append(c)
        if len(cols) >= 3:
            break
    return cols


def fg_mask(rgb, cols, tol=26):
    d = np.full(rgb.shape[:2], 1 << 20, dtype=np.int32)
    for c in cols:
        dd = np.abs(rgb - c).sum(axis=2)
        d = np.minimum(d, dd)
    return (d > tol).astype(np.uint8)


def close_mask(m, r=1):
    out = m.copy()
    for _ in range(r):
        acc = out.copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                acc = acc + np.roll(np.roll(out, dy, 0), dx, 1)
        out = (acc >= 5).astype(np.uint8)
    return out


def split_actors(m, min_w=80, gap=16):
    col = m.sum(axis=0)
    on = col > 3
    segs = []
    start = None
    for x, v in enumerate(on):
        if v and start is None:
            start = x
        elif not v and start is not None:
            segs.append((start, x))
            start = None
    if start is not None:
        segs.append((start, len(on)))
    merged = []
    for s in segs:
        if merged and s[0] - merged[-1][1] < gap:
            merged[-1] = (merged[-1][0], s[1])
        else:
            merged.append(list(s))
    return [(a, b) for a, b in merged if b - a >= min_w]


def bbox_rows(m, x0, x1, thr=8, gap=14):
    sub = m[:, x0:x1]
    rows = sub.sum(axis=1)
    on = rows > thr
    segs = []
    start = None
    last = None
    for y, v in enumerate(on):
        if v:
            if start is None:
                start = y
            last = y
        elif start is not None and y - last > gap:
            segs.append((start, last))
            start = None
    if start is not None:
        segs.append((start, last))
    if not segs:
        return None
    segs.sort(key=lambda s: s[1] - s[0], reverse=True)
    return int(segs[0][0]), int(segs[0][1]) + 1


def kmeans_palette(pix, k=9, iters=24):
    if len(pix) == 0:
        return np.zeros((0, 3))
    rs = np.random.RandomState(7)
    idx = rs.choice(len(pix), min(len(pix), 40000), replace=False)
    p = pix[idx].astype(np.float64)
    rs2 = np.random.RandomState(3)
    cent = [p[rs2.randint(len(p))]]
    for i in range(k - 1):
        d = np.min([np.abs(p - c).sum(axis=1) for c in cent], axis=0)
        prob = d / d.sum() if d.sum() > 0 else np.ones(len(p)) / len(p)
        cent.append(p[np.random.RandomState(11 + len(cent)).choice(len(p), p=prob)])
    cent = np.array(cent)
    for _ in range(iters):
        d = np.stack([np.abs(p - c).sum(axis=1) for c in cent], axis=1)
        lab = d.argmin(axis=1)
        for j in range(k):
            sel = p[lab == j]
            if len(sel):
                cent[j] = np.median(sel, axis=0)
    cent = cent[np.argsort(cent.sum(axis=1))]
    keep = []
    for c in cent:
        if all(np.abs(c - d).max() > 18 for d in keep):
            keep.append(c)
    return np.array(keep)


def quantize(rgb, m, pal):
    h, w = m.shape
    idx = np.zeros((h, w), dtype=np.int16)
    pts = np.where(m > 0)
    if len(pts[0]) == 0:
        return idx
    pix = rgb[m > 0].astype(np.float64)
    d = np.stack([np.abs(pix - c).sum(axis=1) for c in pal], axis=1)
    idx[pts] = d.argmin(axis=1) + 1
    return idx


def downsample_mode(idx_full, m, x0, x1, y0, y1, size, keep=0.42):
    """众数降采样：每格取格内前景索引的众数，保留色块边界。"""
    sh, sw = y1 - y0, x1 - x0
    scale = size / sh
    tw = max(4, min(size, int(round(sw * scale))))
    th = max(4, min(size, int(round(sh * scale))))
    out = np.zeros((size, size), dtype=np.int16)
    ox = (size - tw) // 2
    oy = size - th
    for dy in range(th):
        sy0 = y0 + int(dy * sh / th)
        sy1 = y0 + max(sy0 - y0 + 1, int((dy + 1) * sh / th))
        for dx in range(tw):
            sx0 = x0 + int(dx * sw / tw)
            sx1 = x0 + max(sx0 - x0 + 1, int((dx + 1) * sw / tw))
            cell_m = m[sy0:sy1, sx0:sx1]
            vals = idx_full[sy0:sy1, sx0:sx1][cell_m > 0]
            if len(vals) == 0 or len(vals) < cell_m.size * keep:
                continue
            cnt = np.bincount(vals.astype(np.int64), minlength=10)
            out[oy + dy, ox + dx] = int(cnt.argmax())
    return out


def render(idx, pal, out_png, scale=12):
    h, w = idx.shape
    img = np.zeros((h, w, 3), dtype=np.uint8)
    for i, c in enumerate(pal):
        img[idx == i + 1] = c.astype(np.uint8)
    im = Image.fromarray(img, "RGB").resize((w * scale, h * scale), Image.NEAREST)
    im.save(out_png)
    return im


def ascii_grid(idx):
    return ["".join("." if v == 0 else str(v) for v in idx[y]) for y in range(idx.shape[0])]


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    path = args[0]
    size = 32
    outdir = os.path.join(ROOT, "tmp", "art")
    name = "sprite"
    only_pal = "--palette" in args
    fixed = "--fixed-pal" in args
    box = None
    for i, a in enumerate(args):
        if a == "--size" and i + 1 < len(args):
            size = int(args[i + 1])
        if a == "--out" and i + 1 < len(args):
            outdir = args[i + 1]
        if a == "--name" and i + 1 < len(args):
            name = args[i + 1]
        if a == "--box" and i + 1 < len(args):
            box = tuple(int(v) for v in args[i + 1].split(","))
    os.makedirs(outdir, exist_ok=True)

    rgb = load_rgb(path)
    cols = bg_colors(rgb)
    print("bg:", [tuple(int(v) for v in c) for c in cols])
    m = close_mask(fg_mask(rgb, cols))
    print("fg: %.1f%%" % (m.mean() * 100))

    if box:
        boxes = [box]
    else:
        actors = split_actors(m)
        print("actors:", actors)
        boxes = []
        for (x0, x1) in actors:
            r = bbox_rows(m, x0, x1)
            if r:
                boxes.append((x0, r[0], x1, r[1]))

    if fixed:
        pal = np.array(FIXED_PAL, dtype=np.float64)
    else:
        pix = rgb[m > 0].astype(np.float64)
        pal = kmeans_palette(pix, k=9)
    print("palette %d:" % len(pal))
    for i, c in enumerate(pal):
        print("  %d: #%02X%02X%02X" % (i + 1, int(c[0]), int(c[1]), int(c[2])))
    if only_pal or not boxes:
        return 0

    idx_full = quantize(rgb, m, pal)
    for k, (x0, y0, x1, y1) in enumerate(boxes):
        small = downsample_mode(idx_full, m, x0, x1, y0, y1, size)
        png = os.path.join(outdir, "%s_%d.png" % (name, k))
        render(small, pal, png)
        print("frame %d bbox=(%d,%d,%d,%d) fg=%.0f%% -> %s"
              % (k, x0, y0, x1, y1, 100.0 * (small > 0).mean(), png))
        for row in ascii_grid(small):
            print("  " + row)
    return 0


if __name__ == "__main__":
    sys.exit(main())

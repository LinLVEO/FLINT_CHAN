# pixelgrid.py -- 检测 AI "伪像素画"的原始像素格尺寸，按格重采样
#
# 思路：AI 生成的像素风图其实是"逻辑像素被放大 N 倍"的色块画。
# 找出格宽 W，然后每格取中心/众数，就能无损还原成 W 分之一的干净像素图。
#
# 用法：python tools\pixelgrid.py <图> [--box x0,y0,x1,y1] [--out tmp\art]

import sys
import os
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(path):
    im = Image.open(path)
    if im.mode == "RGBA":
        bg = Image.new("RGB", im.size, (255, 255, 255))
        bg.paste(im, mask=im.split()[3])
        im = bg
    else:
        im = im.convert("RGB")
    return np.asarray(im).astype(np.int32)


def edges(rgb, axis):
    """沿 axis 的一阶梯度和。"""
    d = np.abs(np.diff(rgb, axis=axis)).sum(axis=2)
    return d.sum(axis=1 - axis)


def period_score(e, lo=4, hi=60):
    """周期强度：e 与该周期移位后的自相关（归一化）。"""
    best = (0, 0)
    n = len(e)
    e = e - e.mean()
    for p in range(lo, hi + 1):
        if n <= 2 * p:
            break
        a = e[:-p]
        b = e[p:]
        num = float((a * b).sum())
        den = float(np.sqrt((a * a).sum() * (b * b).sum())) + 1e-9
        s = num / den
        if s > best[0]:
            best = (s, p)
    return best


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    path = args[0]
    box = None
    for i, a in enumerate(args):
        if a == "--box" and i + 1 < len(args):
            box = tuple(int(v) for v in args[i + 1].split(","))
    rgb = load(path)
    if box:
        x0, y0, x1, y1 = box
        rgb = rgb[y0:y1, x0:x1]
    ex = edges(rgb, axis=1)   # 列方向（x 变化）-> 竖边在哪些 x
    ey = edges(rgb, axis=0)
    sx, px = period_score(ex)
    sy, py = period_score(ey)
    print("x 周期: %d (score %.3f)   y 周期: %d (score %.3f)" % (px, sx, py, sy))
    # 打印前 40 个强峰，看是否等距
    def peaks(e, thr):
        m = e.mean() + e.std() * thr
        out = []
        for i in range(1, len(e) - 1):
            if e[i] >= m and e[i] >= e[i - 1] and e[i] >= e[i + 1]:
                out.append(i)
        return out
    pk = peaks(ex, 0.6)[:40]
    print("x 峰(前40):", pk)
    if len(pk) > 3:
        d = np.diff(pk)
        print("x 峰间距中位:", int(np.median(d)), "众数:", int(np.bincount(d).argmax()))
    pk = peaks(ey, 0.6)[:40]
    print("y 峰(前40):", pk)
    if len(pk) > 3:
        d = np.diff(pk)
        print("y 峰间距中位:", int(np.median(d)), "众数:", int(np.bincount(d).argmax()))
    return 0


if __name__ == "__main__":
    sys.exit(main())

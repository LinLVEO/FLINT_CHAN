# hero_attack.py -- 从侧面站立帧派生拔刀二连斩（4 帧）
#
# 背景（2026-11-02）：角色只有站姿 + 行走，没有攻击姿态。刀本身是第二张 AI 参考图
# （斜 45° 的武士刀），但像素旋转会糊，所以刀用程序画：刀身取调色板 3/4（深蓝/亮蓝），
# 刃口 7（浅灰），护手 6（金），柄绳 9（深红）。
#
# 用法：python tools\hero_attack.py            # 追加 4 帧到 sprites\hero4.txt
#       python tools\hero_attack.py --preview  # 只出预览
#
# 帧序：拔刀（刀出鞘下压）-> 第一斩（右横斩 + 刀光）-> 第二斩（反手回斩 + 刀光）-> 收刀

import io
import os
import sys
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "sprites", "hero4.txt")
ART = os.path.join(ROOT, "tmp", "art")

PAL = [(0, 0, 0), (0x07, 0x07, 0x0A), (0x23, 0x23, 0x2B), (0x28, 0x2B, 0x4A),
       (0x3E, 0x43, 0x68), (0x5A, 0x58, 0x60), (0xC3, 0xB0, 0xA2), (0xD8, 0xD1, 0xD7),
       (0xFB, 0xEA, 0xCE), (0xB0, 0x3A, 0x3A)]

BLADE = 4      # 刀身亮色（和服亮蓝，视觉上像冷钢）
EDGE = 7       # 刃口浅灰
GUARD = 6      # 护手金
GRIP = 9       # 柄绳深红


def load(path):
    frames, cur, meta = [], [], []
    for ln in io.open(path, encoding="utf-8").read().split("\n"):
        if ln.startswith("# ----"):
            if cur:
                frames.append(cur)
                cur = []
            meta.append(ln.strip("# -").strip())
            continue
        if ln.startswith("#") or not ln.strip():
            continue
        cur.append(ln)
    if cur:
        frames.append(cur)
    return [np.array([[0 if c == "." else int(c) for c in row] for row in f], dtype=np.uint8) for f in frames], meta


def line(g, x0, y0, x1, y1, val, w=1):
    """粗线（Bresenham + 正方形笔刷）"""
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    x, y = x0, y0
    h, wd = g.shape
    while True:
        for oy in range(-(w // 2), w - w // 2):
            for ox in range(-(w // 2), w - w // 2):
                yy, xx = y + oy, x + ox
                if 0 <= yy < h and 0 <= xx < wd:
                    g[yy, xx] = val
        if x == x1 and y == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x += sx
        if e2 < dx:
            err += dx
            y += sy


def katana(g, hx, hy, tx, ty):
    """在 (hx,hy) 画一把指向 (tx,ty) 的刀：刀身 + 刃口 + 护手 + 柄"""
    # 归一化方向
    dx = tx - hx
    dy = ty - hy
    L = max(1.0, (dx * dx + dy * dy) ** 0.5)
    ux, uy = dx / L, dy / L
    # 柄（向后 5px，深红）
    line(g, hx - int(ux * 5), hy - int(uy * 5), hx, hy, GRIP, 2)
    # 护手（垂直方向一小段金）
    gx, gy = hx + int(ux * 1), hy + int(uy * 1)
    for s in (-2, -1, 0, 1, 2):
        yy = gy + int(-uy * s) + int(-ux * s)
        xx = gx + int(ux * s) + int(-uy * s)
        if 0 <= yy < g.shape[0] and 0 <= xx < g.shape[1]:
            g[yy, xx] = GUARD
    # 刀身：先深色描边（宽 3），再亮蓝（宽 2），最后刃口浅灰（宽 1）
    line(g, gx, gy, tx, ty, 1, 3)
    line(g, gx, gy, tx, ty, BLADE, 2)
    ex = gx + int(-uy * 1)
    ey = gy + int(ux * 1)
    tx2 = tx + int(-uy * 1)
    ty2 = ty + int(ux * 1)
    line(g, ex, ey, tx2, ty2, EDGE, 1)


def slash(g, cx, cy, r, a0, a1, col=7, thick=0.6):
    """刀光：以 (cx,cy) 为圆心、半径 r 的弧，角度 a0..a1（度，y 向下为正）。
    thick = 角步长（度），越小越密。"""
    import math
    a = a0
    while a <= a1:
        rad = math.radians(a)
        x = int(cx + r * math.cos(rad))
        y = int(cy + r * math.sin(rad))
        if 0 <= y < g.shape[0] and 0 <= x < g.shape[1]:
            g[y, x] = col
        a += thick


def attack_frame(side, phase):
    """phase: 0 拔刀 / 1 一斩 / 2 二斩 / 3 收刀"""
    g = side.copy()
    h, w = g.shape
    # 清掉原手（y44..50, x18..38）
    g[44:50, 18:38] = 0
    hx, hy = 26, 46           # 持刀手位置
    if phase == 0:
        # 拔刀：刀还没出鞘，手按柄，刀斜向下（刀鞘）
        line(g, 24, 47, 34, 56, 2, 3)      # 刀鞘（深蓝）
        g[47:49, 25:27] = 8                 # 手
        g[46:48, 23:25] = GUARD             # 护手
        line(g, 23, 45, 20, 42, GRIP, 2)    # 柄
    elif phase == 1:
        # 一斩：刀从右上挥到右下；刀光 = 两条同心弧（内白外青）
        katana(g, hx, hy, 46, 56)
        slash(g, hx, hy - 2, 20, -75, 25, 4)     # 外弧：青
        slash(g, hx, hy - 2, 17, -70, 20, 7)     # 内弧：白
        g[45:48, 24:27] = 8
    elif phase == 2:
        # 二斩：反手从下往上撩；刀光反向、半径更大
        katana(g, hx, hy, 48, 26)
        slash(g, hx, hy - 4, 22, 20, -70, 4)
        slash(g, hx, hy - 4, 19, 15, -65, 7)
        g[45:48, 24:27] = 8
    else:
        # 收刀：刀回到鞘，手收在腰侧
        line(g, 24, 47, 32, 55, 2, 3)
        g[47:49, 25:27] = 8
        line(g, 23, 45, 21, 43, GRIP, 2)
    return g


def rgb(idx):
    out = np.zeros(idx.shape + (3,), dtype=np.uint8)
    for k, c in enumerate(PAL):
        out[idx == k] = c
    return out


def main():
    preview_only = "--preview" in sys.argv
    frames, meta = load(SRC)
    side = frames[2]
    atk = [attack_frame(side, p) for p in range(4)]

    os.makedirs(ART, exist_ok=True)
    imgs = [Image.fromarray(rgb(f), "RGB").resize((64 * 7, 64 * 7), Image.NEAREST) for f in atk]
    sheet = Image.new("RGB", (64 * 7 * 4, 64 * 7), (20, 22, 30))
    for i, im in enumerate(imgs):
        sheet.paste(im, (i * 64 * 7, 0))
    sheet.save(os.path.join(ART, "attack_preview.png"))
    imgs[0].save(os.path.join(ART, "attack_preview.gif"), save_all=True,
                 append_images=imgs[1:], duration=140, loop=0)
    print("preview -> tmp\\art\\attack_preview.png")
    if preview_only:
        return 0

    names = meta[:3] + ["walk0", "walk1", "walk2", "walk3"] + ["atk0", "atk1", "atk2", "atk3"]
    allf = frames[:7] + atk
    lines = ["# hero4 -- 64x64 和服少女：0 正面 / 1 背面 / 2 侧面站 / 3-6 行走 / 7-10 拔刀二连斩",
             "# 3-6 由 tools\\hero_walk.py 派生；7-10 由 tools\\hero_attack.py 派生",
             "# 朝左统一用镜像（sprite_blit_frac 的 flip）"]
    for n, f in zip(names, allf):
        lines.append("# ---- %s ----" % n)
        for row in f:
            lines.append("".join("." if v == 0 else str(v) for v in row))
        lines.append("")
    io.open(SRC, "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %d frames -> sprites\\hero4.txt" % len(allf))
    return 0


if __name__ == "__main__":
    sys.exit(main())

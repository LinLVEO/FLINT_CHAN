# hero_walk.py -- 从侧面站立帧派生 4 帧行走（伸腿 + 摆臂）
#
# 背景（2026-11-02）：AI 只给了 4 个站姿视角，没有行走姿态。这张稿是和服开叉、
# 长裙盖腿，纯层位移看不出走路 ⇒ 直接在下摆以下「画腿」、在身侧「画手」，按
# 相位参数化生成 4 帧。
#
# 用法：python tools\hero_walk.py            # 读 sprites\hero4.txt 的侧面帧 -> 追加 4 帧写回
#       python tools\hero_walk.py --preview  # 只出预览 tmp\art\walk_preview.png，不改素材
#
# 约定：腿 = 小腿(肤色 8 + 右缘暗 6) + 白袜(7) + 木屐(1)，从 y57 裙摆下缘伸出；
#       手 = 袖口(深蓝 2) + 手(肤色 8)，随相位前后摆。

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

# 相位表：(前腿 dx, 前腿底 y, 后腿 dx, 后腿底 y, 手 dx, 手 dy, 后摆, 整体 bob)
SEQ = [
    (3, 63, -3, 61, 2, 0, 0, 0),     # 迈步：前腿前伸直、后腿收回抬高
    (0, 62, 0, 62, 0, -1, 0, -1),    # 过渡：并拢、身体最高
    (-3, 61, 3, 63, -2, -1, 1, 0),   # 反迈步
    (0, 62, 0, 62, 0, 0, 0, -1),     # 过渡
]


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


def leg(g, x, y0, y1):
    """小腿宽 3：肤色 8 + 右缘暗 6，底部白袜 7，最下木屐 1（比腿宽）"""
    if y1 - y0 < 4:
        return
    g[y0:y1, x:x + 3] = 8
    g[y0:y1, x + 2:x + 3] = 6
    g[y1 - 2:y1, x:x + 3] = 7
    g[y1 - 1:y1 + 1, x - 1:x + 4] = 1


def arm(g, x, y, back):
    if back:
        g[y:y + 3, x + 2:x + 5] = 2
        g[y + 3:y + 5, x + 1:x + 3] = 8
    else:
        g[y:y + 3, x:x + 3] = 2
        g[y + 3:y + 5, x:x + 2] = 8


def walk_frame(side, phase):
    fdx, fbot, bdx, bbot, hdx, hdy, back, bob = SEQ[phase % 4]
    g = side.copy()
    g[56:64, 14:54] = 0          # 清掉原腿脚（y56 以下是裙摆下缘）
    g[44:50, 18:38] = 0          # 清掉原手
    leg(g, 27 + bdx, 57, bbot)   # 后腿
    leg(g, 31 + fdx, 57, fbot)   # 前腿
    arm(g, 22 + hdx, 45 + hdy, back)
    if bob:
        out = np.zeros_like(g)
        out[:g.shape[0] - 1] = g[1:]
        g = out
    return g


def rgb(idx):
    out = np.zeros(idx.shape + (3,), dtype=np.uint8)
    for k, c in enumerate(PAL):
        out[idx == k] = c
    return out


def main():
    preview_only = "--preview" in sys.argv
    frames, meta = load(SRC)
    if len(frames) < 3:
        print("hero4.txt 至少要有 3 帧（正面/背面/侧面）")
        return 1
    side = frames[2]
    walk = [walk_frame(side, p) for p in range(4)]

    os.makedirs(ART, exist_ok=True)
    imgs = [Image.fromarray(rgb(f), "RGB").resize((64 * 7, 64 * 7), Image.NEAREST) for f in walk]
    sheet = Image.new("RGB", (64 * 7 * 4, 64 * 7), (20, 22, 30))
    for i, im in enumerate(imgs):
        sheet.paste(im, (i * 64 * 7, 0))
    sheet.save(os.path.join(ART, "walk_preview.png"))
    imgs[0].save(os.path.join(ART, "walk_preview.gif"), save_all=True,
                 append_images=imgs[1:], duration=120, loop=0)
    print("preview -> tmp\\art\\walk_preview.png")
    if preview_only:
        return 0

    # 写回：保留原有 4 帧，追加 4 帧行走
    lines = ["# hero4 -- 64x64 和服少女：0 正面 / 1 背面 / 2 侧面站 / 3-6 侧面行走 4 帧",
             "# 3-6 由 tools\\hero_walk.py 从侧面帧派生（伸腿 + 摆臂），源图仍是 AI 四视图",
             "# 朝左统一用镜像（sprite_blit_frac 的 flip），不另存左向帧"]
    names = ["front", "back", "side_r", "walk0", "walk1", "walk2", "walk3"]
    allf = frames[:3] + walk
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

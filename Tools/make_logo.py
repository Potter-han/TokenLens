#!/usr/bin/env python3
"""把用户提供的 logo JPG 转成透明背景 PNG，并裁切到内容边界。

用法:
    python3 Tools/make_logo.py <输入JPG> <输出PNG>

默认输入/输出:
    输入  = /Users/xiaohan/.workbuddy/clipboard-images/clipboard-2026-10-30T07-00-32-933Z-4dbf1c9d.jpg
    输出  = Assets/AppLogo.png （相对仓库根目录）
"""
import sys
from pathlib import Path
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
DEFAULT_IN = Path("/Users/xiaohan/.workbuddy/clipboard-images/clipboard-2026-10-30T07-00-32-933Z-4dbf1c9d.jpg")
DEFAULT_OUT = REPO / "Assets" / "AppLogo.png"

# 背景判定：白底 = 高亮度 + 极低饱和度；彩色 logo 始终有较高饱和度。
# 用 HSV 的饱和度区分比「最小通道」更稳：抗锯齿边缘（彩色+白混合）仍保留较高饱和，
# 不会被误判成背景，从而避免白边/白点。
V_LO = 0.92   # 亮度阈值：低于此视为非白底（不在此通道背景）
S_HI = 0.08   # 饱和度 <= 此值且够亮 → 纯背景（完全透明）
S_LO = 0.20   # 饱和度 >= 此值 → 纯内容（完全不透明，之间线性羽化）


def _alpha_for(r: int, g: int, b: int) -> int:
    mx = max(r, g, b)
    mn = min(r, g, b)
    v = mx / 255.0
    s = (mx - mn) / mx if mx > 0 else 0.0
    if v <= V_LO:
        return 255                      # 暗像素不可能是白底，一律保留
    if s <= S_HI:
        return 0                        # 亮且无色 → 白底背景
    if s >= S_LO:
        return 255                      # 彩色内容
    return int(255 * (s - S_HI) / (S_LO - S_HI))   # 羽化边缘


def _cleanup(am, w, h):
    """去除孤立噪点：背景中的零星内容点、内容中的零星背景点。"""
    src = am.load()
    dst = am.copy()
    dl = dst.load()
    for y in range(h):
        for x in range(w):
            cnt = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and src[nx, ny] > 8:
                        cnt += 1
            if src[x, y] > 8 and cnt <= 1:
                dl[x, y] = 0            # 孤立内容点 → 背景
            elif src[x, y] <= 8 and cnt >= 4:
                dl[x, y] = 255          # 背景中的内容团 → 保留
    # 腐蚀内容边界 1px：切掉抗锯齿留下的白边/白圈
    src2 = dl
    dl2 = dst.copy()
    d2 = dl2.load()
    for y in range(h):
        for x in range(w):
            if src2[x, y] > 8:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = x + dx, y + dy
                        if not (0 <= nx < w and 0 <= ny < h) or src2[nx, ny] <= 8:
                            d2[x, y] = 0
                            break
    return dl2


def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_IN
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_OUT
    if not src.exists():
        print(f"[make_logo] 找不到输入图: {src}", file=sys.stderr)
        return 1

    img = Image.open(src).convert("RGB")
    w, h = img.size
    px = img.load()

    # 1) 计算透明遮罩 + 内容包围盒
    alpha = Image.new("L", (w, h), 0)
    am = alpha.load()
    minx, miny, maxx, maxy = w, h, 0, 0
    for y in range(h):
        for x in range(w):
            a = _alpha_for(*px[x, y])
            am[x, y] = a
            if a > 8:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y

    if maxx < minx:
        print("[make_logo] 未检测到非白底内容，原样拷贝", file=sys.stderr)
        img.save(dst)
        print(f"[make_logo] 已写入: {dst}")
        return 0

    alpha = _cleanup(alpha, w, h)
    am = alpha.load()

    # 2) 裁切到内容包围盒（留 3% 内边距，避免贴边）
    pad = int(max(w, h) * 0.03)
    minx = max(0, minx - pad); miny = max(0, miny - pad)
    maxx = min(w - 1, maxx + pad); maxy = min(h - 1, maxy + pad)
    crop = img.crop((minx, miny, maxx + 1, maxy + 1)).convert("RGBA")
    ca = alpha.crop((minx, miny, maxx + 1, maxy + 1))
    crop.putalpha(ca)

    dst.parent.mkdir(parents=True, exist_ok=True)
    crop.save(dst)
    print(f"[make_logo] 已写入: {dst}  ({crop.size[0]}x{crop.size[1]}, "
          f"内容区 {maxx - minx + 1}x{maxy - miny + 1})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

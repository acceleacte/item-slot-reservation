#!/usr/bin/env python3
"""生成 ISR（服务端完整版）的 512x512 封面。

版式与 ISR Lite 的封面同一套（`lite/tools/make_cover.py`）：底图是游戏内物品栏截图，
不重绘任何游戏内元素，只在上方暗色区域加两行字——
  中文「物品格预留」
  英文「ITEM SLOT RESERVATION」
主模组没有「[客户端]」前缀与 LITE 徽标，所以两行各自居中、左右边界等宽。

底图取 `main/cover/isr-base-128.png`（无字原封面），不取 `release/modicon.png`：
后者会被本脚本改写成带字的 512 版，拿它当底图会叠字。

输出：
  release/modicon.png          512x512，工坊缩略图源图（Steam 容器 512，不 upscale）
  main/cover/isr-cover-512.png 512x512 母版留档

游戏内 Mods 图标仍用 `release/images/modicon.tex`（128x128），本脚本不改它：
主模组发布已久，tex 是 DXT5 压缩版，换图需要重新编码，风险不值当。

用法：python tools/make_cover.py
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COVER_DIR = os.path.join(ROOT, "cover")
RELEASE = os.path.join(os.path.dirname(ROOT), "release")
SOURCE = os.path.join(COVER_DIR, "isr-base-128.png")

FONT_CN = r"C:\Windows\Fonts\方正粗黑宋简体.ttf"
FONT_EN = r"C:\Windows\Fonts\bahnschrift.ttf"

CREAM = (243, 227, 195)
TAN = (201, 168, 116)

TEXT_ZONE = 0.52      # 原封面 y=76/128 以下才是物品栏，上面是暗色背景
CN_WIDTH = 0.60       # 中文行占版面宽度
EN_WIDTH_RATIO = 1.0  # 英文行与中文行等宽，余量均摊成字距


def font(path, size):
    return ImageFont.truetype(path, size)


def base_layer(size):
    src = Image.open(SOURCE).convert("RGBA")
    big = src.resize((size, size), Image.LANCZOS)
    return big.filter(ImageFilter.UnsharpMask(radius=max(1, size // 300), percent=80, threshold=2))


def darken_top(img, size):
    grad = Image.new("L", (1, size), 0)
    gp = grad.load()
    for y in range(size):
        t = y / (size * TEXT_ZONE)
        gp[0, y] = int(90 * max(0.0, 1 - t) ** 1.4)
    shade = Image.new("RGBA", (size, size), (18, 11, 7, 255))
    shade.putalpha(grad.resize((size, size), Image.BILINEAR))
    return Image.alpha_composite(img, shade)


def text(img, xy, txt, fnt, fill, stroke=None, sw=0, shadow_blur=0, anchor="mm"):
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).text(xy, txt, font=fnt, fill=(0, 0, 0, 200), anchor=anchor,
                            stroke_width=sw, stroke_fill=(0, 0, 0, 200))
    if shadow_blur:
        sh = sh.filter(ImageFilter.GaussianBlur(shadow_blur))
    img.alpha_composite(sh)
    ImageDraw.Draw(img).text(xy, txt, font=fnt, fill=fill, anchor=anchor,
                             stroke_width=sw, stroke_fill=stroke)


def spaced_text(img, x, y, txt, fnt, fill, tracking, stroke=None, sw=0):
    d = ImageDraw.Draw(img)
    if stroke and sw:
        cx = x
        for ch in txt:
            d.text((cx, y), ch, font=fnt, fill=stroke, anchor="lm",
                   stroke_width=sw, stroke_fill=stroke)
            cx += d.textlength(ch, font=fnt) + tracking
    cx = x
    for ch in txt:
        d.text((cx, y), ch, font=fnt, fill=fill, anchor="lm")
        cx += d.textlength(ch, font=fnt) + tracking


def draw_title(img, size, y_cn_ratio, y_en_ratio):
    """两行等宽：中文定宽，英文缩字号后把余量均摊成字距。"""
    d = ImageDraw.Draw(img)
    cn, en = "物品格预留", "ITEM SLOT RESERVATION"

    target_cn = size * CN_WIDTH
    cn_size = target_cn / len(cn)
    for _ in range(12):
        f_cn = font(FONT_CN, max(8, int(cn_size)))
        w = sum(d.textlength(ch, font=f_cn) for ch in cn)
        if abs(w - target_cn) <= 1:
            break
        cn_size *= target_cn / w
    f_cn = font(FONT_CN, max(8, int(cn_size)))

    target_en = target_cn * EN_WIDTH_RATIO
    en_scale = 0.05
    for _ in range(20):
        f_en = font(FONT_EN, max(6, int(size * en_scale)))
        w = sum(d.textlength(ch, font=f_en) for ch in en)
        if abs(w - target_en) <= size * 0.002:
            break
        en_scale *= target_en / max(1.0, w)
    f_en = font(FONT_EN, max(6, int(size * en_scale)))
    tracking = (target_cn - sum(d.textlength(ch, font=f_en) for ch in en)) / (len(en) - 1)

    x_left = (size - target_cn) / 2
    sw_cn = max(2, int(size * 0.0048))
    sw_en = max(1, int(size * 0.0030))

    text(img, (size / 2, size * y_cn_ratio), cn, f_cn, CREAM, stroke=(24, 14, 9),
         sw=sw_cn, shadow_blur=size * 0.0035, anchor="mm")
    spaced_text(img, x_left, size * y_en_ratio, en, f_en, TAN,
                tracking, stroke=(18, 11, 7), sw=sw_en)
    return img


def build(size=2048):
    img = darken_top(base_layer(size), size)
    return draw_title(img, size, 0.245, 0.335)


def main():
    if not os.path.isfile(SOURCE):
        print("FAIL 找不到底图 %s" % SOURCE)
        return 1
    if not os.path.isdir(RELEASE):
        print("FAIL 找不到发布目录 %s" % RELEASE)
        return 1

    os.makedirs(COVER_DIR, exist_ok=True)

    cover = build(2048).resize((512, 512), Image.LANCZOS)
    shop_path = os.path.join(RELEASE, "modicon.png")
    cover.save(shop_path)
    master_path = os.path.join(COVER_DIR, "isr-cover-512.png")
    cover.save(master_path)

    print("base   %s  (%dx%d)" % (SOURCE, *Image.open(SOURCE).size))
    print("shop   %s  (%dx%d) 工坊缩略图" % (shop_path, 512, 512))
    print("master %s  (%dx%d)" % (master_path, 512, 512))
    return 0


if __name__ == "__main__":
    sys.exit(main())

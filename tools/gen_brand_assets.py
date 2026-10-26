#!/usr/bin/env python3
"""从 super_partyb 的品牌 SVG 生成各端图标资源。

## 为什么需要这个脚本

品牌标志的**真源**在姊妹仓库 `super_partyb/apps/webapp/src/app/icon.svg`
（成蹊 logo，1024×1024）。本仓库需要把它分发成 **36 个**平台图标文件
（macOS 7 / iOS 15 / Android 5 legacy + 5 adaptive + 5 splash / Windows ico /
桌面运行时 2 / 应用内 1）。

手工逐个导出的问题不是「慢」，而是**漂移**：改一次品牌色，得记得重新导出
每一个尺寸，而漏掉的那几个只有在真机/对应平台上看图标时才会发现——本仓库
的开发环境恰恰验证不了 macOS / iOS / Windows（见 AGENTS.md §9）。

故把「怎么导出」写成脚本：**改品牌 → 重跑脚本 → 一次性全部同步**。

## 前置：渲染 SVG

本脚本读的是**已经渲染好的 PNG**（`--master`），不是 SVG 本身——Dart/Flutter
环境里没有 SVG 渲染器，而 PIL 不支持 SVG。渲染这一步用 `rsvg-convert`：

```bash
# 一次性的免 sudo 安装（本仓库惯例 ~/.local/opt）
cd /tmp && mkdir -p rsvg && cd rsvg
apt-get download librsvg2-bin && dpkg-deb -x librsvg2-bin_*.deb root

# 渲染真源 SVG 到 1024×1024 中间图
cd /path/to/super_partyb
/tmp/rsvg/root/usr/bin/rsvg-convert -w 1024 -h 1024 \
  apps/webapp/src/app/icon.svg -o /tmp/logo-master.png

# 生成全部图标
cd /path/to/super_partyb-flutter
python3 tools/gen_brand_assets.py --master /tmp/logo-master.png
```

## 各端的形状约定（**不是随便填满**）

| 平台 | 形态 | 为什么 |
|---|---|---|
| iOS | 满幅正方形、**无 alpha** | App Store 拒绝带透明通道的 1024 图标；系统自己加圆角遮罩 |
| Android legacy | 满幅正方形 | 系统按 density 选图，不做裁切 |
| Android adaptive | 背景色 + **透明底**前景区 | API 26+ 由启动器按厂商形状裁切；前景的标志须落在 66% 安全区 |
| macOS | **圆角方形 + 留白** | Big Sur 起的栅格：1024 画布内 824×824 圆角矩形（圆角 185），四周各留 100 |
| Windows .ico | 满幅多尺寸内嵌 | 资源管理器按尺寸挑帧 |
| 桌面运行时 | 满幅（托盘 64 / 窗口 256） | GTK / Windows 自己缩放；窗口图标会被 Alt+Tab 放大，用 64 会糊 |

## 为什么 adaptive 前景要「反预乘」解出 alpha

品牌 logo 里的对勾是**背景色透出来的**（浅色气泡上挖空），不是画上去的蓝。
前景层必须表达成「透明底 + 浅色气泡 + 镂空对勾」，让背景层的蓝填回洞里。

源图 = `alpha·light + (1-alpha)·bg`。按亮度反解 alpha 再反预乘还原颜色，
边缘（抗锯齿像素）自然过渡，不会出现一圈蓝边——直接阈值化抠图会留下硬边。

## 颜色一致性

品牌蓝 `#1a5cd7` 在本仓库出现三处，**必须一致**：

- `packages/spb_ui/lib/src/spb_logo.dart` 的 `SpbLogo.brandBlue`
- `apps/spb_mobile/android/app/src/main/res/values/colors.xml` 的 `ic_launcher_background`
- `apps/spb_mobile/ios/Runner/Base.lproj/LaunchScreen.storyboard` 的 backgroundColor

不一致时，自适应图标的对勾会变成另一种蓝（前景洞透出背景），而启动画面会
与首屏「闪一下」。本脚本从 SVG 的 `rect fill` 读取，不写死。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover - 环境问题，直接给出可执行的提示
    sys.exit('❌ 需要 Pillow：pip install --user Pillow')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 品牌蓝的兜底值（与源 SVG 的 `rect fill` 一致）。正常情况下由
# --svg 读取覆盖，避免「脚本里写死一份、SVG 改了却不同步」。
DEFAULT_BRAND = (26, 92, 215)  # #1a5cd7

# adaptive 图标前景里「气泡边长 / 108dp 画布」的比例。
#
# 0.40 → 可见区（中央 72dp）内气泡占 60%，圆形遮罩下四周留出约 20% 呼吸空间。
# 取 0.49（源图的实际占比）会让气泡在圆形遮罩下贴边（实测预览确认过）。
ADAPTIVE_LOGO_RATIO = 0.40

# macOS 图标栅格（Big Sur 起）：1024 画布内 824×824 圆角矩形，圆角 185。
MAC_INSET = 100
MAC_RADIUS = 185
MAC_BOX = 1024 - 2 * MAC_INSET

IOS_SIZES = {
    '20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60,
    '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87,
    '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120,
    '60x60@2x': 120, '60x60@3x': 180,
    '76x76@1x': 76, '76x76@2x': 152,
    '83.5x83.5@2x': 167,
    '1024x1024@1x': 1024,
}

ANDROID_DENSITIES = {
    'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0,
}


def brand_from_svg(svg_path: str) -> tuple[int, int, int]:
    """从源 SVG 的根 `rect` 读品牌底色。读不到则用兜底值。"""
    try:
        with open(svg_path, encoding='utf-8') as fh:
            text = fh.read()
    except OSError:
        return DEFAULT_BRAND
    m = re.search(r'<rect[^>]*fill="(#[0-9a-fA-F]{6})"', text)
    if not m:
        return DEFAULT_BRAND
    h = m.group(1).lstrip('#')
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


class Generator:
    def __init__(self, master: Image.Image, brand: tuple[int, int, int]):
        self.master = master
        self.brand = brand
        self.written: list[str] = []

    # -- 基础 ---------------------------------------------------------------
    def resize(self, size: int) -> Image.Image:
        return self.master.resize((size, size), Image.LANCZOS)

    def save(self, im: Image.Image, rel: str) -> None:
        full = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        im.save(full, format='PNG', optimize=True)
        self.written.append(rel)

    # -- 各平台 -------------------------------------------------------------
    def macos(self) -> None:
        """圆角方形 + 四周留白（Big Sur 栅格）。"""
        base = 'apps/spb_desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset'
        for size in (16, 32, 64, 128, 256, 512, 1024):
            scale = size / 1024.0
            box = max(1, round(MAC_BOX * scale))
            inset = round(MAC_INSET * scale)
            radius = round(MAC_RADIUS * scale)

            canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
            art = self.master.resize((box, box), Image.LANCZOS).convert('RGBA')

            # 超采样后缩放圆角蒙版：16/32 直接画圆角会有明显锯齿。
            mask = Image.new('L', (box * 4, box * 4), 0)
            ImageDraw.Draw(mask).rounded_rectangle(
                (0, 0, box * 4 - 1, box * 4 - 1), radius=radius * 4, fill=255)
            art.putalpha(mask.resize((box, box), Image.LANCZOS))
            canvas.paste(art, (inset, inset), art)
            self.save(canvas, f'{base}/app_icon_{size}.png')

    def ios(self) -> None:
        """满幅、无 alpha（App Store 的硬性要求）。"""
        base = 'apps/spb_mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset'
        for name, size in IOS_SIZES.items():
            self.save(self.resize(size), f'{base}/Icon-App-{name}.png')

    def android(self) -> None:
        base = 'apps/spb_mobile/android/app/src/main/res'
        # legacy（API < 26）
        for density, factor in ANDROID_DENSITIES.items():
            size = round(48 * factor)
            self.save(self.resize(size), f'{base}/mipmap-{density}/ic_launcher.png')
        # adaptive foreground：逻辑画布 108dp，按 density 放大到实际像素
        fg = self.adaptive_foreground()
        for density, factor in ANDROID_DENSITIES.items():
            size = round(108 * factor)
            self.save(
                fg.resize((size, size), Image.LANCZOS),
                f'{base}/drawable-{density}/ic_launcher_foreground.png')
        # 启动画面（96dp）
        for density, factor in ANDROID_DENSITIES.items():
            size = round(96 * factor)
            self.save(self.resize(size), f'{base}/drawable-{density}/launch_logo.png')

    def adaptive_foreground(self) -> Image.Image:
        """108dp 画布：透明底 + 居中的浅色气泡（反预乘解 alpha）。

        ## 为什么要**缩小后再居中**，而不是直接拿满幅 logo 当画布

        自适应图标的两条硬规则：

        1. 启动器只显示画布的中央 **72dp**（108dp 的 66%），其余部分会被裁掉
           或被相邻图标覆盖；
        2. 圆形 / squircle 遮罩会再切掉 72dp 正方形的四角。

        品牌 logo 里的气泡在源图中占 1024 的 **49%**。若直接铺满 108dp 画布，
        气泡就是 108 的 49% ≈ 53dp，而可见区只有 72dp——气泡会占到可见直径的
        74%，在圆形遮罩下**贴着边**（实测预览图确实如此）。

        故先提取气泡，再按「气泡 = 画布的 40%」重新居中：可见区内气泡占 60%，
        圆形遮罩四周留出约 20% 的呼吸空间，与 Material 图标的视觉重量一致。
        """
        bubble = self._extract_bubble()

        canvas_size = 108
        target = round(canvas_size * ADAPTIVE_LOGO_RATIO)
        art = bubble.resize((target, target), Image.LANCZOS)

        canvas = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
        offset = (canvas_size - target) // 2
        canvas.alpha_composite(art, (offset, offset))
        return canvas

    def _extract_bubble(self) -> Image.Image:
        """把源图里「浅色气泡 + 镂空对勾」抠成透明底图层。

        源图 = `alpha·light + (1-alpha)·bg`。按亮度反解 alpha 再反预乘还原颜色，
        边缘（抗锯齿像素）自然过渡，不会出现一圈蓝边——直接阈值化抠图会留下硬边。
        """
        w, h = self.master.size
        src = self.master.load()
        out = Image.new('RGBA', (w, h))
        dst = out.load()

        br, bg_, bb = self.brand
        luma_bg = 0.299 * br + 0.587 * bg_ + 0.114 * bb
        luma_light = 0.299 * 236 + 0.587 * 243 + 0.114 * 254

        for y in range(h):
            for x in range(w):
                r, g, b = src[x, y]
                luma = 0.299 * r + 0.587 * g + 0.114 * b
                a = (luma - luma_bg) / (luma_light - luma_bg)
                if a < 0.02:
                    continue  # 留空（(0,0,0,0)）
                if a > 0.98:
                    a = 1.0
                # 反预乘：light = (src - (1-a)·bg) / a
                lr = (r - (1 - a) * br) / a
                lg = (g - (1 - a) * bg_) / a
                lb = (b - (1 - a) * bb) / a
                dst[x, y] = (
                    max(0, min(255, round(lr))),
                    max(0, min(255, round(lg))),
                    max(0, min(255, round(lb))),
                    round(a * 255),
                )
        # 裁到气泡包围盒：让「气泡占画布多少」由 ADAPTIVE_LOGO_RATIO 决定，
        # 而不是被源图的四周留白稀释。
        return out.crop(out.getbbox())

    def windows(self) -> None:
        rel = 'apps/spb_desktop/windows/runner/resources/app_icon.ico'
        full = os.path.join(ROOT, rel)
        sizes = [16, 32, 48, 256]
        self.resize(256).save(
            full, format='ICO', sizes=[(s, s) for s in sizes])
        self.written.append(rel)

    def desktop_runtime(self) -> None:
        """托盘 64 / 窗口 256。"""
        self.save(self.resize(64), 'apps/spb_desktop/assets/tray_icon.png')
        self.save(self.resize(256), 'apps/spb_desktop/assets/app_icon.png')

    def in_app(self) -> None:
        """应用内标志（登录页）。随 spb_ui 包分发，两端共用一份。"""
        self.save(self.resize(256), 'packages/spb_ui/assets/brand/logo.png')

    def run(self) -> None:
        self.macos()
        self.ios()
        self.android()
        self.windows()
        self.desktop_runtime()
        self.in_app()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--master', required=True,
                    help='rsvg-convert 渲染出的 1024×1024 PNG')
    ap.add_argument('--svg', default=None,
                    help='源 SVG（仅用于读取品牌底色，可选）')
    ap.add_argument('--dry-run', action='store_true',
                    help='只列出将要写的文件，不落盘')
    args = ap.parse_args()

    if not os.path.isfile(args.master):
        print(f'❌ 找不到 {args.master}（先用 rsvg-convert 渲染，见文件头）')
        return 1

    master = Image.open(args.master).convert('RGB')
    if master.size != (1024, 1024):
        print(f'❌ master 必须是 1024×1024，实际 {master.size[0]}×{master.size[1]}')
        return 1

    brand = brand_from_svg(args.svg) if args.svg else DEFAULT_BRAND
    gen = Generator(master, brand)
    if args.dry_run:
        # 试运行：把 save 换成只记录
        gen.save = lambda im, rel: gen.written.append(rel)  # type: ignore[method-assign]
    gen.run()

    action = '将写入' if args.dry_run else '已写入'
    print(f'品牌底色 #{brand[0]:02x}{brand[1]:02x}{brand[2]:02x}')
    for rel in gen.written:
        print(f'  {action} {rel}')
    print(f'\n共 {len(gen.written)} 个文件')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

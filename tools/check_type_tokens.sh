#!/usr/bin/env bash
# 守卫：字号只能来自 `SpbType` 令牌，`labelSmall`(11px) 需要就地说明理由。
#
# ## 它防的是什么
#
# §6.76 把「列表元数据 11px」定为缺陷，并给了 `SpbType` 语义令牌；§6.78 把
# 聊天面板/状态条里剩下的 68 处 `labelSmall` 一并迁走。两次都是**一次性清扫**，
# 而清扫没有守卫＝两周后照旧长回来：下一个页面只要「顺手挑个槽位」，就会
# 又出现 11px 的状态词、`copyWith(fontSize: 10)` 的角标——这正是 §6.76 缺陷
# 的原始形态，而它**任何测试都不会红**（golden 只盖 12 张按钮/空态/spec 卡）。
#
# ## 判定规则（两条，都需要就地豁免注释）
#
# 1. **数字字号字面量**：`fontSize: 12` / `copyWith(fontSize: 10)`。
#    绘制场景（`TextPainter` 拿不到 `TextTheme`）不是漏洞——令牌提供了
#    `SpbType.metaSize` 字面值，`fontSize: SpbType.metaSize` 因此**不**被拦。
#
# 2. **`labelSmall`**：它是 M3 的 11px 槽位，理论上只该出现在「纯装饰」
#    或「受 golden 锁定的既有基线」上。
#
# 命中后两种情况都要求：该行或**前两行**出现 `字号守卫豁免：<理由>`。
# 理由必须非空（光写「豁免」不算想过）。
#
# ## 为什么用就地注释而不是白名单
#
# 与 `tools/check_silent_catches.sh` 同一个理由：白名单会随重构腐化（文件改名
# /移动后条目失效，而没人回头清理），且新增的 11px 需要「记得去加白名单」——
# 那正是本脚本想避免的「靠人记得」。把理由写在原地，改代码的人一定会看到。
#
# ## 为什么扫 `lib/` 而不扫 `test/`
#
# 测试里断言字号是**读值**（`theme.textTheme.labelSmall` 拿来比较），不是
# 挑槽位渲染；扫进来只会得到一堆假红。golden 测试里的 `fontSize` 同理。
#
# ## 为什么排除 `packages/spb_design/lib`
#
# 令牌本身就住在那里（`SpbType.badgeCount` 基于 `labelSmall` 归零字距），
# 它是**唯一**允许提这三个槽位的地方。排除后令牌之外无人能碰，规则才成立。
#
# ## 空转保护
#
# 与 `tools/check_codegen.sh` 的坑同型：若扫描路径写错（包名改动）会扫到 0 个
# 文件却报「通过」。故要求至少命中一处 `SpbType.` 调用，否则硬失败。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 <<'PY'
import pathlib
import re
import sys

# ── 扫描范围 ──────────────────────────────────────────────────────────
ROOTS = [pathlib.Path('packages'), pathlib.Path('apps')]
EXCLUDED = {'packages/spb_design/lib'}

FILES = sorted(
    p
    for root in ROOTS
    if root.is_dir()
    for p in root.glob('*/lib/**/*.dart')
    if p.is_file() and not any(str(p).startswith(ex) for ex in EXCLUDED)
)

# ── 规则 ─────────────────────────────────────────────────────────────
# 只抓**数字字面量**：`fontSize: SpbType.metaSize` / `fontSize: size` 放行。
NUMERIC_FONT_SIZE = re.compile(r'fontSize:\s*[0-9]+(?:\.[0-9]+)?')
LABEL_SMALL = re.compile(r'\blabelSmall\b')
MARKER = re.compile(r'字号守卫豁免[：:]\s*\S')
SPBTYPE_USE = re.compile(r'\bSpbType\.')


def strip_strings(line: str) -> str:
    """去掉字符串字面量（含转义），避免把文案里的 `//` 当成注释起点。

    只做「能数清引号」这一件事：本仓库的 Dart 源码里没有跨行的裸字符串
    （有的话格式化会被破坏），故逐行处理足够。
    """
    out = []
    quote = None
    escaped = False
    for ch in line:
        if quote:
            if escaped:
                escaped = False
            elif ch == '\\':
                escaped = True
            elif ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
            continue
        out.append(ch)
    return ''.join(out)


def code_part(line: str) -> str:
    """返回去掉注释后的代码片段（行尾注释也不参与判定）。"""
    text = strip_strings(line)
    idx = text.find('//')
    return text if idx < 0 else text[:idx]


def exempted(lines, i) -> bool:
    """该行或前两行有带理由的豁免注释。"""
    for j in (i, i - 1, i - 2):
        if j >= 0 and MARKER.search(lines[j]):
            return True
    return False


violations = []
token_calls = 0
files_with_token = set()

for path in FILES:
    lines = path.read_text(encoding='utf-8').split('\n')
    for i, raw in enumerate(lines):
        code = code_part(raw)
        if SPBTYPE_USE.search(code):
            token_calls += 1
            files_with_token.add(path)
        hits = []
        if NUMERIC_FONT_SIZE.search(code):
            hits.append('数字字号字面量')
        if LABEL_SMALL.search(code):
            hits.append('labelSmall（11px 槽位）')
        if not hits:
            continue
        if exempted(lines, i):
            continue
        violations.append((path, i + 1, '、'.join(hits), raw.strip()))

if not files_with_token:
    print(
        '❌ 空转：扫描范围内没有任何 `SpbType.` 调用——路径或包名可能已改动。',
        file=sys.stderr,
    )
    sys.exit(1)

if violations:
    print(
        f'❌ 字号令牌检查失败（{len(violations)} 处）：',
        file=sys.stderr,
    )
    for path, line_no, kind, text in violations:
        print(f'   {path}:{line_no}: {kind}', file=sys.stderr)
        print(f'      {text}', file=sys.stderr)
    print(
        '\n改法（见 AGENTS.md §6，全文 docs/design-decisions/ui.md §6.76/§6.78）：\n'
        '  • 元数据/状态词/来源/数量 → `SpbType.listMeta(theme.textTheme)`\n'
        '  • 徽标/状态 chip/导航标签 → `SpbType.badge(theme.textTheme)`\n'
        '  • 角标数字 → `SpbType.badgeCount(theme.textTheme)`\n'
        '  • 正文 → `SpbType.body(theme.textTheme)`；块标题 → `SpbType.cardTitle(theme.textTheme)`\n'
        '  • Canvas 绘制（TextPainter）→ `fontSize: SpbType.metaSize`\n'
        '确实只能用 11px（纯装饰或受 golden 锁定的基线）时，在该行或前两行写：\n'
        '  // 字号守卫豁免：<为什么这里必须 11px>',
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f'✅ 字号令牌检查通过（{len(FILES)} 个文件、{token_calls} 处 SpbType 调用；'
    '无裸字号、无未说明的 labelSmall）'
)
PY

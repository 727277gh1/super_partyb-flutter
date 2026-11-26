#!/usr/bin/env bash
# 守卫：字号只能来自 `SpbType` 令牌，`labelSmall`(11px) 需要就地说明理由，
# 小字号文字不得再叠加透明度。
#
# ## 它防的是什么
#
# §6.76 把「列表元数据 11px」定为缺陷，并给了 `SpbType` 语义令牌；§6.78 把
# 聊天面板/状态条里剩下的 68 处 `labelSmall` 一并迁走。两次都是**一次性清扫**，
# 而清扫没有守卫＝两周后照旧长回来：下一个页面只要「顺手挑个槽位」，就会
# 又出现 11px 的状态词、`copyWith(fontSize: 10)` 的角标——这正是 §6.76 缺陷
# 的原始形态，而它**任何测试都不会红**（golden 只盖 12 张按钮/空态/spec 卡）。
#
# 规则 3 防的是同一篇 §6.78 里**没有守卫**的那条：「小字号不再叠加透明度」。
# 当时清掉的 6 处后来真的长回来了 5 处（#127）——因为脚本只查前两条，
# 「规则写在文档里、判定靠人记得」必然回流。
#
# ## 判定规则（三条，都需要就地豁免注释）
#
# 1. **数字字号字面量**：`fontSize: 12` / `copyWith(fontSize: 10)`。
#    绘制场景（`TextPainter` 拿不到 `TextTheme`）不是漏洞——令牌提供了
#    `SpbType.metaSize` 字面值，`fontSize: SpbType.metaSize` 因此**不**被拦。
#
# 2. **`labelSmall`**：它是 M3 的 11px 槽位，理论上只该出现在「纯装饰」
#    或「受 golden 锁定的既有基线」上。
#
# 3. **小字号文字叠加透明度**：以 `SpbType.listMeta` / `badge` / `badgeCount` /
#    `bodySmall` / `labelSmall` / `labelMedium` 这类**小字文字样式**为锚点，
#    沿括号配平把整段表达式（含跨行 `copyWith`、局部样式变量）取出来，
#    段内出现 `alpha < 1` 的降透明度即违规。锚点只在该表达式内生效，
#    所以「同一文件里既有小字又有 alpha」**不会**误报；边框、背景、
#    装饰图标的 alpha 不在小字表达式里，也不属于本规则。
#    依据：12px 已经贴着可读下界，`onSecondaryContainer` 压到 0.8 是 4.45:1、
#    0.7 是 3.54:1，都在 WCAG AA 的 4.5 之下（§6.78 规则 3）。
#
# 规则 1、2 命中后要求：该行或**前两行**出现 `字号守卫豁免：<理由>`。
# 规则 3 要求 `透明度守卫豁免：<理由>`。理由必须非空（光写「豁免」不算想过）。
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

# 规则 3：小字文字样式的锚点。只认「文字样式」这一侧，不认 `Icon(...)`。
SMALL_TEXT_STYLE = re.compile(
    r'\b(?:'
    r'SpbType\.(?:listMeta|badge|badgeCount)'
    r'|textTheme\.(?:bodySmall|labelSmall|labelMedium)'
    r'|(?:bodySmall|labelSmall|labelMedium)\b'
    r')'
)
# 降透明度的三种写法：`withValues(alpha: …)`、`withOpacity(…)`、
# 带 alpha 字节的 `Color(0xAARRGGBB)`（前两位不是 ff 即为半透明）。
ALPHA_DROP = re.compile(
    r'withValues\(\s*alpha:\s*(0?\.\d+(?:_\d+)*|\d+(?:\.\d+)?)\s*\)'
    r'|withOpacity\(\s*(0?\.\d+(?:_\d+)*|\d+(?:\.\d+)?)\s*\)'
    r'|Color\(\s*(?:0x)?([0-9a-fA-F]{8})\s*\)'
)
ALPHA_MARKER = re.compile(r'透明度守卫豁免[：:]\s*\S')
# 表达式窗口上限：跨行 `copyWith` 很少超过几行；给足余量但不至于吞掉整个函数。
MAX_EXPR_LINES = 12


def _alpha_below_one(line: str) -> bool:
    """该行是否含 `alpha < 1` 的降透明度写法。"""
    for m in ALPHA_DROP.finditer(line):
        a, o, hexcolor = m.group(1), m.group(2), m.group(3)
        if hexcolor:
            if int(hexcolor[:2], 16) < 0xFF:
                return True
            continue
        raw = (a or o).replace('_', '')
        try:
            if float(raw) < 1.0:
                return True
        except ValueError:
            continue
    return False


def _balanced(text: str) -> int:
    """括号净差（`(` 记正、`)` 记负）。字符串与注释已在调用方剥掉。"""
    return text.count('(') - text.count(')')


def small_text_alpha_hits(lines, codes) -> set[int]:
    """规则 3 的命中行号集合（0 基）。

    从锚点行开始，沿括号配平把整段表达式取出来，段内的降透明度才算违规——
    这样「同一文件里既有小字、又有别处的 alpha」不会误报，而跨行 `copyWith`
    与局部样式变量都能覆盖到。
    """
    hits: set[int] = set()
    for i, code in enumerate(codes):
        if not SMALL_TEXT_STYLE.search(code):
            continue
        depth = 0
        j = i
        while j < len(codes) and j < i + MAX_EXPR_LINES:
            if _alpha_below_one(codes[j]):
                hits.add(j)
            depth += _balanced(codes[j])
            j += 1
            if depth <= 0:
                break
    return hits


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


def exempted(lines, i, marker=MARKER) -> bool:
    """该行或前两行有带理由的豁免注释。"""
    for j in (i, i - 1, i - 2):
        if j >= 0 and marker.search(lines[j]):
            return True
    return False


violations = []
token_calls = 0
files_with_token = set()

for path in FILES:
    lines = path.read_text(encoding='utf-8').split('\n')
    codes = [code_part(raw) for raw in lines]
    for i, code in enumerate(codes):
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
        violations.append((path, i + 1, '、'.join(hits), lines[i].strip()))

    # ── 规则 3：小字 + 降透明度 ──
    for i in sorted(small_text_alpha_hits(lines, codes)):
        if exempted(lines, i, ALPHA_MARKER):
            continue
        violations.append(
            (
                path,
                i + 1,
                '小字号文字叠加透明度（§6.78 规则 3）',
                lines[i].strip(),
            )
        )

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
        '  • 小字要拉开层次 → 换字重（w600）或主题色，**不要** `withValues(alpha: …)`\n'
        '    （12px + 0.8 只有 4.45:1，0.7 只有 3.54:1，都在 WCAG AA 之下）\n'
        '确实只能用 11px（纯装饰或受 golden 锁定的基线）时，在该行或前两行写：\n'
        '  // 字号守卫豁免：<为什么这里必须 11px>\n'
        '确实需要半透明小字（例如被 golden 锁定的既有基线）时，在该行或前两行写：\n'
        '  // 透明度守卫豁免：<为什么这里必须半透明>',
        file=sys.stderr,
    )
    sys.exit(1)

print(
    f'✅ 字号令牌检查通过（{len(FILES)} 个文件、{token_calls} 处 SpbType 调用；'
    '无裸字号、无未说明的 labelSmall、无未说明的小字降透明度）'
)
PY

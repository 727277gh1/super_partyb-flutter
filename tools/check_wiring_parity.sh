#!/usr/bin/env bash
# 守卫：两端装配层对**同一个共享组件**的接线必须一致。
#
# ## 为什么需要它
#
# `ConversationPage` 的具名参数有 46 个，两端 router 各传 40+ 个。两端源码里
# 有 11 处注释写着「两端构造点必须一致，否则一端功能缺失而测试仍绿」——**约定
# 靠注释，不靠工具**。而这个约定已经失效过一次：移动端 `enableSearch: false`
# 配上宽屏返回 null 的 `overflowItems`，使 ≥720dp 的对话内搜索入口彻底不可达
# （issue #33），两端测试全绿。
#
# 根因不是某一处写错，而是「漏接线」这件事**没有任何自动化信号**：
# - Dart 编译器只保证「传了的参数存在」，不管「另一端也传了」；
# - 页面测试自己传参，接不接线它不管（`conversation_page_test.dart` 全绿）；
# - 两端 router 测试各自只覆盖自己那端。
#
# 故这里对两端 `ConversationPage(` 的具名参数做**集合比对**：差异必须命中
# 下面的显式豁免清单，否则报错并列出差异。
#
# ## 豁免为什么要写死在脚本里
#
# 「桌面端有 `onOpenAgentFile`、移动端没有」是**有意的产品差异**（移动端注入
# `NoopDesktopCapabilities`，`openFile`/`revealPath` 恒 false，接上会让用户点
# 「打开」得到「无法打开」）。豁免必须显式、可审计——写成「两端取交集」会把
# 这类有意差异也一起藏掉，那才是真的失去守卫。
#
# ## 不检查什么
#
# - **值**：两端传的**表达式**不同是正常的（`enableSearch` 就按宽度给）。本
#   脚本只比对**参数名**是否存在，不解析值语义。
# - **provider 层**：两端 `providers.dart` 有 88 个同名 provider，上提到共享包
#   是独立的重构（见 issue #39），不在本守卫范围。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f apps/spb_desktop/lib/router.dart ] || \
   [ ! -f apps/spb_mobile/lib/router.dart ]; then
  echo "❌ 未找到两端 router.dart（工作目录不对？）"
  exit 1
fi

python3 - <<'PY'
import re
import sys

# 被检查的共享组件调用点。
#
# `exempt` 是**有意**的单端参数（不是「还没接」）：
#   - onOpenAgentFile / onRevealAgentFile：桌面端能力，移动端 Noop 降级，
#     接上会得到「无法打开文件」（AGENTS.md §6.10）；
#   - overflowItems：窄屏溢出菜单是移动端独有的载体，桌面端有宽屏余量、
#     直接摆独立图标（AGENTS.md §6.16）。
TARGETS = [
    {
        'component': 'ConversationPage',
        'decl': 'packages/spb_features/lib/src/chat/conversation_page.dart',
        'sites': {
            'desktop': 'apps/spb_desktop/lib/router.dart',
            'mobile': 'apps/spb_mobile/lib/router.dart',
        },
        'exempt': {
            'desktop': {'onOpenAgentFile', 'onRevealAgentFile'},
            'mobile': {'overflowItems'},
        },
    },
]


def blank_strings_and_comments(src):
    """把注释删掉、把字符串内容抹成空格，只留结构。

    必须保留字符串**长度与换行**（行号才对得上），故用空格替换而不是删除。
    不这么做的话，字符串里的 `,` / `(` / `)` 会被当成参数分隔符或括号——
    而 `reason: 'a, b'` 这类写法在真实代码里很常见。
    """
    out = []
    i = 0
    n = len(src)
    quote = None
    while i < n:
        c = src[i]
        if quote:
            if c == '\\':
                out.append(' ')
                out.append(' ' if i + 1 < n else '')
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(c)
            else:
                out.append('\n' if c == '\n' else ' ')
            i += 1
            continue
        # 三引号（多行字符串）：整体抹掉。
        if c in "'\"" and src[i:i + 3] == c * 3:
            end = src.find(c * 3, i + 3)
            end = n if end == -1 else end + 3
            for ch in src[i:end]:
                out.append('\n' if ch == '\n' else ' ')
            i = end
            continue
        if c in "'\"":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out.append(' ')
                i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            out.append(' ')
            out.append(' ')
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                out.append('\n' if src[i] == '\n' else ' ')
                i += 1
            if i + 1 < n:
                out.append(' ')
                out.append(' ')
                i += 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def call_args(src, component):
    """取 `component(` 那一对括号里的具名参数名（按出现顺序）。"""
    code = blank_strings_and_comments(src)
    marker = component + '('
    if marker not in code:
        return None
    start = code.index(marker) + len(component)
    depth = 0
    end = None
    for p in range(start, len(code)):
        if code[p] == '(':
            depth += 1
        elif code[p] == ')':
            depth -= 1
            if depth == 0:
                end = p
                break
    if end is None:
        raise SystemExit(f'❌ {component}( 的括号没有闭合')

    body = code[start + 1:end]
    args = []
    depth = 0
    cur = ''
    for ch in body:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        args.append(cur.strip())

    names = []
    for a in args:
        if a.startswith('...'):  # 展开（目前没有，将来有则跳过）
            continue
        if ':' in a:
            names.append(a.split(':', 1)[0].strip())
    return names


def declared_params(src, component):
    """从 `component` 的构造函数里取 `this.xxx` 形式的具名参数名。"""
    code = blank_strings_and_comments(src)
    i = code.index(f'class {component} extends StatefulWidget')
    j = code.index(';', i)
    # 构造函数体到第一个字段声明之间。
    k = code.index('const ' + component + '(', i)
    depth = 0
    end = None
    for p in range(k, len(code)):
        if code[p] == '(':
            depth += 1
        elif code[p] == ')':
            depth -= 1
            if depth == 0:
                end = p
                break
    return re.findall(r'this\.(\w+)', code[k:end])


failed = False

for t in TARGETS:
    comp = t['component']
    decl_src = open(t['decl'], encoding='utf-8').read()
    declared = declared_params(decl_src, comp)

    per_end = {}
    for end, path in t['sites'].items():
        args = call_args(open(path, encoding='utf-8').read(), comp)
        if args is None:
            print(f'❌ {path}: 找不到 {comp}( 构造点')
            failed = True
            continue
        per_end[end] = args

        # 传了的名字必须在构造函数里声明过（拼错/改名会在这里暴露）。
        unknown = [a for a in args if a not in declared]
        if unknown:
            print(f'❌ {path}: 传了 {comp} 没有的参数：{sorted(set(unknown))}')
            failed = True

        dups = sorted({a for a in args if args.count(a) > 1})
        if dups:
            print(f'❌ {path}: 重复传参：{dups}')
            failed = True

    if failed or len(per_end) != len(t['sites']):
        continue

    ends = sorted(per_end)
    a, b = ends[0], ends[1]
    only_a = set(per_end[a]) - set(per_end[b])
    only_b = set(per_end[b]) - set(per_end[a])

    for end, missing, extra in ((a, only_a, only_b), (b, only_b, only_a)):
        allowed = t['exempt'].get(end, set())
        unexpected = sorted(missing - allowed)
        if unexpected:
            print(f'❌ {t["sites"][end]}: 相比另一端多传了 {comp} 参数 '
                  f'{unexpected}——另一端会缺这个接线（且测试仍绿）。')
            print(f'   若是有意的单端差异，请加进 check_wiring_parity.sh 的 '
                  f'exempt["{end}"] 并注明理由。')
            failed = True

        # 反向：豁免清单里列了、但实际两端都有（说明豁免已过期，该删）。
        stale = sorted(allowed - missing)
        if stale:
            print(f'⚠️  {t["sites"][end]}: 豁免清单已过期（两端都传了）：{stale}')
            failed = True

    if not failed:
        print(f'✅ {comp} 接线一致（{len(per_end[a])} / {len(per_end[b])} 个参数；'
              f'{a} 单端豁免 {sorted(t["exempt"][a])}，'
              f'{b} 单端豁免 {sorted(t["exempt"][b])}）')

if failed:
    sys.exit(1)
PY

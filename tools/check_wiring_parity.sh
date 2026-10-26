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
# 故这里对两端共享组件构造点的具名参数做**集合比对**：差异必须命中下面的
# 显式豁免清单，否则报错并列出差异。
#
# ## 覆盖面（issue #42）
#
# 最初只登记了 `ConversationPage`。其余共享页面同样有单端差异（桌面端有托盘/
# 快捷键/诊断导出，移动端有小程序订阅额度），且**同样没有守卫**。现已扩到
# 4 个组件：`ConversationPage` / `GroupListPage` / `SettingsPage` / `SyncPage`。
#
# ⚠️ **`SyncPage` 的差异曾被本脚本误判为「两端一致」**——因为匹配用了
# `component + '('` 的裸子串搜索，而两端 router 里各有一个同名的私有包装
# （`class _SyncPage extends ConsumerWidget`，转成 `ConsumerStatefulWidget`）。
# `_SyncPage(` 里含 `SyncPage(` 子串，`index()` 命中的是**包装**而不是真正的
# 构造点（参数为零），于是「零参数 == 零参数」被判为一致——**假绿**。
#
# 故 `call_args_all` 现在用 `(?<![A-Za-z0-9_])` 词边界，且返回**全部**调用点
# （调用方取并集）而不是只取第一个：漏掉的调用点会静默降低覆盖。
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
# `exempt` 是**有意**的单端参数（不是「还没接」）。每条都必须在下方注明理由
# ——豁免清单是给人审的，没有理由的条目下次重构时没人敢删。
TARGETS = [
    {
        'component': 'ConversationPage',
        'decl': 'packages/spb_features/lib/src/chat/conversation_page.dart',
        'sites': {
            'desktop': 'apps/spb_desktop/lib/router.dart',
            'mobile': 'apps/spb_mobile/lib/router.dart',
        },
        'exempt': {
            # 桌面端能力，移动端 Noop 降级，接上会得到「无法打开文件」
            # （AGENTS.md §6.10）。
            'desktop': {'onOpenAgentFile', 'onRevealAgentFile'},
            # 窄屏溢出菜单是移动端独有的载体，桌面端有宽屏余量、直接摆独立
            # 图标（AGENTS.md §6.16）。
            'mobile': {'overflowItems'},
        },
    },
    {
        'component': 'GroupListPage',
        'decl': 'packages/spb_features/lib/src/chat/group_list_page.dart',
        'sites': {
            'desktop': 'apps/spb_desktop/lib/router.dart',
            'mobile': 'apps/spb_mobile/lib/router.dart',
        },
        'exempt': {
            # 全局设置入口：桌面端**没有标签栏**，设置只能从 AppBar / 托盘进
            # （AGENTS.md §6.11）；移动端设置是底部标签栏的一级 tab
            # （`_AppShell` 的 `NavigationBar`），AppBar 再放一个就是同一目标
            # 的第二个入口，而窄屏 AppBar 已有 5 个常驻图标（§6.16 的溢出教训）。
            'desktop': {'onOpenSettings'},
            # 无归属快速输入（带附件）在移动端是 AppBar 入口（AGENTS.md §6.7）；
            # 桌面端走 Alt+Space 悬浮窗（§6.5），列表页不需要这个入口。
            'mobile': {'onOpenQuickCapture'},
        },
    },
    {
        'component': 'SettingsPage',
        'decl': 'packages/spb_features/lib/src/settings/settings_page.dart',
        'sites': {
            'desktop': 'apps/spb_desktop/lib/router.dart',
            'mobile': 'apps/spb_mobile/lib/router.dart',
        },
        'exempt': {
            'desktop': {
                # 托盘 / 全局快捷键是桌面专属（AGENTS.md §6.11）。
                'loadLaunchAtStartup',
                'setLaunchAtStartup',
                # `revealPath` 在移动端恒 false（AGENTS.md §6.10）。
                'onOpenDirectory',
                # `file_selector.getSaveLocation` 在 Android/iOS 未实现
                # （AGENTS.md §6.20）。
                'onExportDiagnostics',
                # 自动同步排程器只在桌面端装配（移动端后台定时器不可靠，
                # 系统会冻结/杀进程）。按「不展示点了没反应的开关」的
                # 既有取向，移动端传 `showAutoSync: false`（默认值）。
                # 见 AGENTS.md §6.42。
                'showAutoSync',
            },
            # 微信小程序订阅消息额度（AGENTS.md §6.9.1）：桌面端没有小程序
            # 运行环境，展示它无法兑现。
            'mobile': {'loadNotifications', 'saveNotifications'},
        },
    },
    {
        'component': 'SyncPage',
        'decl': 'packages/spb_features/lib/src/sync/sync_page.dart',
        'sites': {
            'desktop': 'apps/spb_desktop/lib/router.dart',
            'mobile': 'apps/spb_mobile/lib/router.dart',
        },
        'exempt': {
            # 移动端无「同步目录」概念（NoopDesktopCapabilities，§6.10）。
            'desktop': {'onOpenDirectory'},
            'mobile': set(),
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


def call_args_all(src, component):
    """取**全部** `component(` 调用点的具名参数名（每个调用点一个列表）。

    ## 为什么必须用词边界而不是 `component + '('` 子串

    两端 router 里各有一个同名的私有包装：

        class _SettingsPage extends ConsumerWidget { ... SettingsPage(...) }
        class _SyncPage      extends ConsumerWidget { ... SyncPage(...) }

    `_SyncPage(` 里含 `SyncPage(` 子串，裸 `index()` 会命中**包装**那个零参数的
    调用点，于是「零参数 == 零参数」被判为一致——**假绿**。实测：修前
    `SyncPage` 报告「一致」，实际桌面端多传 `onOpenDirectory`。

    ## 为什么返回全部而不是第一个

    同一组件在两端可能各构造多次（不同路由 / 不同 wrapper）。只取第一个会
    静默丢掉后面的调用点，覆盖范围随重构缩小而无人察觉。调用方取并集。
    """
    code = blank_strings_and_comments(src)
    pattern = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(component) + r'\(')
    found = []
    for m in pattern.finditer(code):
        start = m.end() - 1  # 指向 '('
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
        found.append(names)
    return found


def declared_params(src, component):
    """从 `component` 的构造函数里取 `this.xxx` 形式的具名参数名。"""
    code = blank_strings_and_comments(src)
    m = re.search(r'(?<![A-Za-z0-9_])class\s+' + re.escape(component) +
                  r'\s+extends\s+StatefulWidget\b', code)
    if m is None:
        raise SystemExit(f'❌ 找不到 `class {component} extends StatefulWidget`')
    i = m.start()
    ctor = re.search(r'(?<![A-Za-z0-9_])const\s+' + re.escape(component) + r'\(',
                     code[i:])
    if ctor is None:
        raise SystemExit(f'❌ 找不到 `const {component}(`')
    k = i + ctor.start()
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
    site_counts = {}
    for end, path in t['sites'].items():
        sites = call_args_all(open(path, encoding='utf-8').read(), comp)
        if not sites:
            print(f'❌ {path}: 找不到 {comp}( 构造点')
            failed = True
            continue
        # 并集：同一组件可能在该端构造多次（不同路由 / wrapper），只取第一个
        # 会静默丢掉后面的调用点。
        args = [a for site in sites for a in site]
        per_end[end] = args
        site_counts[end] = len(sites)

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
        print(f'✅ {comp} 接线一致（{a} {len(per_end[a])} 参数 / '
              f'{site_counts[a]} 处，{b} {len(per_end[b])} 参数 / '
              f'{site_counts[b]} 处；{a} 单端豁免 '
              f'{sorted(t["exempt"][a]) or "无"}，{b} 单端豁免 '
              f'{sorted(t["exempt"][b]) or "无"}）')

if failed:
    sys.exit(1)
PY

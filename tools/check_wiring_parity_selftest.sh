#!/usr/bin/env bash
# `check_wiring_parity.sh` 自身的自测（issue #42）。
#
# ## 为什么守卫需要自己的测试
#
# 守卫的价值全部建立在「它真的在看」之上。issue #42 修的是一个**假绿**：
# 匹配用了 `component + '('` 的裸子串，而两端 router 里各有一个同名私有包装
# （`class _SyncPage extends ConsumerWidget`）。`_SyncPage(` 含 `SyncPage(`
# 子串，`index()` 命中的是包装那个**零参数**的调用点，于是「零参数 ==
# 零参数」被判为一致——守卫报「✅ SyncPage 接线一致」，而桌面端实际多传了
# `onOpenDirectory`。
#
# 一个会假绿的守卫比没有守卫更危险（它给出「已覆盖」的错觉）。故这里用
# **合成输入**逐条钉住解析器的行为——不依赖仓库当前的真实 router。
#
# ## 为什么用合成输入而不是改真 router
#
# 改真 router 再 revert 的做法只能在本地手动跑（且容易忘记 revert）。
# 合成输入是纯字符串，可以在 CI 里稳定复现，且能覆盖「真实代码里没有」的
# 边界（同名包装、多个调用点、嵌套构造）。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v python3 >/dev/null 2>&1; then
  echo "❌ 未找到 python3"
  exit 1
fi

# 从守卫脚本里抽出 python 段（`python3 - <<'PY'` 到 `PY`），只保留解析函数
# 部分——即到 `failed = False` 之前。这样测的是**真身**而不是副本，
# 守卫改了实现这里就会跟着测到（副本会悄悄过期）。
awk "/^import re\$/,/^failed = False\$/" tools/check_wiring_parity.sh | head -n -1 \
  > /tmp/_wiring_parser.py

if [ ! -s /tmp/_wiring_parser.py ]; then
  echo "❌ 未能从 check_wiring_parity.sh 抽出解析器（脚本结构变了？）"
  exit 1
fi

cat >> /tmp/_wiring_parser.py <<'PY'

# ==================== 自测 ====================

failures = []


def check(label, got, want):
    if got != want:
        failures.append(f'{label}\n     期望: {want}\n     实际: {got}')


# ---- 1. 同名私有包装不得被误当成目标调用点 ----
#
# 这是 issue #42 的**原始缺陷**。`_SyncPage(` 在 `SyncPage(` 之前出现，
# 旧实现用裸 index 命中它（零参数）→ 假绿。
wrapper_src = '''
class _SyncPage extends ConsumerWidget {
  const _SyncPage();
  Widget build(BuildContext c, WidgetRef r) {
    return SyncPage(pickDirectory: r.read(p), onOpenDirectory: r.read(d));
  }
}
'''
sites = call_args_all(wrapper_src, 'SyncPage')
check('词边界：应只命中真正的 SyncPage(', sites, [['pickDirectory', 'onOpenDirectory']])

# 旧行为（裸 index）会命中 `_SyncPage(` 并返回 []——显式钉住它不再是那样。
if sites and sites[0] == []:
    failures.append('词边界失效：命中了 `_SyncPage(` 包装（零参数）')

# ---- 2. 同一组件多个调用点取并集 ----
multi_src = '''
Widget a() => SyncPage(pickDirectory: x);
Widget b() => SyncPage(runSync: y, onOpenDirectory: z);
'''
sites = call_args_all(multi_src, 'SyncPage')
check('多调用点：应返回 2 处', len(sites), 2)
merged = sorted({n for s in sites for n in s})
check('多调用点：并集', merged, ['onOpenDirectory', 'pickDirectory', 'runSync'])

# ---- 3. 嵌套构造只取本层参数 ----
#
# `SettingsPage` 的参数值里可能又构造别的组件（真实代码里
# `desktopInfo: DesktopIntegrationInfo(...)` 就是）。嵌套层的键不得混入。
nested_src = '''
Widget f() => SettingsPage(
  loadSettings: a,
  desktopInfo: DesktopIntegrationInfo(visible: true, hotkeyLabel: 'x'),
  onSignOut: b,
);
'''
sites = call_args_all(nested_src, 'SettingsPage')
check('嵌套构造：只取本层', sites, [['loadSettings', 'desktopInfo', 'onSignOut']])

# ---- 4. 字符串与注释里的目标名不得被当成调用点 ----
#
# 守卫文件头部的注释里就写着 `ConversationPage(`；字符串里也可能有。
noise_src = '''
// 这里提到 ConversationPage( 但这是注释
const doc = 'ConversationPage( 在字符串里';
Widget f() => ConversationPage(icon: i);
'''
sites = call_args_all(noise_src, 'ConversationPage')
check('注释/字符串：应只命中 1 处', len(sites), 1)
check('注释/字符串：参数正确', sites[0], ['icon'])

# ---- 5. 值里的逗号不得拆错参数 ----
#
# `reason: 'a, b'` 这类写法在真实代码里很常见；拆错会让参数名带上垃圾。
comma_src = '''
Widget f() => SettingsPage(
  title: 'a, b',
  onOpenSync: () => go(x),
  onSignOut: null,
);
'''
sites = call_args_all(comma_src, 'SettingsPage')
check('值内逗号', sites, [['title', 'onOpenSync', 'onSignOut']])

# ---- 6. 声明参数解析（this.xxx） ----
decl_src = '''
class SyncPage extends StatefulWidget {
  const SyncPage({
    super.key,
    required this.pickDirectory,
    this.onOpenDirectory,
    this.title = 'x',
  });
  final PickSyncDirectory pickDirectory;
  final Future<bool> Function(String)? onOpenDirectory;
  final String title;
}
'''
check('declared_params', sorted(declared_params(decl_src, 'SyncPage')),
      ['onOpenDirectory', 'pickDirectory', 'title'])

# ---- 7. 目标组件在源码中不存在时应返回空（调用方据此报错） ----
check('不存在的组件', call_args_all('void f() {}', 'NoSuchPage'), [])

if failures:
    print('❌ check_wiring_parity 自测失败：')
    for f in failures:
        print('   - ' + f)
    raise SystemExit(1)

print('✅ check_wiring_parity 自测通过（7 组解析器用例）')
PY

python3 /tmp/_wiring_parser.py

#!/usr/bin/env bash
# 守卫：AGENTS.md 里的 Dart 标识符引用是否真实存在（issue #37）。
#
# ## 为什么需要它
#
# `AGENTS.md` 是本仓库**主要协作接口**（AI agent 与人的共同参考）。它引用的
# 函数/字段若不存在，读者会去找一个不存在的东西——而这类漂移**有过实际先例**：
#
# - §6.15 曾引用 `_summarize`（实际是 `searchConversationItems` 内联截取）
#   与 `hasMore`（实际参数名是 `upperHistoryUnloaded`）；
# - 两端 router 的注释曾引用已改名的 `_narrowActions`（实际 `_appBarActions`）。
#
# 改代码时重命名一个函数，不会有人记得回头改 AGENTS.md——除非有机器检查。
#
# ## 只查「高置信度」三类（零误报是硬指标）
#
# 全文 backtick 标识符有 300+ 个，其中大量**合法地**不存在于 `lib/`：
# 服务端 Go 符号（`ReplyProjector`）、webapp 组件名（`SkillPanel`）、
# 环境变量（`ANDROID_HOME`）、SQL 列名（`chat_decisions`）、C++ 符号
# （`fl_view_new`）、README/文档名……无差别地查会淹没在误报里。
#
# 故只查这三类——实测在本仓库**当前基线零误报**：
#
# | 规则 | 理由 | 实测 |
# |---|---|---|
# | `_privateMember`（下划线开头） | 只可能来自本仓库 Dart | 20 候选 / 0 误报 |
# | `foo()`（snake_case 调用） | 只可能来自本仓库 Dart | 4 候选 / 0 误报 |
# | `xxx.dart`（文件名） | 只可能来自本仓库文件 | 22 候选 / 0 误报 |
#
# 私有成员/小写调用**不可能**是 Go 导出符号（Go 导出首字母大写）、也不可能是
# webapp 的 React 组件（PascalCase），故这两类天然无歧义。
#
# ## 另加一条：`tools/` 脚本清单不得漏列（issue #47 第六项）
#
# §3 的 tools/ 树是**读者找脚本的唯一入口**。新增守卫脚本后若忘了补文档，
# 读者根本不知道它存在（`ls tools/` 不会被想起来）。故反向检查：
# 每个非 `_selftest` 的 `tools/*.sh` 都必须在 AGENTS.md 里被 backtick 引用。
#
# ⚠️ 豁免的是 `*_selftest.sh`（每个守卫都配一个，逐个列进树会让树长一倍；
# 树里已用一行注释说明它们的存在）。这是一个**规则**而非白名单，故不会腐化。
#
# ## 查不到怎么办
#
# - 若标识符**确实**不该存在（文档漂移）→ 改文档；
# - 若它来自**别的仓库**（`super_partyb` / `api-gateway`）→ 不要写成
#   `_foo` 这种像本仓库私有成员的形态，或在下方 EXEMPT 里登记并注明来源；
# - 若它是**测试/示例里的**→ 确认路径在扫描范围内（本脚本扫 lib/ 与 test/）。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f AGENTS.md ]; then
  echo "❌ 未找到 AGENTS.md"
  exit 1
fi

python3 - <<'PY'
import glob
import os
import re
import sys

DOC = 'AGENTS.md'

# 显式豁免：确知「不该在本仓库 lib/test 里找到」的引用。
# key 是标识符，value 是理由。新增豁免必须写理由。
EXEMPT = {
    # §6.19 与 §11 把「已修的历史漂移」当作**反例**列出——它们本就不该存在，
    # 引用它们是文档的**意图**（说明「曾引用 X，实际是 Y」）。
    # 若将来又出现同名符号，这两条豁免会让它不被拦——代价可接受（这两个名字
    # 已废弃，重名概率低）。
    '_summarize': '§6.19 历史漂移反例（实际是 searchConversationItems 内联截取）',
    '_narrowActions': '§6.19 历史漂移反例（已改名 _appBarActions）',
}

with open(DOC, encoding='utf-8') as fh:
    doc = fh.read()

# 源码 + 测试 + 工具的文件名集合（给 `.dart` 规则用）。
files = []
for pat in ('packages/*/lib/**/*.dart', 'apps/*/lib/**/*.dart',
            'packages/*/test/**/*.dart', 'apps/*/test/**/*.dart',
            'tools/*'):
    files += glob.glob(pat, recursive=True)
basenames = {os.path.basename(f) for f in files}

# 源码 + 测试的内容（给标识符规则用）。
# 注意也扫 test/：文档会引用测试辅助/用例里的符号。
blob = []
for f in files:
    if f.endswith('.dart'):
        with open(f, encoding='utf-8', errors='ignore') as fh:
            blob.append(fh.read())
blob = '\n'.join(blob)

checks = [
    # (正则, 说明, 判定方式)
    (re.compile(r'`(_[A-Za-z][A-Za-z0-9_]*)`'),
     '私有成员（下划线开头）', 'source'),
    (re.compile(r'`([a-z][a-z0-9_]*\(\))`'),
     'snake_case 调用', 'source'),
    (re.compile(r'`([a-z_]+\.dart)`'),
     'Dart 文件名', 'file'),
]

failed = False
total = 0
for pat, label, mode in checks:
    cands = {m.group(1) for m in pat.finditer(doc)}
    for name in sorted(cands):
        total += 1
        if name in EXEMPT:
            continue
        hit = (name in basenames) if mode == 'file' else (name in blob)
        if not hit:
            print(f'❌ AGENTS.md 引用了不存在的{label}：`{name}`')
            print(f'   要么改文档（若代码已改名/删除），要么加进 '
                  f'check_agents_refs.sh 的 EXEMPT 并注明来源。')
            failed = True

if failed:
    sys.exit(1)

# ── 反向检查：tools/ 脚本清单 ────────────────────────────────────────
#
# 与上面的「文档引用必须存在」方向相反：**脚本必须被文档提到**。
# 见脚本头「另加一条」的说明。
#
# 只查非 selftest 的 .sh（豁免规则而非白名单，见头注）。
script_refs = set(re.findall(r'`(tools/[a-z0-9_]+\.sh)`', doc))
script_names = {os.path.basename(p) for p in script_refs}

missing = []
for path in sorted(glob.glob('tools/*.sh')):
    name = os.path.basename(path)
    if name.endswith('_selftest.sh'):
        continue
    if name not in script_names and name not in doc:
        missing.append(name)

if missing:
    print('❌ 下列 tools/ 脚本没有被 AGENTS.md §3 提到：')
    for name in missing:
        print(f'   - tools/{name}')
    print('   请在 §3 的 tools/ 树里补上（它是读者找脚本的唯一入口）。')
    sys.exit(1)

print(f'✅ AGENTS.md 标识符引用检查通过（{total} 个高置信度引用均存在；'
      f'{len(glob.glob("tools/*.sh"))} 个脚本中非 selftest 者均已列出）')
PY

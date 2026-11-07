#!/usr/bin/env bash
# 守卫：字符串插值里「$identifier(」形态必须报错（issue #62）。
#
# ## 它防的是什么
#
# `'… $_basename(conflictRelPath) …'` 是 Dart 插值的一个**分析器抓不到**的笔误：
# `$identifier` 只取标识符本身，紧跟着的 `(conflictRelPath)` 是字面文本，于是
# 插值出的是**函数对象的 toString**（`Closure: (String) => String from
# Function '_basename': static.(conflictRelPath)`），而不是调用结果。
# `dart analyze`（三项严格模式全开）不报——插值一个函数是合法表达式。
#
# issue #62 里这个 bug 把「发给 agent 的冲突副本路径」变成了一段闭包 toString，
# agent 收到不存在的路径，冲突处理直接失效。同文件 55 行外就有正确写法
# （`${_basename(...)}`），形成「看起来都对」的错觉。
#
# ## 判定规则
#
# 命中 `\$[A-Za-z_][A-Za-z0-9_]*\(` 且**不**是以下情况即报错：
#
# 1. 前一个字符是 `{`（即 `${...(`，正确的表达式插值形式）；
# 2. 该行是注释（`//` / `///` / 块注释续行 `*`）——文档里**描述**这个形态是合法
#    的（本文件和 deliverable_upload_usecase.dart 的注释都在描述它）。
#
# ## 为什么不扫 test/
#
# 测试里偶有「故意写错以复现」的字符串；守卫的价值在**生产代码**（lib/），
# 误报淹没守卫比漏报更糟（见 AGENTS.md §6.24 的教训）。真要扫测试时再加白名单。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 <<'PY'
import pathlib
import re
import sys

BAD = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\(")
COMMENT = re.compile(r"^\s*(//|/\*|\*)")

def is_generated(path: pathlib.Path) -> bool:
    """build_runner 产物必须整份跳过。

    WHY：`$` 在 Dart 里是**合法标识符首字符**，而 drift/freezed 生成的代码大量
    使用它（`$SyncedFilesTable(...)`、`$composableBuilder(column: ...)`）。那不是
    插值，是构造函数/函数调用。179 处误报全部来自 `database.g.dart` 一个文件。
    只按文件名（`.g.dart`）+ 生成标记头判定，不按目录（`lib/` 下就有生成物）。
    """
    if path.name.endswith((".g.dart", ".freezed.dart", ".g.yaml.dart")):
        return True
    head = path.read_text(encoding="utf-8", errors="replace")[:200]
    return "GENERATED CODE" in head.upper() or "is generated code" in head


files = [
    p
    for base in ("packages", "apps")
    for p in pathlib.Path(base).glob("*/lib/**/*.dart")
    if p.is_file() and not is_generated(p)
]
files.sort()

bad = []
checked = 0
for path in files:
    for i, line in enumerate(path.read_text(encoding="utf-8").split("\n")):
        if COMMENT.match(line):
            continue
        for m in BAD.finditer(line):
            checked += 1
            if m.start() > 0 and line[m.start() - 1] == "{":
                continue  # ${...}：正确的表达式插值
            bad.append(f"{path}:{i + 1}: {line.strip()}")

if bad:
    print(
        f"❌ 发现「$identifier(」形态的字符串插值（{len(bad)} 处）——插值的是函数"
        "对象本身，不是调用结果：",
        file=sys.stderr,
    )
    for b in bad:
        print(f"   {b}", file=sys.stderr)
    print(
        "\n请改为表达式插值：'${_basename(x)}'（$identifier 只取标识符，"
        "后面的 (…) 是字面文本，dart analyze 抓不到这类错误，见 issue #62）。",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"✅ 插值形态检查通过（{checked} 处 $…( 均为合法的 ${{…}} 或注释）")
PY

#!/usr/bin/env bash
# 守卫：静默吞异常的 catch 必须留下「为什么静默」的说明（issue #45）。
#
# ## 它防的是什么
#
# `catch (_) {}` 让异常**完全消失**——没有日志、没有提示。issue #40 建好了
# 「导出诊断日志」通道（环形缓冲 + 环境信息 + 脱敏），但它的输入只有显式走
# `SpbLog` 的日志。一个静默 catch 里的异常**永远不会出现在用户导出的报告里**，
# 于是「应用莫名其妙没反应」这种最需要诊断的场景恰好没有任何记录。
#
# ## 判定规则（两类）
#
# 1. **`catch (_)`**：`_` 是「我不关心这个异常」的显式声明。必须满足任一条：
#    - catch 体第一条语句是注释（说明「为什么静默是安全的」）；
#    - catch 体（在它之前）出现 `SpbLog.` 调用。
#
# 2. **`catch (e)` 但 `e` 在体内从未被引用**：同样是静默吞——`e` 只是占位符。
#    规则同 1。
#
# ⚠️ 规则 1 与规则 2 **不是二选一就够**：规则 1 只要求「有人想过为什么」，
# 规则 2 要求「真的留了痕」。两者都允许，因为有些静默确实是安全的（如
# 「连接已断开，无处可写」），而有些需要日志。本脚本防的是**没想过**。
#
# ⚠️ **不要**把规则扩到「`catch (e)` 且 `e` 被引用但没记日志」——那会命中
# 100+ 处「捕获 → 映射成 SpbError 再 rethrow」的正常写法（如
# `on DioException catch (e) { throw mapDioError(e); }`），淹没在误报里，
# 没人会看。见 AGENTS.md §6.24。
#
# ## 为什么用注释而不是白名单
#
# 白名单会随重构腐化（文件改名/移动后条目失效，而没人会回头清理），且新增
# 的静默 catch 需要「记得去加白名单」——那正是本脚本想避免的「靠人记得」。
# 把理由写在原地，改代码的人一定会看到。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 <<'PY'
import pathlib
import re
import sys

CATCH = re.compile(r"catch\s*\(\s*(_|[A-Za-z][A-Za-z0-9_]*)\s*\)\s*\{")
LOG = re.compile(r"SpbLog\.")
COMMENT = re.compile(r"^\s*(//|/\*|\*)")


def catch_body(lines, start, open_col):
    """返回 (body_lines, end_index)。

    从 catch 行的 `{` 开始做花括号配对。字符串/注释里的花括号**不**参与
    配对——本仓库的 catch 体里出现含花括号的字符串字面量是常见情形
    （如 `{'group_id': gid}` 那种 Map 字面量其实是真花括号，要算）。
    """
    depth = 0
    body = []
    for i in range(start, len(lines)):
        line = lines[i]
        text = line[open_col:] if i == start else line
        body.append(text)
        depth += text.count("{") - text.count("}")
        if depth <= 0:
            return body[1:], i
    return body[1:], len(lines) - 1


files = sorted(
    p
    for base in ("packages", "apps")
    for p in pathlib.Path(base).glob("*/lib/**/*.dart")
    if p.is_file()
)

bad = []
checked = 0
for path in files:
    lines = path.read_text(encoding="utf-8").split("\n")
    for i, line in enumerate(lines):
        m = CATCH.search(line)
        if not m:
            continue
        checked += 1
        name = m.group(1)
        body, _ = catch_body(lines, i, m.end() - 1)
        text = "\n".join(body)

        # 体内有日志 → 放行。
        if LOG.search(text):
            continue
        # 体内第一行是注释 → 放行（作者解释过为什么静默）。
        if body and COMMENT.match(body[0]):
            continue
        # 捕获了变量但**从未使用** → 与 `_` 等价，是静默吞。
        if name != "_":
            if re.search(rf"\b{re.escape(name)}\b", text):
                # 变量被用到了（典型：`throw mapXxx(e)` / `SpbLog.warn(... '$e')`）。
                # 这类是「捕获 → 转换」的正常写法，不是静默吞。
                continue
        bad.append(f"{path}:{i + 1}: {line.strip()}")

if bad:
    print(
        f"❌ 发现静默吞异常的 catch（{len(bad)} 处，既无说明注释，也无 SpbLog 调用）：",
        file=sys.stderr,
    )
    for b in bad:
        print(f"   {b}", file=sys.stderr)
    print(
        "\n请在 catch 体里二选一：\n"
        "  • 加注释说明「为什么静默是安全的」（如「连接已断开，无处可写」）；\n"
        "  • 加 SpbLog.debug/warn/error 记录它（见 AGENTS.md §6.24）。",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"✅ 静默 catch 检查通过（{checked} 处 catch 均有说明、日志或使用了异常）")
PY

#!/usr/bin/env bash
# 守卫：AGENTS.md 里**标注了复现命令**的数字不得偏离实测（issue #46）。
#
# ## 它防的是什么
#
# `tools/check_agents_refs.sh` 只查**标识符存在性**（下划线成员 / snake_case
# 调用 / `.dart` 文件名），查不到数字一致性。而 §6.12 的「重新评估条件 2」是
# 「`spb_features` 硬编码字符串 > 1500」——文档里的「当前值」若长期不准，
# 将来判断「是否触发重评估」时会基于**错误基线**。
#
# 实测漂移先例：§6.12 写 808，实际 878；全仓写 782，实际 1569；§11 写 83.4%
# 而 §6.13 写 83.8%（**同一文档两处不一致**）。
#
# ## ⚠️ 为什么是「容差」而不是「精确相等」
#
# issue #46 的原始建议是「失败时只提示『数字过期』而非硬失败」。本守卫**没有**
# 照做，也没有改成精确相等，而是选了中间路线——**容差内放行、超出则硬失败**：
#
# | 方案 | 问题 |
# |---|---|
# | 软失败（只提示） | CI 上**永远不会被看到**——没人翻绿构建的日志。等于没查 |
# | 精确相等 | 这些数字**随实现自然增长**（`spb_features` 从 782→808→878）。每加一句中文文案就红一次，很快会有人删掉标记 |
# | **容差** | 小漂移放行（不打扰正常开发），大漂移拦住（防止文档烂到误导决策） |
#
# 默认容差 **5%**。依据：§6.12 的阈值是 `> 1500` 而当前 878——5% 的漂移
# （约 44 条）远不足以改变「离阈值还有多远」的判断。覆盖率类数字漂移更慢，
# 可用标记的 `tolerance=` 给更小值。
#
# ## 为什么命令在脚本里、而不在文档的标记里
#
# 最初设计是标记内联 `cmd='...'`。但这两条复现命令**自身含单引号**
# （`grep -rhoE "'[^']*[一-龥][^']*'"`），塞进属性就得转义，属性解析会先崩。
# 故改成：**命令单一定义在下方 CHECKS 表**，标记只写 `name=` 与 `value=`。
#
# 这带来一个额外好处：**文档里展示的命令文本必须与脚本里的逐字相同**（本守卫
# 会断言这一点）。于是「文档教用户跑的」与「守卫实际跑的」不可能漂移——
# 否则用户复现出来的数字与守卫的判定会不一致，而那种不一致极难排查。
#
# ## 标记格式
#
# ```
# <!-- number-check: name=spb_features_hardcoded_zh value=878 -->
# <!-- number-check: name=coverage_total value=84.6 tolerance=0.02 -->
# ```
#
# ## 为什么只查这几处
#
# 数字出现在很多语境里（版本号 `3.47.5`、端口 `8081`、行数、测试数……）。
# 无差别地查会把 `flutter-version: '3.47.5'` 这类也当成「过期数字」，淹没在
# 误报里——那就没人会看。故用**显式标记**定位。
#
# ## 为什么没有标记时要报错
#
# 没有标记的守卫会**静默空转**（扫描零处、报「通过」）——那比没有守卫更危险
# （给出「已覆盖」的错觉）。这与 `check_codegen.sh` 的坑 1（根目录空转）同型。
#
# ## 为什么覆盖率总计不在 CHECKS 里
#
# `bash tools/coverage.sh --summary-only` 读的是**已有产物**（`coverage/lcov.info`），
# 而本守卫在 CI 的 quality job 里跑——那时覆盖率步骤还没执行（它在测试之后），
# 产物不存在。要在这里查就得**重跑一遍全部测试**（约 +3 min），而那正是
# `tools/coverage.sh` 在 CI 里单独一步、且注释里写明「不该让它影响门禁反馈速度」
# 的原因。
#
# §6.13 的表已有一条显式免责（「这张表会漂移——用上面的命令重跑，别把这里当
# 权威数字」），且覆盖率是**观测**而非决策基线（与 §6.12 的「> 1500 阈值」不同）
# ——后者的不准会直接导致错误决策，前者只会让人多跑一条命令。故这里不查它。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

python3 <<'PY'
import pathlib
import re
import subprocess
import sys

DOC = pathlib.Path("AGENTS.md")

# name → 复现命令。**单一定义处**：AGENTS.md 里展示的命令必须与此逐字相同
# （去掉连续空白后比较），由本守卫断言。
CHECKS = {
    "spb_features_hardcoded_zh": (
        """cd packages/spb_features && grep -rhoE "'[^']*[一-龥][^']*'" """
        """--include=*.dart lib | wc -l"""
    ),
    "repo_hardcoded_zh": (
        """grep -rhoE "'[^']*[一-龥][^']*'" --include=*.dart """
        """packages/*/lib apps/*/lib | wc -l"""
    ),
}

MARKER = re.compile(
    r"<!--\s*number-check:\s*name=(?P<name>[a-z_]+)\s+value=(?P<value>[0-9.]+)"
    r"(?:\s+tolerance=(?P<tolerance>[0-9.]+))?\s*-->"
)

text = DOC.read_text(encoding="utf-8")
matches = list(MARKER.finditer(text))

if not matches:
    print(
        "❌ AGENTS.md 里没有任何 number-check 标记——守卫会静默空转。\n"
        "   请在标注了复现命令的数字处加：\n"
        "   <!-- number-check: name=... value=123 -->",
        file=sys.stderr,
    )
    sys.exit(1)

DEFAULT_TOLERANCE = 0.05


def normalize(cmd: str) -> str:
    """去掉所有空白，用于「文档展示的命令 == 脚本里的命令」的比较。

    去空白而非逐字比较：文档里为了可读性可能换行（长命令），而换行不改变
    语义。去空白后 `cd x && grep ...` 与 `cd x && grep\n  ...` 视为相同。
    """
    return re.sub(r"\s+", "", cmd)


bad = []
checked = 0
for m in matches:
    name = m.group("name")
    expected = float(m.group("value"))
    tolerance = float(m.group("tolerance") or DEFAULT_TOLERANCE)
    line = text[: m.start()].count("\n") + 1

    if name not in CHECKS:
        bad.append(
            f"AGENTS.md:{line}: 未知的 number-check 名 `{name}`"
            f"（脚本 CHECKS 里没有它——标记写错了，或脚本忘了加）"
        )
        continue

    cmd = CHECKS[name]

    # 1) 文档里必须展示同一条命令（否则用户复现出的数字与守卫的判定不一致）。
    if normalize(cmd) not in normalize(text):
        bad.append(
            f"AGENTS.md:{line}: 文档里找不到与 CHECKS['{name}'] 相同的命令。\n"
            f"    脚本里的命令：{cmd}\n"
            f"    请在文档里逐字展示它（用户要能复现守卫的判定）。"
        )
        continue

    # 2) 实跑命令，比对数字。
    proc = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
    if proc.returncode != 0:
        bad.append(
            f"AGENTS.md:{line}: 复现命令失败（exit {proc.returncode}）\n"
            f"    cmd: {cmd}\n"
            f"    stderr: {proc.stderr.strip()[:200]}"
        )
        continue

    try:
        actual = float(proc.stdout.strip())
    except ValueError:
        bad.append(
            f"AGENTS.md:{line}: 复现命令的输出不是数字："
            f"{proc.stdout.strip()[:80]!r}\n    cmd: {cmd}"
        )
        continue

    checked += 1
    deviation = 0.0 if expected == 0 else abs(actual - expected) / expected
    if deviation > tolerance:
        bad.append(
            f"AGENTS.md:{line}: 文档写 {m.group('value')}，实测 {proc.stdout.strip()}"
            f"（偏差 {deviation * 100:.1f}%，容差 {tolerance * 100:.1f}%）\n"
            f"    cmd: {cmd}"
        )

if bad:
    print("❌ AGENTS.md 里的数字与实测不符（issue #46）：", file=sys.stderr)
    for b in bad:
        print(f"   {b}", file=sys.stderr)
    print(
        "\n请把数字更新为实测值。若该数字已不再需要检查，删掉它的 number-check "
        "标记并说明原因。",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"✅ AGENTS.md 数字检查通过（{checked} 处数字均在容差内）")
PY

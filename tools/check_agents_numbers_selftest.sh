#!/usr/bin/env bash
# `tools/check_agents_numbers.sh` 的自测（issue #46）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫的价值全部建立在「它真的抓得住数字漂移」之上。它的判定涉及四处
# **容易写反**的地方，写错任一个都会得到假绿或假红：
#
#   1. **标记为空**必须报错（否则守卫**静默空转**、报「通过」——比没守卫更危险）；
#   2. **数字大幅漂移**必须报错；
#   3. **数字小幅漂移**（容差内）必须放行（否则每加一句中文文案就红一次，
#      很快会有人删掉标记）；
#   4. **文档展示的命令与脚本里的不一致**必须报错（否则用户复现出的数字与
#      守卫的判定不一致——那种不一致极难排查）。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，且只读 `AGENTS.md`——故把守卫
# 真身复制进 `mktemp -d` 的受控仓库，再在那边造一份 `AGENTS.md`。
#
# ⚠️ 受控 `AGENTS.md` 里**必须包含与脚本 CHECKS 逐字相同的命令**（去空白后），
# 否则会撞上第 4 条判定。故下面直接从脚本里抽出命令，而不是手抄（手抄会随
# 脚本演进而漂移，自测本身就假红）。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_agents_numbers.sh ]; then
  echo "❌ 找不到 tools/check_agents_numbers.sh"
  exit 1
fi

failures=()

note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/packages/spb_features/lib"
cp tools/check_agents_numbers.sh "$repo/tools/"
chmod +x "$repo/tools/check_agents_numbers.sh"

# CHECKS 里的命令会 `cd packages/spb_features` 并 grep 中文串——故受控仓库需要
# 一个**确定条数**的桩。
#
# ⚠️ 条数不能太小：容差是**相对**的（默认 5%），而「±1」在 4 条上是 25%——
# 那会让「容差内放行」的断言（第 3 条）假红，且 `tolerance=0.6`（第 6 条）
# 也无法用 50% 的偏差验证。故造 100 条。
{
  echo '// 桩：100 条含中文的字面量（不含 `ascii`，用于钉住「只数含中文的」）。'
  for i in $(seq 1 100); do
    echo "const s$i = '文案$i';"
  done
  echo "const ascii = 'no-chinese-here';"
} > "$repo/packages/spb_features/lib/stub.dart"
# 中文串 = 100。

# 从守卫脚本里抽出 CHECKS 表里两条命令的真身（用 python 解析，避免手抄漂移）。
cmd_spb=$(python3 - <<'PY'
import re
src = open("tools/check_agents_numbers.sh", encoding="utf-8").read()
m = re.search(r'"spb_features_hardcoded_zh": \(\s*(.*?)\s*\)', src, re.S)
parts = re.findall(r'"""(.*?)"""', m.group(1), re.S)
print("".join(parts))
PY
)
if [ -z "$cmd_spb" ]; then
  echo "❌ 无法从守卫脚本里抽出 spb_features_hardcoded_zh 的命令（自测需同步更新）"
  exit 1
fi

run_guard() {
  (cd "$repo" && bash tools/check_agents_numbers.sh 2>&1)
}

write_doc() {
  # $1 = marker（含 name=/value=/可选 tolerance=），$2 = 是否展示命令（1/0）
  {
    echo "# AGENTS.md（自测桩）"
    echo
    echo '```bash'
    if [ "$2" = "1" ]; then
      echo "$cmd_spb"
    fi
    echo '```'
    echo
    echo "$1"
  } > "$repo/AGENTS.md"
}

# ---------------------------------------------------------------------------
# 1) 无标记 → 必须报错（否则守卫静默空转）
# ---------------------------------------------------------------------------
{
  echo "# AGENTS.md（自测桩，无标记）"
  echo
  echo '```bash'
  echo "$cmd_spb"
  echo '```'
} > "$repo/AGENTS.md"

out=$(run_guard) && {
  note_fail "无标记时守卫未报错（静默空转——比没守卫更危险）"
} || true
case "$out" in
  *"静默空转"*) ;;
  *) note_fail "无标记的报错文案不含「静默空转」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 2) 数字大幅漂移 → 必须报错
# ---------------------------------------------------------------------------
# 取实测值再故意写小一半。
actual=$(cd "$repo" && bash -c "$cmd_spb")
wrong=$((actual / 2))
write_doc "<!-- number-check: name=spb_features_hardcoded_zh value=$wrong -->" 1

out=$(run_guard) && {
  note_fail "数字大幅漂移（写 $wrong，实测 $actual）未被检出"
} || true
case "$out" in
  *"文档写 $wrong，实测 $actual"*) ;;
  *) note_fail "漂移报错未同时给出文档值与实测值：$out" ;;
esac

# ---------------------------------------------------------------------------
# 3) 数字小幅漂移（容差内）→ 必须放行
# ---------------------------------------------------------------------------
near=$((actual + 1))
write_doc "<!-- number-check: name=spb_features_hardcoded_zh value=$near -->" 1

if ! out=$(run_guard); then
  note_fail "容差内的漂移被误报（假红会让标记被删掉）：$out"
fi

# ---------------------------------------------------------------------------
# 4) 文档展示的命令与脚本不一致 → 必须报错
# ---------------------------------------------------------------------------
# 精确值 + 错误的展示命令（把 `--include` 改成 `--exclude`）。
write_doc "<!-- number-check: name=spb_features_hardcoded_zh value=$actual -->" 0

out=$(run_guard) && {
  note_fail "文档未展示命令时守卫未报错（用户无法复现守卫的判定）"
} || true
case "$out" in
  *"找不到与 CHECKS"*) ;;
  *) note_fail "命令不一致的报错文案不含「找不到与 CHECKS」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 5) 未知的 name → 必须报错（标记写错，或脚本忘了加）
# ---------------------------------------------------------------------------
write_doc "<!-- number-check: name=no_such_check value=1 -->" 1

out=$(run_guard) && {
  note_fail "未知 name 未被检出"
} || true
case "$out" in
  *"未知的 number-check 名"*) ;;
  *) note_fail "未知 name 的报错文案不含「未知的 number-check 名」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 6) tolerance= 覆盖默认值 → 必须生效
# ---------------------------------------------------------------------------
# ⚠️ 偏差是相对 **expected**（文档值）而非 actual 算的：
#   deviation = |actual - expected| / expected
# 故「写 70、实测 100」= 42.9%——默认 5% 会拒，显式 60% 应放行。这正是
# 「默认拒、override 后放行」的干净对照（用 actual/2 会得到 100%，两边都拒，
# 分不出 override 到底有没有生效）。
partial=$((actual * 7 / 10))
write_doc \
  "<!-- number-check: name=spb_features_hardcoded_zh value=$partial tolerance=0.6 -->" 1

if ! out=$(run_guard); then
  note_fail "tolerance=0.6 未生效（应放行 42.9% 偏差）：$out"
fi

# 同一个值、不加 tolerance → 必须被默认 5% 拒绝（否则第 6 条断言可能是
# 「本来就不会红」而非「override 生效」）。
write_doc "<!-- number-check: name=spb_features_hardcoded_zh value=$partial -->" 1
out=$(run_guard) && {
  note_fail "42.9% 偏差在默认容差（5%）下未被检出——第 6 条断言失去意义"
} || true

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_agents_numbers 自测通过（6 条断言）"
  exit 0
fi

echo "❌ check_agents_numbers 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

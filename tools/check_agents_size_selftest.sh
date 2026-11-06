#!/usr/bin/env bash
# `tools/check_agents_size.sh` 的自测。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫有两处**极易写成永远通过**的地方：
#
#   1. **体积判定**：`wc -c` 拿到空串（文件不存在 / 命令写错）时，
#      `[ "" -gt 40960 ]` 在某些 shell 下直接报错退出，被 `|| true` 吞掉后
#      就成了「永远绿」；反过来把比较写成 `-lt` 就是「永远红」。
#   2. **索引反向检查**：`README.md` 是索引本身，若忘了豁免它，守卫一上线就
#      假红（然后很快被删掉）；若豁免写成「豁免所有 .md」，则**所有决策文件
#      都不检查**，守卫静默空转。
#
# 故这里五条断言：超限报错、正常放行、漏索引报错、全索引放行、README 豁免。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 tools/ 下再执行**，否则它会在本仓库上跑（而本仓库的 AGENTS.md 是
# 真的、且不超限，测不出任何东西）。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_agents_size.sh ]; then
  echo "❌ 找不到 tools/check_agents_size.sh"
  exit 1
fi

failures=()
note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/docs/design-decisions"
cp tools/check_agents_size.sh "$repo/tools/"
chmod +x "$repo/tools/check_agents_size.sh"

run_guard() {
  (cd "$repo" && AGENTS_SIZE_LIMIT=200 bash tools/check_agents_size.sh 2>&1)
}

# ---------------------------------------------------------------------------
# 1) 体积超限 → 必须报错（并点名上限）
# ---------------------------------------------------------------------------
python3 -c "print('x' * 500)" > "$repo/AGENTS.md"
printf '# 索引\n' > "$repo/docs/design-decisions/README.md"

out=$(run_guard) && {
  note_fail "AGENTS.md 超过上限未被检出（守卫静默空转）"
} || true
case "$out" in
  *"超过上限"*) ;;
  *) note_fail "超限报错未说明「超过上限」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 2) 体积正常 → 必须放行（防止比较方向写反导致永远红）
# ---------------------------------------------------------------------------
printf '# AGENTS.md（自测桩）\n\n短。\n' > "$repo/AGENTS.md"

if ! out=$(run_guard); then
  note_fail "体积正常时被误报（假红会让守卫被删掉）：$out"
fi

# ---------------------------------------------------------------------------
# 3) 有决策文件没进索引 → 必须报错（并点名该文件）
# ---------------------------------------------------------------------------
printf '# 主题\n' > "$repo/docs/design-decisions/chat.md"

out=$(run_guard) && {
  note_fail "未被索引的决策文件未被检出（索引腐化无人发现）"
} || true
case "$out" in
  *"chat.md"*) ;;
  *) note_fail "漏索引报错未点名 chat.md：$out" ;;
esac

# ---------------------------------------------------------------------------
# 4) 全部进索引 → 必须放行
# ---------------------------------------------------------------------------
cat > "$repo/AGENTS.md" <<'MD'
# AGENTS.md（自测桩）

短。

| 主题 | 文件 |
|---|---|
| 对话 | [`chat.md`](docs/design-decisions/chat.md) |
MD

if ! out=$(run_guard); then
  note_fail "决策文件已进索引时被误报：$out"
fi

# ---------------------------------------------------------------------------
# 5) README.md 必须豁免（它是索引本身，不该被要求索引自己）
# ---------------------------------------------------------------------------
printf '# 索引\n\n| 主题 | 文件 |\n|---|---|\n| 对话 | [`chat.md`](docs/design-decisions/chat.md) |\n' \
  > "$repo/docs/design-decisions/README.md"

if ! out=$(run_guard); then
  note_fail "README.md 未被豁免（守卫一上线就假红）：$out"
fi

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_agents_size 自测通过（5 条断言）"
  exit 0
fi

echo "❌ check_agents_size 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

#!/usr/bin/env bash
# `tools/check_agents_refs.sh` 的自测（issue #47）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫有**两个相反方向**的判定，各自有容易写反的地方：
#
#   1. **文档引用的标识符必须存在**（原有，issue #37）；
#   2. **脚本必须被文档提到**（新增，issue #47 第六项）——方向相反，最容易
#      写成同一个集合判定，从而两边都失效。
#
# 尤其第 2 条有个**豁免规则**：`*_selftest.sh` 不要求逐个列进树（每个守卫
# 都配一个，列出来会让树长一倍）。写反豁免（豁免了普通脚本、却要求列
# selftest）会得到：
#
#   - 假绿：所有脚本都不检查 → 守卫静默空转；
#   - 假红：要求列出 18 个脚本 → 守卫一上线就红，很快被删掉。
#
# 故这里四条断言：漏列报错、已列放行、selftest 豁免、引用不存在的标识符报错。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 tools/ 下再执行**，否则它会在本仓库上跑。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_agents_refs.sh ]; then
  echo "❌ 找不到 tools/check_agents_refs.sh"
  exit 1
fi

failures=()

note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/packages/demo/lib/src"
cp tools/check_agents_refs.sh "$repo/tools/"
chmod +x "$repo/tools/check_agents_refs.sh"

# 一个真实的 Dart 符号，供「引用存在」的正例用。
cat > "$repo/packages/demo/lib/src/demo.dart" <<'DART'
class Demo {
  void _privateThing() {}
}
DART

run_guard() {
  (cd "$repo" && bash tools/check_agents_refs.sh 2>&1)
}

# ---------------------------------------------------------------------------
# 1) 漏列脚本 → 必须报错
# ---------------------------------------------------------------------------
cat > "$repo/tools/check_alpha.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$repo/tools/check_beta.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$repo/tools/check_beta_selftest.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

# 文档只提到 alpha，漏了 beta。
cat > "$repo/AGENTS.md" <<'MD'
# AGENTS.md（自测桩）

```bash
bash tools/check_alpha.sh
bash tools/check_agents_refs.sh
```
MD

out=$(run_guard) && {
  note_fail "漏列 tools/check_beta.sh 未被检出（守卫静默空转）"
} || true
case "$out" in
  *check_beta.sh*) ;;
  *) note_fail "漏列报错未点名 check_beta.sh：$out" ;;
esac
# ⚠️ 豁免规则写反的话，这里会连 selftest 一起报——那会让守卫一上线就假红。
case "$out" in
  *check_beta_selftest.sh*)
    note_fail "豁免规则失效：_selftest.sh 被要求列进文档（会让守卫一上线就假红）" ;;
esac

# ---------------------------------------------------------------------------
# 2) 全部列出（且 selftest 豁免）→ 必须放行
# ---------------------------------------------------------------------------
cat > "$repo/AGENTS.md" <<'MD'
# AGENTS.md（自测桩）

```bash
bash tools/check_alpha.sh
bash tools/check_beta.sh
bash tools/check_agents_refs.sh
```

引用一个真实存在的符号：`_privateThing`。
MD

if ! out=$(run_guard); then
  note_fail "脚本全部列出时被误报（假红会让守卫被删掉）：$out"
fi

# ---------------------------------------------------------------------------
# 3) 文档引用了不存在的标识符 → 必须报错（原有方向，防止被新逻辑挤掉）
# ---------------------------------------------------------------------------
cat > "$repo/AGENTS.md" <<'MD'
# AGENTS.md（自测桩）

```bash
bash tools/check_alpha.sh
bash tools/check_beta.sh
```

引用一个**不存在**的符号：`_noSuchMember`。
MD

out=$(run_guard) && {
  note_fail "引用不存在的标识符未被检出（原有判定被新逻辑挤掉）"
} || true
case "$out" in
  *"_noSuchMember"*) ;;
  *) note_fail "不存在的标识符报错未点名 _noSuchMember：$out" ;;
esac

# ---------------------------------------------------------------------------
# 4) 两个方向同时满足 → 必须放行（防止「一边修好、另一边又坏」）
# ---------------------------------------------------------------------------
cat > "$repo/AGENTS.md" <<'MD'
# AGENTS.md（自测桩）

```bash
bash tools/check_alpha.sh
bash tools/check_beta.sh
bash tools/check_agents_refs.sh
```

引用一个真实存在的符号：`_privateThing`。
MD

if ! out=$(run_guard); then
  note_fail "两个方向同时满足时被误报：$out"
fi

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_agents_refs 自测通过（4 条断言）"
  exit 0
fi

echo "❌ check_agents_refs 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

#!/usr/bin/env bash
# `tools/check_type_tokens.sh` 的自测（§6.78）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫的价值全在「它真的抓得住裸字号」之上，而它的判定有三处**容易写反**：
#
#   1. 数字字面量 `fontSize: 12` 必须报错；而 `fontSize: SpbType.metaSize`
#      必须放行（守卫若把 `fontSize:` 整个拦掉，绘制场景就没法写）；
#   2. `labelSmall` 必须报错，但**带理由的豁免注释**必须放行——否则下一次
#      「受 golden 锁定、暂时不能改」的位置会被逼着写白名单；
#   3. **注释里的 `fontSize: 10`** 必须放行（那是解释为什么禁止，不是使用）；
#   4. 规则 3（小字 + 降透明度，#127）的判定边界：跨行 `copyWith` 与局部样式
#      变量必须抓到；边框/背景/图标的 alpha、不透明原色必须放行；
#      豁免注释要带理由、且只能在命中行或前两行生效。
#
# 规则 3 的误报代价尤其高：一旦把「同一文件里既有小字、又有别处的 alpha」
# 当成违规，开发者会直接删掉注释而不是加豁免——守卫就死了。
#
# 外加一条**空转保护**：扫描路径全空时必须硬失败，不能报「通过」——一个会假绿
# 的守卫比没有守卫更危险（给出「已覆盖」的错觉）。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 tools/ 下再执行**，否则它会在本仓库上跑。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_type_tokens.sh ]; then
  echo "❌ 找不到 tools/check_type_tokens.sh"
  exit 1
fi

failures=()
note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/packages/demo/lib/src" "$repo/packages/spb_design/lib/src"
cp tools/check_type_tokens.sh "$repo/tools/"
chmod +x "$repo/tools/check_type_tokens.sh"

src="$repo/packages/demo/lib/src/demo.dart"
ok="$repo/packages/demo/lib/src/ok.dart"

# 空转保护要求至少一处 `SpbType.` 调用，故放一个「必然合格」的文件。
cat > "$ok" <<'DART'
Text build(ThemeData theme) =>
    Text('x', style: SpbType.listMeta(theme.textTheme));
DART

run_guard() { (cd "$repo" && bash tools/check_type_tokens.sh 2>&1); }

# ---------------------------------------------------------------------------
# 1) 数字字号字面量 → 必须报错，并指出行号
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  style: TextStyle(fontSize: 12),
);
DART

out=$(run_guard) && note_fail "fontSize: 12 字面量未被检出（应报错却退出 0）" || true
case "$out" in
  *"字号令牌检查失败"*) ;;
  *) note_fail "fontSize 字面量的报错文案不对：$out" ;;
esac
case "$out" in
  *demo.dart:3*) ;;
  *) note_fail "fontSize 字面量未指出正确行号（期望 demo.dart:3）：$out" ;;
esac

# ---------------------------------------------------------------------------
# 2) `labelSmall` 无豁免 → 必须报错
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  style: theme.textTheme.labelSmall,
);
DART

out=$(run_guard) && note_fail "labelSmall 未被检出（应报错却退出 0）" || true
case "$out" in
  *demo.dart:3*) ;;
  *) note_fail "labelSmall 未指出正确行号（期望 demo.dart:3）：$out" ;;
esac

# ---------------------------------------------------------------------------
# 3) `labelSmall` + 带理由的豁免注释（前一行）→ 必须放行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  // 字号守卫豁免：受 golden 锁定，改动会破坏既有基线。
  style: theme.textTheme.labelSmall,
);
DART

if ! out=$(run_guard); then
  note_fail "带理由的豁免注释被误报：$out"
fi

# ---------------------------------------------------------------------------
# 4) 豁免注释但**没有理由** → 必须报错（光写「豁免」不算想过）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  // 字号守卫豁免：
  style: theme.textTheme.labelSmall,
);
DART

out=$(run_guard) && note_fail "空理由的豁免注释被放行（要求非空理由）" || true

# ---------------------------------------------------------------------------
# 5) `fontSize: SpbType.metaSize` → 必须放行（绘制场景的合法写法）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
TextStyle painter(double size) => TextStyle(fontSize: SpbType.metaSize);
DART

if ! out=$(run_guard); then
  note_fail "fontSize: SpbType.metaSize 被误报（绘制场景会被逼回字面量）：$out"
fi

# ---------------------------------------------------------------------------
# 6) 注释里提到 `fontSize: 10` → 必须放行（解释 ≠ 使用）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
// 这里**不要**写 fontSize: 10——那是全应用最小的字。
Text build(ThemeData theme) =>
    Text('q', style: SpbType.listMeta(theme.textTheme));
DART

if ! out=$(run_guard); then
  note_fail "注释里的 fontSize: 10 被误报：$out"
fi

# ---------------------------------------------------------------------------
# 7) `packages/spb_design/lib` 是令牌所在地 → 必须放行
# ---------------------------------------------------------------------------
cat > "$repo/packages/spb_design/lib/src/type.dart" <<'DART'
TextStyle raw() => const TextStyle(fontSize: 11);
DART

if ! out=$(run_guard); then
  note_fail "spb_design 内的字号定义被误报（令牌必须能定义字号）：$out"
fi

# ---------------------------------------------------------------------------
# 8) 规则 3：跨行 `copyWith` 里的小字降透明度 → 必须报错，行号指向 alpha 那一行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  style: SpbType.listMeta(theme.textTheme)?.copyWith(
    color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
  ),
);
DART

out=$(run_guard) && note_fail "跨行 copyWith 的小字 alpha 未被检出" || true
case "$out" in
  *demo.dart:4*) ;;
  *) note_fail "小字 alpha 未指出正确行号（期望 demo.dart:4）：$out" ;;
esac

# ---------------------------------------------------------------------------
# 9) 规则 3：局部样式变量 → 必须报错
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
TextStyle build(ThemeData theme) {
  final style = theme.textTheme.bodySmall?.copyWith(
    color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.7),
  );
  return style;
}
DART

out=$(run_guard) && note_fail "局部样式变量里的小字 alpha 未被检出" || true

# ---------------------------------------------------------------------------
# 10) 规则 3：不透明原色 → 必须放行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  style: SpbType.listMeta(theme.textTheme)?.copyWith(
    color: theme.colorScheme.onSecondaryContainer,
    fontWeight: FontWeight.w600,
  ),
);
DART

if ! out=$(run_guard); then
  note_fail "不透明原色 + 字重被误报（§6.78 推荐的写法）：$out"
fi

# ---------------------------------------------------------------------------
# 11) 规则 3：非文字 alpha（边框 / 背景 / 图标）→ 必须放行
# ---------------------------------------------------------------------------
# 小字与 alpha 同文件共存，但 alpha 不在小字表达式里——这正是「不能因为
# 同文件出现就判违规」的那一条。
cat > "$src" <<'DART'
Widget build(ThemeData theme) => Container(
  decoration: BoxDecoration(
    color: theme.colorScheme.secondary.withValues(alpha: 0.3),
    border: Border.all(color: theme.colorScheme.outline.withOpacity(0.5)),
  ),
  child: Icon(Icons.info, color: const Color(0x80FFFFFF)),
);

Text meta(ThemeData theme) =>
    Text('q', style: SpbType.listMeta(theme.textTheme));
DART

if ! out=$(run_guard); then
  note_fail "边框/背景/图标的 alpha 被误报：$out"
fi

# ---------------------------------------------------------------------------
# 12) 规则 3：带理由的透明度豁免 → 必须放行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  // 透明度守卫豁免：受 golden 锁定的既有基线，改动会破坏基线图。
  style: SpbType.listMeta(theme.textTheme)?.copyWith(
    color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
  ),
);
DART

if ! out=$(run_guard); then
  note_fail "带理由的透明度豁免被误报：$out"
fi

# ---------------------------------------------------------------------------
# 13) 规则 3：豁免注释但**没有理由** → 必须报错
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  // 透明度守卫豁免：
  style: SpbType.listMeta(theme.textTheme)?.copyWith(
    color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
  ),
);
DART

out=$(run_guard) && note_fail "空理由的透明度豁免被放行" || true

# ---------------------------------------------------------------------------
# 14) 规则 3：豁免注释落在窗口外（前两行之外）→ 必须报错
# ---------------------------------------------------------------------------
# 注释离命中行超过两行 → 豁免不生效（alpha 在第 7 行，注释在第 3 行）。
cat > "$src" <<'DART'
Text build(ThemeData theme) => Text(
  'q',
  // 透明度守卫豁免：离命中行超过两行，不应生效。
  style: SpbType.listMeta(theme.textTheme)?.copyWith(
    fontWeight: FontWeight.w600,
    height: 1.5,
    color: theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
  ),
);
DART

out=$(run_guard) && note_fail "超出两行窗口的豁免注释被误放行" || true

# ---------------------------------------------------------------------------
# 15) 空转：扫描范围没有任何 SpbType 调用 → 必须硬失败
# ---------------------------------------------------------------------------
rm -f "$src" "$ok"
out=$(run_guard) && note_fail "无 SpbType 调用时未触发空转保护（假绿）" || true
case "$out" in
  *"空转"*) ;;
  *) note_fail "空转时的报错文案不对：$out" ;;
esac

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_type_tokens 自测通过（15 条断言）"
  exit 0
fi

echo "❌ check_type_tokens 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

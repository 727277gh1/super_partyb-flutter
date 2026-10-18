#!/usr/bin/env bash
# 守卫：跨包**逐字节相同**的测试辅助文件必须真的逐字节相同。
#
# ## 为什么会有重复文件
#
# Dart 的 import 只能引用包内的 `lib/`（或同包相对路径）。`spb_ui` 与
# `spb_features` 是两个包，测试辅助代码**无法**互相 import——
# `import '../../../../spb_ui/test/support/x.dart'` 会被分析器拒绝
# （跨包的文件相对导入不在 package 的根内）。
#
# 三个选项：
#   1. 建一个 `spb_test_support` 包 —— 为 100 行字体加载器引入一个 workspace
#      成员，且它只能被 dev_dependencies 引用（pub 对 dev-only 包的表达力很差）；
#   2. 把辅助代码放进 `lib/` —— 让测试代码进入生产产物，更糟；
#   3. 重复 + 本守卫。
#
# 选 3。**风险是真实的**：两份 `golden_fonts.dart` 若行为不一致，本机与 CI
# 会装载不同的字体，golden 基线必然有一边失败——而报错信息只会说「像素不匹配」，
# 完全指不到「两份辅助文件漂移了」。
#
# ## 检查范围
#
# 只列**已知的有意重复**，不做全仓扫描：扫描会要求「所有同名文件都相同」，
# 而不同包里有同名但语义不同的文件是正常的（如各包的 `_FakeApi`）。
set -euo pipefail

cd "$(dirname "$0")/.."

# 格式：每组一行，空格分隔的仓库相对路径。第一个是「权威」副本。
#
# ⚠️ 变量名**不能**叫 `GROUPS`——那是 bash 的**特殊变量**（当前用户的组 ID
# 数组，`declare -a GROUPS=([0]="1001" [1]="100")`）。赋值会被静默忽略，
# 循环里拿到的是组 ID 而不是路径（报错信息完全指不到原因）。踩过一次。
SYNC_GROUPS=(
  "packages/spb_ui/test/support/golden_fonts.dart packages/spb_features/test/support/golden_fonts.dart"
)

failed=0
for group in "${SYNC_GROUPS[@]}"; do
  # shellcheck disable=SC2086
  set -- $group
  ref="$1"
  shift

  if [ ! -f "$ref" ]; then
    echo "❌ 权威副本不存在：$ref"
    failed=1
    continue
  fi

  for other in "$@"; do
    if [ ! -f "$other" ]; then
      echo "❌ 缺失：$other（应从 $ref 复制）"
      failed=1
      continue
    fi
    if ! cmp -s "$ref" "$other"; then
      echo "❌ 副本与权威不一致："
      echo "     权威 $ref"
      echo "     副本 $other"
      echo "   修复：cp '$ref' '$other'"
      diff "$ref" "$other" | head -20 | sed 's/^/     /' || true
      failed=1
    fi
  done
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "✅ 测试辅助文件同步检查通过"

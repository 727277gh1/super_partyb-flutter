#!/usr/bin/env bash
# `tools/check_dollar_paren.sh` 的自测（issue #62）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫的判定有三个**容易写反**的地方，写错任一个就是假绿或假红：
#
#   1. `'$_f(x)'`（字符串里的 `$identifier(`）**必须**报错——这正是 issue #62 的
#      笔误形态，`dart analyze` 抓不到；
#   2. `'${f(x)}'` 必须放行——同文件里的正确写法，误报会让守卫被加进忽略列表；
#   3. 生成代码（`*.g.dart`）里的 `$Table(x)` 必须放行——drift/freezed 大量使用
#      `$` 前缀标识符，这不是插值。实测：不排除生成物时会报 179 处误报，全部
#      来自 `database.g.dart`。
#
# 第 3 条尤其容易「为了抓得更狠」而写错：一个假红率高的守卫比没有守卫更糟。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 tools/ 下再执行**，否则它会在本仓库上跑。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_dollar_paren.sh ]; then
  echo "❌ 找不到 tools/check_dollar_paren.sh"
  exit 1
fi

failures=()

note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/packages/demo/lib/src"
cp tools/check_dollar_paren.sh "$repo/tools/"

run_guard() {
  (cd "$repo" && bash tools/check_dollar_paren.sh 2>&1)
}

# 1) 笔误形态：$identifier( —— 必须报错。
cat >"$repo/packages/demo/lib/src/bad.dart" <<'EOF'
String note(String? p) =>
    p == null ? '' : '另有一份副本位于 _conflict/$_basename(p)，请比对。';
EOF
if out=$(run_guard); then
  note_fail '笔误形态 "$_basename(p)" 未被报出（守卫假绿）'
else
  echo '  ✅ 抓到 "$_basename(p)" 形态'
  case "$out" in
  *bad.dart:2*) echo "     （错误行号正确）" ;;
  *) note_fail "报错行号不是 bad.dart:2：$out" ;;
  esac
fi

# 2) 正确写法 ${...} —— 必须放行。
cat >"$repo/packages/demo/lib/src/bad.dart" <<'EOF'
String note(String? p) =>
    p == null ? '' : '另有一份副本位于 _conflict/${_basename(p)}，请比对。';
EOF
if out=$(run_guard); then
  echo "  ✅ 放行 '\${_basename(p)}'"
else
  note_fail "正确写法 \${_basename(p)} 被误报：$out"
fi

# 3) 注释里描述这个形态 —— 必须放行（本仓库多处注释在讲这个 bug）。
cat >"$repo/packages/demo/lib/src/bad.dart" <<'EOF'
/// 反例（**不要这样写**）：`'… $_basename(p) …'` 插值的是函数对象。
// 同上：$_basename(p)
String note(String? p) => '${_basename(p)}';
EOF
if out=$(run_guard); then
  echo "  ✅ 放行注释里的描述"
else
  note_fail "注释里的描述被误报：$out"
fi

# 4) 生成代码里的 $-前缀标识符 —— 必须放行。
cat >"$repo/packages/demo/lib/src/database.g.dart" <<'EOF'
// GENERATED CODE - DO NOT MODIFY BY HAND
class $Table {
  $Table(this.db);
  final Object db;
  void build() => $composableBuilder(column: $Table(this.db), builder: (c) => c);
}
Object $composableBuilder({required Object column, required Object builder}) => builder;
EOF
cat >"$repo/packages/demo/lib/src/bad.dart" <<'EOF'
String note(String p) => '${_basename(p)}';
EOF
if out=$(run_guard); then
  echo "  ✅ 放行生成代码的 \$ 前缀标识符"
else
  note_fail "生成代码被误报（drift 的 \$Table( 等）：$out"
fi

rm -rf "$repo"

if [ ${#failures[@]} -gt 0 ]; then
  echo
  echo "❌ check_dollar_paren selftest 失败："
  for f in "${failures[@]}"; do
    echo "   • $f"
  done
  exit 1
fi

echo "✅ check_dollar_paren selftest 全部通过"

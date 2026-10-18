#!/usr/bin/env bash
# `tools/check_silent_catches.sh` 的自测（issue #45）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫的价值全部建立在「它真的抓得住静默吞异常」之上。它的判定涉及三处
# **容易写反**的地方，写错任一个都会得到假绿或假红：
#
#   1. **`catch (_) {}` 空体**必须报错（这是最该抓的形态，而它最容易因为
#      「没有下一行可看」被漏掉）；
#   2. **`catch (_)` + 注释**必须放行（作者解释过为什么静默是安全的）；
#   3. **`catch (e) { throw mapXxx(e); }`** 必须放行——这是本仓库 100+ 处的
#      正常写法（捕获 → 转成 SpbError → rethrow）。规则若写成「没记日志就报错」
#      会淹没在误报里。
#
# 一个会假绿的守卫比没有守卫更危险（给出「已覆盖」的错觉）；而一个假红率高的
# 守卫会很快被加进忽略列表。故这里三条各钉一条断言。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 tools/ 下再执行**，否则它会在本仓库上跑。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_silent_catches.sh ]; then
  echo "❌ 找不到 tools/check_silent_catches.sh"
  exit 1
fi

failures=()

note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/packages/demo/lib/src"
cp tools/check_silent_catches.sh "$repo/tools/"
chmod +x "$repo/tools/check_silent_catches.sh"

# 守卫扫描 packages/*/lib/**/*.dart 与 apps/*/lib/**/*.dart。
src="$repo/packages/demo/lib/src/demo.dart"

run_guard() {
  (cd "$repo" && bash tools/check_silent_catches.sh 2>&1)
}

# ---------------------------------------------------------------------------
# 1) 空体 `catch (_) {}` → 必须报错
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
void a() {
  try {
    risky();
  } catch (_) {}
}
DART

out=$(run_guard) && {
  note_fail "空体 catch (_) 未被检出（应报错却退出 0）"
} || true
case "$out" in
  *"静默吞异常"*) ;;
  *) note_fail "空体 catch (_) 的报错文案不含「静默吞异常」：$out" ;;
esac
case "$out" in
  *demo.dart:4*) ;;
  *) note_fail "空体 catch (_) 未指出正确行号（期望 demo.dart:4）：$out" ;;
esac

# ---------------------------------------------------------------------------
# 2) `catch (_)` + 说明注释 → 必须放行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
void a() {
  try {
    risky();
  } catch (_) {
    // 连接已断开：无处可写。
  }
}
DART

if ! out=$(run_guard); then
  note_fail "带说明注释的 catch (_) 被误报：$out"
fi

# ---------------------------------------------------------------------------
# 3) `catch (e) { throw mapXxx(e); }` → 必须放行（本仓库 100+ 处的正常写法）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
SpbError wrap(Object e) => SpbError('$e');

void a() {
  try {
    risky();
  } on DioException catch (e) {
    throw wrap(e);
  }
}
DART

if ! out=$(run_guard); then
  note_fail "「捕获 → 转换 → rethrow」被误报（假红会让守卫被加进忽略列表）：$out"
fi

# ---------------------------------------------------------------------------
# 4) `catch (e)` 但 `e` 从未被引用 → 必须报错（e 只是占位符）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
void a() {
  try {
    risky();
  } catch (e) {
    return;
  }
}
DART

out=$(run_guard) && {
  note_fail "catch (e) 但 e 未使用未被检出"
} || true
case "$out" in
  *demo.dart:4*) ;;
  *) note_fail "catch (e) 未使用未指出正确行号：$out" ;;
esac

# ---------------------------------------------------------------------------
# 5) `catch (_)` + 体内 SpbLog → 必须放行
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
void a() {
  try {
    risky();
  } catch (_) {
    SpbLog.debug('吞了');
  }
}
DART

if ! out=$(run_guard); then
  note_fail "带 SpbLog 的 catch (_) 被误报：$out"
fi

# ---------------------------------------------------------------------------
# 6) 多层花括号嵌套：catch 体内的 Map 字面量不得让配对提前结束
#    （若配对写错，`catch (_) {}` 会「看起来」有内容而被漏掉）
# ---------------------------------------------------------------------------
cat > "$src" <<'DART'
void a() {
  try {
    risky();
  } catch (_) {
    if (x) {
      log({'a': 1});
    }
  }
  try {
    risky2();
  } catch (_) {}
}
DART

out=$(run_guard) && {
  note_fail "嵌套花括号后的空体 catch (_) 未被检出"
} || true
case "$out" in
  *demo.dart:11*) ;;
  *) note_fail "嵌套场景未定位到第二个 catch（期望 demo.dart:11）：$out" ;;
esac
# 第一个 catch（体内有嵌套块但没有说明/日志）也应被检出——否则配对写错
# 时「吞掉第一个、只报第二个」会看起来正常。
case "$out" in
  *demo.dart:4*) ;;
  *) note_fail "嵌套场景未定位到第一个 catch（期望 demo.dart:4）：$out" ;;
esac

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_silent_catches 自测通过（6 条断言）"
  exit 0
fi

echo "❌ check_silent_catches 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

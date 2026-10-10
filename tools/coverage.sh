#!/usr/bin/env bash
# 覆盖率采集（issue #25）：逐包跑测试并汇总成一份 lcov + 一张汇总表。
#
# ## 为什么要「逐包」而不是根目录一把梭
#
# 纯 Dart 包（spb_core/models/api/domain）用 `dart test`（无 Flutter 引擎，
# 秒级启动），含 UI 的包必须 `flutter test`。根目录的 `dart test` 不会进
# Flutter 包，`flutter test` 又要求逐包执行——与 ci.yml 的测试步骤同一约束。
#
# ## 两种包要调不同的 `format_coverage`
#
# `dart test --coverage` 产出的**不是** lcov，而是 `coverage/test/*.json`
# （一行一个 VM coverage 记录）。要变成 lcov 必须再跑 `coverage:format_coverage`。
# 而 `flutter test --coverage` **直接**产出 `coverage/lcov.info`。
#
# 这个差异很容易踩：对 `flutter test` 的产物再跑一次 `format_coverage` 会报
# 「in 目录里没有可解析的文件」——因为 lcov.info 不是它的输入格式。
#
# ## 用法
#
#   bash tools/coverage.sh              # 全包
#   bash tools/coverage.sh spb_domain   # 单包（调试用）
#   bash tools/coverage.sh --summary-only  # 不跑测试，只汇总已有产物
#
# `--summary-only` 供 CI 写 job summary 用：避免为了打一张表**再跑一遍全部
# 测试**（CI 里上一步刚跑完，产物就在磁盘上）。
#
# 产物：`coverage/lcov.info`（仓库根，合并全部包）+ 终端汇总表。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "❌ 未找到 flutter（需 Flutter SDK 在 PATH 中，见 AGENTS.md §9）"
  exit 1
fi

SUMMARY_ONLY=false
if [ "${1:-}" = "--summary-only" ]; then
  SUMMARY_ONLY=true
  shift
fi

DART_PKGS=(spb_core spb_models spb_api spb_domain)
FLUTTER_PKGS=(spb_data spb_design spb_ui spb_platform spb_features)
APPS=(spb_desktop spb_mobile)

# 允许只跑指定包（调试用）。
#
# ⚠️ 用 `printf | while read` 过滤时 **`keep` 返回 1 会让整个命令替换非零退出**，
# 在 `set -e` 下直接终止脚本（且报错位置在 `while` 里，看不出是过滤失败）。
# 故改用「先拼字符串、再按空格拆」，无子命令、无退出码。
filter_list() {
  local out=""
  local p w
  for p in $1; do
    for w in "${WANTED[@]}"; do
      if [ "$w" = "$p" ]; then out="$out $p"; break; fi
    done
  done
  echo "$out"
}

if [ "$#" -gt 0 ]; then
  WANTED=("$@")
  DART_PKGS=($(filter_list "${DART_PKGS[*]}"))
  FLUTTER_PKGS=($(filter_list "${FLUTTER_PKGS[*]}"))
  APPS=($(filter_list "${APPS[*]}"))
fi

OUT_DIR="coverage"
# 收集所有分段 lcov，最后合并。
SEGMENTS=()

if [ "$SUMMARY_ONLY" = true ]; then
  # 不跑测试：直接指向各包已存在的 lcov。
  for p in "${DART_PKGS[@]}" "${FLUTTER_PKGS[@]}"; do
    SEGMENTS+=("packages/$p/coverage/lcov.info")
  done
  for a in "${APPS[@]}"; do
    SEGMENTS+=("apps/$a/coverage/lcov.info")
  done
else
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  : > "$OUT_DIR/lcov.info"
fi

run_dart_pkg() {
  local pkg="$1"
  [ -d "packages/$pkg/test" ] || return 0
  echo "=== $pkg (dart test) ==="
  (
    cd "packages/$pkg"
    rm -rf coverage
    dart test --coverage=coverage >/dev/null
    # `--report-on` 用**绝对路径**：format_coverage 把 SF: 写成相对于该路径的
    # 形式，用相对路径会因工作目录不同而产生 `packages/spb_domain/lib/...`
    # 与 `lib/...` 两种前缀，合并时同一文件会被算两次。
    dart run coverage:format_coverage \
      --lcov --in=coverage --out=coverage/lcov.info \
      --report-on="$PWD/lib" >/dev/null
  )
  SEGMENTS+=("packages/$pkg/coverage/lcov.info")
}

run_flutter_pkg() {
  local dir="$1"
  local name
  name="$(basename "$dir")"
  [ -d "$dir/test" ] || return 0
  echo "=== $name (flutter test) ==="
  (cd "$dir" && rm -rf coverage && flutter test --coverage >/dev/null)
  SEGMENTS+=("$dir/coverage/lcov.info")
}

if [ "$SUMMARY_ONLY" = false ]; then
  for p in "${DART_PKGS[@]}"; do run_dart_pkg "$p"; done
  for p in "${FLUTTER_PKGS[@]}"; do run_flutter_pkg "packages/$p"; done
  for a in "${APPS[@]}"; do run_flutter_pkg "apps/$a"; done

  # 合并：lcov 是「每个 SF: 一段」的文本格式，直接拼接即可（lcov 工具链的
  # `lcov -a` 做的是同样的事，但那是外部依赖，这里只拼文本，无额外依赖）。
  for f in "${SEGMENTS[@]}"; do
    [ -f "$f" ] || continue
    cat "$f" >> "$OUT_DIR/lcov.info"
  done
fi

echo ""
echo "=== 汇总（逐包行覆盖率）==="
printf '%-16s %8s %8s %7s\n' 包 已覆盖 总行数 覆盖率
printf '%-16s %8s %8s %7s\n' -- ------ ----- ------

total_lf=0
total_lh=0
for f in "${SEGMENTS[@]}"; do
  [ -f "$f" ] || continue
  # 包名：packages/spb_x/coverage/... 或 apps/spb_y/coverage/...
  pkg="$(echo "$f" | cut -d/ -f2)"
  read -r lh lf < <(awk -F: '
    /^LH:/ { lh += $2 }
    /^LF:/ { lf += $2 }
    END    { printf "%d %d\n", lh, lf }
  ' "$f")
  [ "${lf:-0}" -eq 0 ] && continue
  total_lh=$((total_lh + lh))
  total_lf=$((total_lf + lf))
  printf '%-16s %8d %8d %6.1f%%\n' "$pkg" "$lh" "$lf" \
    "$(awk -v a="$lh" -v b="$lf" 'BEGIN { printf "%.1f", 100*a/b }')"
done

echo ""
if [ "$total_lf" -gt 0 ]; then
  printf '总计 %d/%d = %.1f%%\n' "$total_lh" "$total_lf" \
    "$(awk -v a="$total_lh" -v b="$total_lf" 'BEGIN { printf "%.1f", 100*a/b }')"
fi
if [ "$SUMMARY_ONLY" = false ]; then
  echo "lcov: $OUT_DIR/lcov.info"
  echo ""
  echo "提示：把 $OUT_DIR/lcov.info 交给 codecov / genhtml / VS Code Coverage Gutters 均可。"
fi

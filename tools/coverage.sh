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
# ## 剔除生成代码（issue #38）
#
# `database.g.dart` 一个文件就占 `spb_data` 分母的 79%（1591/2002 行），而它
# **是构建产物**：`dart run build_runner build` 生成，随表/列定义自动变。
#
# ⚠️ 分子 1591 是 lcov 的**可执行行数**（`LF`），不是文件行数（3912）——
# 生成代码里大量是声明与字符串，不计入覆盖率分母。这个比例会随表/列定义
# 漂移，不是常数；分母 2002 = 剔除后 411 + 剔除的 1591。
# 它没有「测试写得好不好」这个维度——覆盖多少完全由「用到了哪些表/列」决定，
# 为它补测试就是 coverage-gaming。
#
# 故汇总与合并时**剔除**下列模式，让数字反映**手写可测代码**的真实覆盖：
# `*.g.dart`（drift / json_serializable）、`*.freezed.dart`、`*.gr.dart`。
#
# 剔除是**可见的**：汇总表下方会打印被剔除了多少行，不是悄悄消失。
# 要看含生成代码的原始数字，用 `COVERAGE_INCLUDE_GENERATED=1`。
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

# 生成代码的模式（`SF:` 行）。用 `\\.` 转义点号，避免 `gXdart` 之类误匹配。
GENERATED_RE='\.(g|freezed|gr)\.dart$'

# 把一份 lcov 过滤后写到 stdout（剔除生成代码）。
#
# lcov 是「一条记录 = SF: 行 + 若干 DA:/LF:/LH: 行 + end_of_record」的文本格式，
# 故按记录过滤：命中模式的 SF: 起直到下一条 SF: 全部丢弃。
#
# `COVERAGE_INCLUDE_GENERATED=1` 时原样输出（用于对比原始数字）。
filter_lcov() {
  if [ "${COVERAGE_INCLUDE_GENERATED:-0}" = "1" ]; then
    cat "$1"
    return
  fi
  awk -v re="$GENERATED_RE" '
    /^SF:/ {
      skip = ($0 ~ re) ? 1 : 0
      if (skip) next
    }
    !skip { print }
  ' "$1"
}

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
    #
    # `--check-ignore` 让 `// coverage:ignore-line` / `ignore-start/end` 生效。
    # ⚠️ 纯 Dart 路径**必须显式加**（`flutter test --coverage` 默认就认，见
    # `database.dart` 的表类标记），否则标记被静默忽略、数字偏高（issue #38）。
    dart run coverage:format_coverage \
      --lcov --in=coverage --out=coverage/lcov.info \
      --report-on="$PWD/lib" --check-ignore >/dev/null
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
  # 拼接前逐份过滤，剔除生成代码（见文件头说明）。
  for f in "${SEGMENTS[@]}"; do
    [ -f "$f" ] || continue
    filter_lcov "$f" >> "$OUT_DIR/lcov.info"
  done
fi

echo ""
echo "=== 汇总（逐包行覆盖率）==="
printf '%-16s %8s %8s %7s\n' 包 已覆盖 总行数 覆盖率
printf '%-16s %8s %8s %7s\n' -- ------ ----- ------

total_lf=0
total_lh=0
total_excluded_lf=0
for f in "${SEGMENTS[@]}"; do
  [ -f "$f" ] || continue
  # 包名：packages/spb_x/coverage/... 或 apps/spb_y/coverage/...
  pkg="$(echo "$f" | cut -d/ -f2)"
  read -r lh lf < <(filter_lcov "$f" | awk -F: '
    /^LH:/ { lh += $2 }
    /^LF:/ { lf += $2 }
    END    { printf "%d %d\n", lh, lf }
  ')
  [ "${lf:-0}" -eq 0 ] && continue
  # 被剔除的生成代码行数（仅统计，用于提示可见性）。
  raw_lf=$(awk -F: '/^LF:/ { lf += $2 } END { printf "%d", lf }' "$f")
  total_excluded_lf=$((total_excluded_lf + raw_lf - lf))
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
if [ "${COVERAGE_INCLUDE_GENERATED:-0}" != "1" ] && [ "$total_excluded_lf" -gt 0 ]; then
  echo "（已剔除生成代码 $total_excluded_lf 行：*.g.dart / *.freezed.dart / *.gr.dart）"
  echo "  含生成代码的原始数字：COVERAGE_INCLUDE_GENERATED=1 bash tools/coverage.sh --summary-only"
fi
if [ "$SUMMARY_ONLY" = false ]; then
  echo "lcov: $OUT_DIR/lcov.info"
  echo ""
  echo "提示：把 $OUT_DIR/lcov.info 交给 codecov / genhtml / VS Code Coverage Gutters 均可。"
fi

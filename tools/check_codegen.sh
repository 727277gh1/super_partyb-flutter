#!/usr/bin/env bash
# 生成物漂移门禁：提交进 git 的 build_runner 产物必须与源文件同步。
#
# ## 为什么需要它（issue #43）
#
# `packages/spb_data/lib/src/database.g.dart`（3900+ 行）是仓库里**唯一提交进
# git 的生成文件**，由 `database.dart` 的 7 个 drift 表定义生成。
#
# 若有人改了表/列定义但忘了重跑 build_runner：
#
#   - `dart analyze --fatal-infos .`     → 全绿
#   - `flutter test`                     → 全绿
#   - 其余 9 个守卫                       → 全绿
#
# 因为 `.g.dart` 是 `part of`，编译器只看得到旧版本里已有的成员——**新增的列
# 在生成代码里不存在，但也没有任何编译错误**。直到运行时第一次查询碰到那一列
# 才炸，而报错指向 drift 内部（`no such column`），指不到「忘了重跑」。
#
# 这与 issue #34（根 `analysis_options.yaml` 从未生效）是**同一类缺陷**：
# 门禁覆盖不到的地方，绿不代表对。
#
# ## 四个必须处理的坑（都实测过；写错任一个都会得到一个假绿或假红的守卫）
#
# ### 坑 1：**不能**在仓库根跑 build_runner
#
# 直觉上 `dart run build_runner build` 在根目录跑一次就覆盖所有包。**实测不是**：
#
#   $ dart run build_runner build          # 根目录
#   Built with build_runner/aot in 0s; wrote 0 outputs.
#
# 根 `pubspec.yaml` 没有 build_runner 依赖、没有 `build.yaml`、没有任何 builder
# 声明；`dart run` 能解析到 workspace 里的可执行文件，但「当前包」是根包，它
# 没有任何输入/输出 → **静默 0 输出**。于是守卫会永远报「✅ 无漂移」——正是
# issue #43 要消灭的那种假绿。
#
# （`--workspace` 能修，但那是 build_runner 2.5+ 的新 flag，且仍要进包目录才稳。
# 本脚本按包执行：从「提交进 git 的生成物路径」反推所属包。）
#
# ### 坑 2：build_runner 的产出**不是** `dart format` 的形态
#
# `build_runner` 写出的 `database.g.dart` 与仓库里提交的**不同**——实测：
#
#   $ cd packages/spb_data && dart run build_runner build
#   $ dart format --output=none --set-exit-if-changed lib/src/database.g.dart
#   Changed lib/src/database.g.dart        ← 生成物未格式化
#
# 差异全部是空白（`({` 后是否换行等），而提交进仓库的那份**是格式化过的**。
# 若守卫直接比对原始产出，会报一个**永远存在**的假漂移（正确状态也红）。
#
# 故比对前对生成物跑一次 `dart format`（只碰生成物；手写文件的格式由
# `check_format.sh` 单独守）。
#
# ### 坑 3：build_runner 有**增量资产图**，比对后必须能重来
#
# `build_runner` 把「已构建状态」存在 `.dart_tool/build/`。它**不看输出文件的
# 当前内容**，只看自己的资产图。
#
# 这带来一个**非幂等陷阱**（本脚本的第一版就踩了，实测复现）：
#
#   1. 守卫跑 build_runner → 生成物被就地改写（含新列）
#   2. 守卫为「不改工作区」把生成物 `cp` 回提交版
#   3. **下一轮**守卫再跑 build_runner → 资产图认为「已是最新」，`wrote 0 outputs`
#      → 生成物仍是旧版 → 与提交版一致 → **报 ✅**
#
# 即同一个坏状态，第一轮报漂移、第二轮报「一致」。修法：比对前**先删掉输出**，
# 让资产图必须重新产出它（实测：删输出后 `wrote 28 outputs`，不删则 `wrote 0`）。
# 见下方 `rm -f "$f"` 处的注释。
#
# ### 坑 4：`diff | head` + `pipefail` = 在还原文件**之前**中止
#
# `set -o pipefail` 下，`diff | head -20` 会在 diff 输出超过 20 行时让 diff 收到
# SIGPIPE 而死，整个脚本以 141 退出——**在把生成物还原回去之前**。实测后果：
# 门禁报失败，却把重新生成的文件留在工作区，下一轮 `git status` 多出一份开发者
# 自己没生成的 diff。
#
# 故先把 diff 输出接进变量（diff 退出码 1 = 有差异，是预期值），再 head。
#
# ## 不修改工作区
#
# 无论是否漂移，脚本结束前都会把每个生成物还原成**运行前的样子**。门禁的职责
# 是「报告」，不是「顺手改文件」——静默重写会让开发者看到一份自己没生成的
# diff，且 `git status` 的脏状态会与真实改动混淆。
set -euo pipefail

cd "$(dirname "$0")/.."

for cmd in dart git diff; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ 未找到 $cmd（需 Flutter/Dart SDK 在 PATH 中）"
    exit 1
  fi
done

# 提交进 git 的生成物。用 git ls-files 而不是 find：只有**被跟踪**的生成物才
# 需要守——`test/**/*.g.dart` 之类被 .gitignore 挡住的产物不参与。
mapfile -t generated < <(
  git ls-files | grep -E '\.(g|freezed|gr)\.dart$' | LC_ALL=C sort
)

if [ "${#generated[@]}" -eq 0 ]; then
  echo "✅ 生成物漂移检查通过（本仓库当前没有提交进 git 的生成文件）"
  exit 0
fi

# 从生成物路径反推所属包目录：`packages/<pkg>/...` 或 `apps/<app>/...`。
# 用「前两段」而非向上找 pubspec.yaml——包目录结构是固定的，而向上找会把
# `apps/x/lib/...` 误判到根包（根包没有 build_runner 依赖，见坑 1）。
declare -A files_of_pkg=()

for f in "${generated[@]}"; do
  case "$f" in
    packages/*/*) pkg="packages/$(echo "$f" | cut -d/ -f2)" ;;
    apps/*/*)     pkg="apps/$(echo "$f" | cut -d/ -f2)" ;;
    *)
      echo "❌ $f: 不在 packages/* 或 apps/* 下，本脚本无法反推所属包"
      exit 1
      ;;
  esac
  if [ ! -f "$pkg/pubspec.yaml" ]; then
    echo "❌ $f: 反推出的包目录 $pkg 下没有 pubspec.yaml"
    exit 1
  fi
  files_of_pkg["$pkg"]="${files_of_pkg[$pkg]:-} $f"
done

echo "检查 ${#generated[@]} 个生成物，涉及 ${#files_of_pkg[@]} 个包："
for pkg in $(echo "${!files_of_pkg[@]}" | tr ' ' '\n' | LC_ALL=C sort); do
  for f in $(echo "${files_of_pkg[$pkg]}" | tr ' ' '\n' | grep . | LC_ALL=C sort); do
    echo "  - $f"
  done
done
echo ""

failed=0
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for pkg in $(echo "${!files_of_pkg[@]}" | tr ' ' '\n' | LC_ALL=C sort); do
  echo "── $pkg ──────────────────────────────────────────────"

  # 备份运行前的样子，供比对与还原。
  for f in ${files_of_pkg[$pkg]}; do
    cp -p "$f" "$tmpdir/$(echo "$f" | tr '/' '_')"
  done

  # ⚠️ 比对前先删输出（见文件头「坑 3」）。不删的话，上一轮守卫还原过的文件
  # 会被资产图当成「已是最新」，build_runner 写出 0 个输出，于是漂移永远检不出。
  for f in ${files_of_pkg[$pkg]}; do
    rm -f "$f"
  done

  # ⚠️ 必须 cd 进包目录（见文件头「坑 1」）。
  #
  # 不加 `--delete-conflicting-outputs`：该 flag 在 build_runner 2.5+ 已被
  # **静默忽略**（`W These options have been removed and were ignored`），
  # 带上它只会让读者以为它在起作用。
  set +e
  build_out=$(cd "$pkg" && dart run build_runner build 2>&1)
  build_status=$?
  set -e
  if [ "$build_status" -ne 0 ]; then
    echo "❌ build_runner 在 $pkg 失败（exit=$build_status）："
    echo "$build_out" | tail -30 | sed 's/^/     /'
    # 生成物已被删除，用备份补回，避免门禁失败还留下一个残缺工作区。
    for f in ${files_of_pkg[$pkg]}; do
      cp -p "$tmpdir/$(echo "$f" | tr '/' '_')" "$f"
    done
    failed=1
    continue
  fi

  # 比对前格式化（见文件头「坑 2」）。
  set +e
  fmt_out=$(dart format ${files_of_pkg[$pkg]} 2>&1)
  fmt_status=$?
  set -e
  if [ "$fmt_status" -ne 0 ]; then
    echo "❌ dart format 失败（exit=$fmt_status）："
    echo "$fmt_out" | tail -10 | sed 's/^/     /'
    for f in ${files_of_pkg[$pkg]}; do
      cp -p "$tmpdir/$(echo "$f" | tr '/' '_')" "$f"
    done
    failed=1
    continue
  fi

  pkg_failed=0
  for f in ${files_of_pkg[$pkg]}; do
    backup="$tmpdir/$(echo "$f" | tr '/' '_')"
    if ! diff -q "$backup" "$f" >/dev/null 2>&1; then
      echo "❌ $f 与源文件不同步（改了源却忘了重跑 build_runner，或改了源却没提交生成物）"
      echo "   实际差异（前 20 行，< 已提交 / > 重新生成）："
      # 见文件头「坑 4」：不能写成 `diff ... | head -20`，也不能写成
      # `d=$(diff ...); echo "$d" | head`——两者在输出超过管道缓冲（64KB）时
      # 都会让 diff 收到 SIGPIPE，配合 `set -o pipefail` 使整个脚本以 141 退出
      # **在还原文件之前**。实测：2 万行输入下两种写法都是 EXIT=141。
      #
      # 落到临时文件再 head 就没有写入端可被杀死。diff 的退出码 1（有差异）
      # 是预期值，用 `|| true` 吃掉；真正的失败（2）也会因为 -q 已经判过而
      # 不会走到这里。
      diff "$backup" "$f" >"$tmpdir/diff.txt" || true
      head -20 "$tmpdir/diff.txt" | sed 's/^/     /'
      pkg_failed=1
      failed=1
    fi
    # 无论是否漂移都还原：门禁只报告，不改工作区。
    cp -p "$backup" "$f"
  done

  if [ "$pkg_failed" -eq 0 ]; then
    echo "✅ 生成物与源文件一致"
  fi
  echo ""
done

if [ "$failed" -ne 0 ]; then
  echo "❌ 生成物漂移检查失败。修复："
  echo ""
  for pkg in $(echo "${!files_of_pkg[@]}" | tr ' ' '\n' | LC_ALL=C sort); do
    echo "   (cd $pkg && dart run build_runner build) && dart format ${files_of_pkg[$pkg]}"
  done
  echo ""
  echo "   （或 melos run gen —— 它已指向包目录；见 melos.yaml）"
  echo "   然后把生成物一起提交。"
  exit 1
fi

echo "✅ 生成物漂移检查通过（${#generated[@]} 个文件与源文件一致）"

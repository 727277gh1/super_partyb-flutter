#!/usr/bin/env bash
# `tools/check_codegen.sh` 的自测（issue #43）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫的价值全部建立在「它真的重跑了生成器并比对」之上。而它涉及四个
# **反直觉**的坑（都实测复现过），写错任一个都会得到：
#
#   - **假绿**（坑 1 空转 / 坑 3 非幂等）——守卫报「✅」而漂移仍在；
#   - **假红**（坑 2 未格式化）——正确状态也报漂移，很快被加进忽略列表；
#   - **留下脏工作区**（坑 4 SIGPIPE 提前中止）——门禁失败还把文件改了。
#
# 一个会假绿的守卫比没有守卫更危险（它给出「已覆盖」的错觉）。故这里把四个坑
# 各自钉成一条**可自动重跑**的断言，不需要手动改 `database.dart`。
#
# ## 测法：用一个临时的、受控的「仓库」
#
# 直接改真仓库的 `database.dart` 再 revert 只能在本地手动跑，且容易忘记
# revert（本轮开发中真的踩到过）。故这里在 `mktemp -d` 里造一个**最小仓库**：
# 一个包、一个源文件、一个生成物，用 `git init` 让它可被 `git ls-files` 看见，
# 再用**桩命令**替换 `dart`（脚本只依赖 `dart run build_runner build` 与
# `dart format` 两种调用），从而在毫秒级、无 Flutter SDK 依赖的条件下逐条
# 验证守卫的行为。
#
# 桩 `dart` 的行为由环境变量控制，使「生成物与源是否同步」可任意摆布。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_codegen.sh ]; then
  echo "❌ 找不到 tools/check_codegen.sh"
  exit 1
fi

# ⚠️ 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把它复制进受控仓库的
# tools/ 下再执行**——否则它会在本仓库上跑（实测踩到：临时仓库里建好了文件，
# 守卫却去检查真的 `packages/spb_data`）。这里用 `cp` 的是**真身**，不是副本
# 逻辑，守卫改了实现自测跟着变。

failures=()

note_fail() { failures+=("$1"); }

# ---------------------------------------------------------------------------
# 搭一个受控的最小仓库
# ---------------------------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/packages/pkg/lib/src" "$repo/packages/pkg" "$repo/bin" "$repo/tools"
cp tools/check_codegen.sh "$repo/tools/check_codegen.sh"
GUARD="$repo/tools/check_codegen.sh"

cat > "$repo/packages/pkg/pubspec.yaml" <<'EOF'
name: pkg
EOF

# 源文件（手写）。守卫**不比对**它，只是让包目录结构成立。
cat > "$repo/packages/pkg/lib/src/thing.dart" <<'EOF'
class Thing {}
EOF

# 生成物（提交进 git）。内容 = 桩 dart 将要写出的「期望值」。
GEN="$repo/packages/pkg/lib/src/thing.g.dart"

git -C "$repo" init -q
git -C "$repo" config user.email t@t
git -C "$repo" config user.name t

# ---------------------------------------------------------------------------
# 桩 dart：只实现守卫用到的两种调用
#
#   1. `dart run build_runner build`  —— 把 $STUB_BUILD_OUTPUT 写进生成物
#   2. `dart format <paths...>`       —— 无操作（本测试的漂移不靠空白）
#
# 这样「生成物」完全由测试摆布：STUB_BUILD_OUTPUT 与已提交内容相同 → 无漂移；
# 不同 → 有漂移。
# ---------------------------------------------------------------------------
cat > "$repo/bin/dart" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  run)
    # 守卫在包目录里跑 `dart run build_runner build`；工作目录即包目录。
    if [ "${STUB_BUILD_FAIL:-0}" = "1" ]; then
      echo "stub build failed" >&2
      exit 3
    fi
    # ⚠️ **必须模拟 build_runner 的增量资产图**，否则用例 3（非幂等）是空转。
    #
    # 真实 build_runner 看的是自己 `.dart_tool/build/` 里的资产图，**不是输出
    # 文件的当前内容**：若它认为该输出已是最新，就写 `wrote 0 outputs` 且**不碰
    # 文件**。本桩据此建模——输出文件已存在 → 0 输出；不存在 → 才写出。
    #
    # 这正是「守卫为不改工作区而把生成物 cp 回去」会毒化下一轮的原因：第二轮
    # 看到输出存在 → 0 输出 → 生成物仍是旧版 → 与提交版一致 → 假绿。
    # 守卫用「比对前先 rm 输出」破解它；去掉那句，用例 3 必须失败。
    if [ -e lib/src/thing.g.dart ]; then
      echo "Built with build_runner/aot in 0s; wrote 0 outputs."
    else
      printf '%s' "${STUB_BUILD_OUTPUT:-}" > lib/src/thing.g.dart
      echo "Built with build_runner/aot in 0s; wrote 1 output."
    fi
    ;;
  format)
    # 真实 build_runner 产出未格式化；本测试的漂移不涉及空白，
    # 故 format 为无操作（若守卫忘了调 format，本测试不会察觉——
    # 那条由「坑 2」的独立断言覆盖）。
    exit 0
    ;;
  *)
    echo "stub dart: unexpected args: $*" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$repo/bin/dart"

# 已提交的生成物内容。
COMMITTED='GENERATED_V1'

write_committed() {
  printf '%s' "$COMMITTED" > "$GEN"
  git -C "$repo" add -A
  # `--allow-empty`：本函数会被调用多次（用例间重置状态），内容相同时无需再建
  # 一个空提交，但也不能因为「没东西可提交」而让 set -e 中止测试。
  git -C "$repo" commit -qm "init" --allow-empty
}

# 在受控仓库里跑守卫。$1 = 桩 build 的输出（默认与已提交一致）。
run_guard() {
  local build_output="${1:-$COMMITTED}"
  local build_fail="${2:-0}"
  (
    cd "$repo"
    PATH="$repo/bin:$PATH" \
      STUB_BUILD_OUTPUT="$build_output" \
      STUB_BUILD_FAIL="$build_fail" \
      bash "$GUARD"
  )
}

# ---------------------------------------------------------------------------
# 用例 1：干净状态必须通过，且**不改工作区**
# ---------------------------------------------------------------------------
write_committed
set +e
out=$(run_guard "$COMMITTED" 2>&1); status=$?
set -e
if [ "$status" -ne 0 ]; then
  note_fail "干净状态应通过，实际 exit=$status：$out"
fi
if ! git -C "$repo" diff --quiet; then
  note_fail "干净状态跑完守卫后工作区变脏：$(git -C "$repo" status --short)"
fi
if ! grep -q "生成物漂移检查通过" <<<"$out"; then
  note_fail "干净状态未打印通过：$out"
fi

# ---------------------------------------------------------------------------
# 用例 2（坑 1）：生成物与源不同 → 必须失败
#
# 这条同时验证「守卫真的重跑了生成器」：若它退化成在根目录跑（0 输出），
# 或退化成只做文件哈希比对，都会漏掉这个差异。
# ---------------------------------------------------------------------------
set +e
out=$(run_guard 'GENERATED_V2' 2>&1); status=$?
set -e
if [ "$status" -eq 0 ]; then
  note_fail "生成物与源不同步时必须失败，实际通过：$out"
fi
if ! grep -q "不同步" <<<"$out"; then
  note_fail "失败信息未指出不同步：$out"
fi

# ---------------------------------------------------------------------------
# 用例 3（坑 3，**核心**）：非幂等陷阱
#
# 守卫跑完会把生成物还原（用例 1/2 已验证）。于是**同一坏状态连跑两次**：
#
#   - 正确实现：两次都失败（每轮都重新产出 V2 并与 V1 比对）；
#   - 有坑的实现：第一轮失败（产出 V2、还原 V1），第二轮**通过**——因为
#     增量资产图认为「已是最新」而写出 0 个输出，生成物仍是 V1。
#
# 这正是本守卫第一版实测到的行为，必须钉住。
# ---------------------------------------------------------------------------
# ⚠️ 每轮跑之前先 `git checkout` 回到提交态：若守卫有坑（SIGPIPE 提前退出、
# 不还原），上一轮会留下脏文件，使**后续用例全部失真**——实测踩到：把守卫改回
# `diff | head` 后，是「非幂等」和「未还原」两条先炸，而用例 5 自己的断言因为
# 状态已被污染而不再触发，报错指向了错误的原因。故每轮从已知干净态开始。
reset_tree() { git -C "$repo" checkout -q -- . 2>/dev/null || true; }

reset_tree
set +e
run_guard 'GENERATED_V2' >/dev/null 2>&1; first=$?
reset_tree
run_guard 'GENERATED_V2' >/dev/null 2>&1; second=$?
set -e
if [ "$first" -eq 0 ]; then
  note_fail "非幂等用例：第一轮应失败，实际通过"
fi
if [ "$second" -eq 0 ]; then
  note_fail "非幂等用例：第二轮应仍失败，实际通过（守卫非幂等 → 假绿）"
fi

# ---------------------------------------------------------------------------
# 用例 4：失败后必须还原工作区（不能留下自己生成的 diff）
# ---------------------------------------------------------------------------
reset_tree
set +e
run_guard 'GENERATED_V2' >/dev/null 2>&1
set -e
if ! git -C "$repo" diff --quiet; then
  note_fail "漂移失败后工作区未还原：$(git -C "$repo" status --short)"
fi

# ---------------------------------------------------------------------------
# 用例 5（坑 4）：大 diff 不得因 SIGPIPE 提前中止而跳过还原
#
# 守卫用 `head -20` 截断差异展示。若写成 `diff | head -20`（或
# `d=$(diff); echo "$d" | head`），在 diff 输出**既超过 20 行、又超过管道缓冲
# （64KB）**时，head 读够 20 行就退出，diff 继续写却被 EPIPE 打断，配合
# `set -o pipefail` 使脚本以 141 退出——**在还原文件之前**。
#
# ⚠️ 两个条件缺一不可，第一版用例只满足「超过 64KB」而**只有 5 行**（单个超长
# 行），head 会把它们全读完正常退出，于是 SIGPIPE 根本不会发生——用例空转，
# 把守卫改回 `diff | head` 仍然「通过」。故这里构造**两万行**且总长 ~1MB 的差异。
# ---------------------------------------------------------------------------
big_committed=$(python3 -c "print('\n'.join('OLD%d' % i for i in range(20000)))")
big_output=$(python3 -c "print('\n'.join('NEW%d' % i for i in range(20000)))")
printf '%s' "$big_committed" > "$GEN"
git -C "$repo" add -A
git -C "$repo" commit -qm "big" --allow-empty

reset_tree
set +e
out=$(run_guard "$big_output" 2>&1); status=$?
set -e
if [ "$status" -eq 141 ]; then
  note_fail "大 diff 下脚本因 SIGPIPE 中止（exit=141），会在还原前退出"
fi
if [ "$status" -eq 0 ]; then
  note_fail "大 diff 下应报漂移，实际通过"
fi
if ! git -C "$repo" diff --quiet; then
  note_fail "大 diff 失败后工作区未还原：$(git -C "$repo" status --short)"
fi
write_committed

# ---------------------------------------------------------------------------
# 用例 6：build_runner 失败时必须报错、还原，且不能把生成物留在「已删除」态
# ---------------------------------------------------------------------------
write_committed
set +e
out=$(run_guard "$COMMITTED" 1 2>&1); status=$?
set -e
if [ "$status" -eq 0 ]; then
  note_fail "build_runner 失败时守卫应失败，实际通过：$out"
fi
if [ ! -s "$GEN" ]; then
  note_fail "build_runner 失败后生成物丢失（守卫删了输出却没补回）"
fi
if ! git -C "$repo" diff --quiet; then
  note_fail "build_runner 失败后工作区未还原：$(git -C "$repo" status --short)"
fi

# ---------------------------------------------------------------------------
# 用例 7（坑 2）：比对前必须调用 `dart format`
#
# 真实 build_runner 的产出未格式化，而仓库里提交的是格式化过的——不调 format
# 会得到**永远存在的假漂移**。这里用「记录调用」的桩来验证守卫确实调了它。
# ---------------------------------------------------------------------------
cat > "$repo/bin/dart" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  run)
    if [ -e lib/src/thing.g.dart ]; then
      echo "wrote 0 outputs."
    else
      printf '%s' "${STUB_BUILD_OUTPUT:-}" > lib/src/thing.g.dart
      echo "wrote 1 output."
    fi
    ;;
  format)
    echo "format" >> "${STUB_FORMAT_LOG:?}"
    exit 0
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$repo/bin/dart"
write_committed
: > "$work/format.log"
set +e
(
  cd "$repo"
  PATH="$repo/bin:$PATH" \
    STUB_BUILD_OUTPUT="$COMMITTED" \
    STUB_FORMAT_LOG="$work/format.log" \
    bash "$GUARD" >/dev/null 2>&1
)
set -e
if [ ! -s "$work/format.log" ]; then
  note_fail "守卫在比对前未调用 dart format（坑 2：会得到永远存在的假漂移）"
fi

# ---------------------------------------------------------------------------
# 用例 8：守卫必须按包执行（坑 1），即**在包目录里**调 build_runner
#
# 桩记录自己的 pwd；若守卫在仓库根跑，pwd 会是仓库根——而根包没有
# build_runner 依赖，真实环境下就是 0 输出的空转。
# ---------------------------------------------------------------------------
cat > "$repo/bin/dart" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  run)
    pwd >> "${STUB_PWD_LOG:?}"
    if [ -e lib/src/thing.g.dart ]; then
      echo "wrote 0 outputs."
    else
      printf '%s' "${STUB_BUILD_OUTPUT:-}" > lib/src/thing.g.dart
      echo "wrote 1 output."
    fi
    ;;
  format) exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$repo/bin/dart"
write_committed
: > "$work/pwd.log"
set +e
(
  cd "$repo"
  PATH="$repo/bin:$PATH" \
    STUB_BUILD_OUTPUT="$COMMITTED" \
    STUB_PWD_LOG="$work/pwd.log" \
    bash "$GUARD" >/dev/null 2>&1
)
set -e
expected_pwd=$(cd "$repo/packages/pkg" && pwd)
actual_pwd=$(head -1 "$work/pwd.log")
if [ "$actual_pwd" != "$expected_pwd" ]; then
  note_fail "守卫未在包目录里跑 build_runner（坑 1：根目录是静默空转）"$'\n'"     期望 pwd: $expected_pwd"$'\n'"     实际 pwd: $actual_pwd"
fi

# ---------------------------------------------------------------------------
if [ "${#failures[@]}" -ne 0 ]; then
  echo "❌ check_codegen 自测失败："
  for f in "${failures[@]}"; do
    echo "   - $f"
  done
  exit 1
fi

echo "✅ check_codegen 自测通过（8 组用例：干净通过 / 检出漂移 / 幂等 / 还原 / 大 diff / 构建失败 / 调 format / 在包目录执行）"

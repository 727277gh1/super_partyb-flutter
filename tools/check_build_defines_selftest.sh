#!/usr/bin/env bash
# 自测：`tools/check_build_defines.sh`（构建参数守卫）。
#
# ## 为什么需要「守卫的守卫」
#
# 这个守卫要抓的是「CI 产物用 127.0.0.1 默认地址」——它已经真实发生过一次
# （2026-10，用户报「远程计算机拒绝网络连接」），而 analyze / 3400+ 用例 /
# 三平台构建当时**全是绿的**。守卫自己若写错，会回到那个状态且更糟：给出
# 「已覆盖」的错觉（同 §6.17 的 `check_wiring_parity` 假绿教训）。
#
# ## 钉住的三处相反方向的判定
#
# | 用例 | 写错方向 | 后果 |
# |---|---|---|
# | 无 define 的 job 必须报错 | 漏报 | 缺陷复发 |
# | 有 define 的 job 必须放行 | 误报 | 守卫被加进忽略列表，等于没有 |
# | 二进制残留必须报错 | 漏报 | 静态检查通过、产物仍连本机 |
# | 二进制干净必须放行 | 误报 | 同上 |
# | 没有任何构建 job 必须报错 | 空转 | workflow 重构后守卫静默失效 |
#
# ⚠️ **造临时仓库而不是改真仓库**：直接改 `ci.yml` 再 revert 只能在本地手动跑，
# 且容易忘 revert。故在 `mktemp -d` 里造最小仓库，把真守卫**逐字节复制**过去
# 执行——不是副本实现，守卫改了自测跟着变。
#
# ## 为什么二进制用例要造真的「字符串含默认地址」的文件
#
# `strings -a` 对任意字节序列都有输出。用一个文本文件写进 `127.0.0.1:8000`
# 就能可靠地命中——不需要真编译 Flutter 产物（那要几分钟，不可能进自测）。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
GUARD="$REPO/tools/check_build_defines.sh"

[ -f "$GUARD" ] || { echo "❌ 未找到 $GUARD"; exit 1; }

pass=0
fail=0
tmpdirs=()
cleanup() {
  # ⚠️ 不能写成 `for d in "${tmpdirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done`：
  # 空数组时 `${tmpdirs[@]:-}` 展开成一个空串，`[ -n "" ]` 失败 → 循环体
  # 最后一条命令返回 1 → **函数返回 1** → EXIT trap 把整个脚本的退出码改成 1。
  # 实测：所有断言都通过、最后一行打印「自测通过」，退出码却是 1。
  for d in ${tmpdirs[@]+"${tmpdirs[@]}"}; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT

# 造一个最小仓库：只有 tools/ 与 .github/workflows/。
new_repo() {
  local d
  d=$(mktemp -d)
  tmpdirs+=("$d")
  mkdir -p "$d/tools" "$d/.github/workflows"
  cp "$GUARD" "$d/tools/check_build_defines.sh"
  chmod +x "$d/tools/check_build_defines.sh"
  printf '%s' "$d"
}

# run_guard <repo> -> 设置 rc / out
run_guard() {
  set +e
  out=$(cd "$1" && bash tools/check_build_defines.sh 2>&1)
  rc=$?
  set -e
}

expect() {
  local desc="$1" want="$2"
  if [ "$rc" -eq "$want" ]; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc（期望 exit $want，实际 $rc）"
    echo "$out" | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

expect_out() {
  local desc="$1" needle="$2"
  if printf '%s' "$out" | grep -q -- "$needle"; then
    echo "  ✅ $desc"
    pass=$((pass + 1))
  else
    echo "  ❌ $desc（输出里没有「$needle」）"
    echo "$out" | sed 's/^/       /'
    fail=$((fail + 1))
  fi
}

echo '── 用例 1：job 没传 define 必须报错 ──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-windows:
    runs-on: windows-2022
    steps:
      - run: flutter build windows --release
YAML
run_guard "$r"
expect '检出未传 define' 1
expect_out '指出缺哪个 define' 'SPB_API_BASE_URL'
expect_out '点名具体 job' 'build-windows'

echo '── 用例 2：job 传了 define 必须放行 ──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-windows:
    runs-on: windows-2022
    steps:
      - run: |
          args=(--dart-define=SPB_API_BASE_URL=$API)
          flutter build windows --release "${args[@]}"
YAML
run_guard "$r"
expect '放行已传 define 的 job' 0

echo '── 用例 3：define 只在**另一个 job** 里，仍必须报错 ──'
# 这是最容易写错的一处：若守卫按「整个文件」grep 而不是按 job 切块，
# 就会因为别的 job 传了而放行——而那正是「配置 job 传了、构建 job 没传」
# 的真实形态（release.yml 的 config job 与 build job 是分开的）。
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  config:
    runs-on: ubuntu-24.04
    steps:
      - run: echo "--dart-define=SPB_API_BASE_URL=x" >> "$GITHUB_OUTPUT"
  build-windows:
    runs-on: windows-2022
    steps:
      - run: flutter build windows --release
YAML
run_guard "$r"
expect '按 job 切块，不因别的 job 而放行' 1
expect_out '点名的是构建 job' 'build-windows'

echo '── 用例 4：完全没有 release 构建 → 必须报错（防空转）──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  quality:
    runs-on: ubuntu-24.04
    steps:
      - run: dart analyze
YAML
run_guard "$r"
expect '无构建 job 时报错而非静默通过' 1
expect_out '说明是空转' '空转'

echo '── 用例 5：debug 构建不受约束（只查 --release）──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: flutter build linux
YAML
run_guard "$r"
expect 'debug 构建不算（无 --release）→ 空转报错' 1

echo '── 用例 6：二进制残留默认地址必须报错 ──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-linux:
    runs-on: ubuntu-24.04
    steps:
      - run: flutter build linux --release --dart-define=SPB_API_BASE_URL=x
YAML
mkdir -p "$r/apps/spb_desktop/build/linux/x64/release/bundle/lib"
printf 'junk http://127.0.0.1:8000 junk' \
  > "$r/apps/spb_desktop/build/linux/x64/release/bundle/lib/libapp.so"
run_guard "$r"
expect '静态通过但二进制残留 → 报错' 1
expect_out '指出是哪个文件' 'libapp.so'

echo '── 用例 7：二进制干净必须放行 ──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-linux:
    runs-on: ubuntu-24.04
    steps:
      - run: flutter build linux --release --dart-define=SPB_API_BASE_URL=x
YAML
mkdir -p "$r/apps/spb_desktop/build/linux/x64/release/bundle/lib"
printf 'junk https://example.test/pba junk' \
  > "$r/apps/spb_desktop/build/linux/x64/release/bundle/lib/libapp.so"
run_guard "$r"
expect '静态+二进制均通过' 0

echo '── 用例 8：本机无产物时只做静态检查，不报错 ──'
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-linux:
    runs-on: ubuntu-24.04
    steps:
      - run: flutter build linux --release --dart-define=SPB_API_BASE_URL=x
YAML
run_guard "$r"
expect '无产物不报错' 0
expect_out '说明跳过了二进制检查' '跳过'

echo '── 用例 9：多行 run 里的续行写法也能识别 ──'
# 真实 workflow 里 build 命令常带 `set -euo pipefail` 与前置 cd，
# 正则若要求行首匹配会漏掉它们。
r=$(new_repo)
cat > "$r/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  build-android:
    runs-on: ubuntu-24.04
    steps:
      - run: |
          set -euo pipefail
          cd apps/spb_mobile
          flutter build apk --release
YAML
run_guard "$r"
expect '带前置命令的构建仍被检出' 1
expect_out '点名 build-android' 'build-android'

echo
if [ "$fail" -gt 0 ]; then
  echo "❌ check_build_defines 自测失败（$pass 通过 / $fail 失败）"
  exit 1
fi
echo "✅ check_build_defines 自测通过（$pass 条断言）"

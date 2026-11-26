#!/usr/bin/env bash
# `tools/check_workflow_steps.sh` 的自测（issue #47）。
#
# ## 为什么守卫需要自己的测试
#
# 这条守卫守的是一个**真实发生过**的缺陷（release.yml 里 `- uses:` 被写进
# 注释行，整个 step 消失，打 tag 时必定失败）。它的价值在于「下次还会不会
# 被抓住」，而这依赖两处容易写反的判定：
#
#   1. **注释里的 step 标记**必须报错（这是缺陷的**形态**，也是唯一不依赖
#      PyYAML 的检查）；
#   2. **`checkout` 的 `with` 白名单**必须拦「属于别的 step 的键」——但
#      **不能**拦合法的 `fetch-depth` / `fetch-tags`（issue #47 给 release
#      notes 加 `git log` 后 checkout 确实需要它们；若白名单写死成「不许有
#      with」，守卫会对着正确配置假红，很快被删）。
#
# 故这里钉住：注释形态报错、合法 with 放行、错挂 with 报错。
#
# ## 测法：受控的最小仓库
#
# 守卫用 `cd "$(dirname "$0")/.."` 定位仓库根，故**必须把守卫真身复制进受控
# 仓库的 `.github/workflows/` 同级再执行**，否则它会在本仓库上跑。
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f tools/check_workflow_steps.sh ]; then
  echo "❌ 找不到 tools/check_workflow_steps.sh"
  exit 1
fi

failures=()

note_fail() { failures+=("$1"); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/tools" "$repo/.github/workflows"
cp tools/check_workflow_steps.sh "$repo/tools/"
chmod +x "$repo/tools/check_workflow_steps.sh"

run_guard() {
  (cd "$repo" && bash tools/check_workflow_steps.sh 2>&1)
}

# 一个「干净」的 release.yml 骨架：checkout（带合法的 fetch 组）+ download-artifact。
write_clean() {
  cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: release
on: { push: { tags: ['v*'] } }
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          fetch-tags: true
      - uses: actions/download-artifact@v4
        with:
          merge-multiple: true
      - name: Create release
        run: echo ok
YAML
}

# ---------------------------------------------------------------------------
# 1) 注释里的 step 标记 → 必须报错（真实缺陷的形态）
# ---------------------------------------------------------------------------
write_clean
# 把 download-artifact 那个 step 折进注释行。
python3 - "$repo/.github/workflows/release.yml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace(
    "      - uses: actions/download-artifact@v4",
    "      # 合并产物 - uses: actions/download-artifact@v4",
)
p.write_text(s)
PY

out=$(run_guard) && {
  note_fail "注释吞掉 step 标记未被检出（真实缺陷形态漏检）"
} || true
case "$out" in
  *"step 标记落在注释里"*) ;;
  *) note_fail "报错文案不含「step 标记落在注释里」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 2) 干净的 workflow → 必须放行（尤其是 checkout 带 fetch-depth/fetch-tags）
# ---------------------------------------------------------------------------
write_clean
if ! out=$(run_guard); then
  note_fail "合法的 checkout with（fetch-depth/fetch-tags）被误报——守卫会假红被删：$out"
fi

# ---------------------------------------------------------------------------
# 3) 别的 step 的 with 错挂到 checkout → 必须报错
# ---------------------------------------------------------------------------
write_clean
python3 - "$repo/.github/workflows/release.yml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
# 模拟「download-artifact step 被吞掉，它的 with 挂到了 checkout 上」。
s = s.replace(
    """          fetch-tags: true
      - uses: actions/download-artifact@v4
        with:
          merge-multiple: true""",
    """          fetch-tags: true
          merge-multiple: true""",
)
p.write_text(s)
PY

out=$(run_guard) && {
  note_fail "checkout 挂着别的 step 的 with（merge-multiple）未被检出"
} || true
case "$out" in
  *"意外键"*) ;;
  *) note_fail "错挂 with 的报错文案不含「意外键」：$out" ;;
esac

# ---------------------------------------------------------------------------
# 4) release job 缺 download-artifact → 必须报错
# ---------------------------------------------------------------------------
cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: release
on: { push: { tags: ['v*'] } }
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
YAML

out=$(run_guard) && {
  note_fail "release job 缺 download-artifact 未被检出（gh release create 必失败）"
} || true
case "$out" in
  *"download-artifact"*) ;;
  *) note_fail "缺 download-artifact 的报错未点名它：$out" ;;
esac

# ---------------------------------------------------------------------------
# 5) 残缺 step（既无 name 也无 uses）→ 必须报错
# ---------------------------------------------------------------------------
cat > "$repo/.github/workflows/release.yml" <<'YAML'
name: release
on: { push: { tags: ['v*'] } }
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
      - run: echo orphan
YAML

out=$(run_guard) && {
  note_fail "残缺 step（无 name/uses）未被检出"
} || true
case "$out" in
  *"既无 name 也无 uses"*) ;;
  *) note_fail "残缺 step 的报错文案不含「既无 name 也无 uses」：$out" ;;
esac

# ---------------------------------------------------------------------------
echo
if [ ${#failures[@]} -eq 0 ]; then
  echo "✅ check_workflow_steps 自测通过（5 条断言）"
  exit 0
fi

echo "❌ check_workflow_steps 自测失败（${#failures[@]} 条）：" >&2
for f in "${failures[@]}"; do
  echo "   $f" >&2
done
exit 1

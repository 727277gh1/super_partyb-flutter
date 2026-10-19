#!/usr/bin/env bash
# 把当前 HEAD 导出成「单提交干净仓库」并推送到 GitHub（squash 方案）。
#
# ## 为什么是 squash 而不是 `git push` 原历史
#
# Gitea 上的历史含生产部署标识（域名 / IP / 目录）。把它们从**历史**里清掉需要
# 重写所有提交哈希（`tools/scrub-history.sh`），且重写后 Gitea 与 GitHub 两边
# 历史都会变——而 Gitea 是权威源，不该为了一次镜像而改写。
#
# squash 方案只导出「恰好 HEAD 这一棵树」，用一条新提交承载：GitHub 上看到的是
# 干净的现状，Gitea 保留完整历史与 blame。
#
# ## ⚠️ 代价（务必知晓）
#
# - **提交历史全部丢失**：GitHub 上永远只有一条提交，`git blame` / `git log -p`
#   / `release.yml` 的「由 git log 生成发布说明」都退化为单条。
# - **两边无共同祖先**：GitHub 那份是孤立仓库。**绝不要**把 Gitea 合并进来或
#   反向拉取——会产生「两个无关联历史的合并」，冲突极难收拾。
# - **每次同步都是 force-push**：GitHub 上的历史每次被整体替换。若有人在那边
#   开了 PR 或基于它工作，会被打断（这也是它只适合「只读镜像」的原因）。
#
# ## 为什么本脚本里没有任何真实值
#
# 与 `tools/scrub-history.sh` 同一取向：本脚本会入库、会被公开。若把
# 「真实值 → 占位符」的映射（或真实值的任何片段）写进脚本，同步本身就
# 成了泄露渠道。故真实值与规则**全部**来自仓库外的映射文件，脚本里只出现
# 变量名与文件名。
#
# ## 用法
#
#   # 准备（仓库外，含真实值，绝不入库，chmod 600）
#   export SPB_OS_MAP="$HOME/.config/spb-flutter/opensource-map.env"
#   export SPB_OS_EXTRA_RULES="$HOME/.config/spb-flutter/extra-rules.txt"
#   export SPB_GITHUB_REMOTE="git@github.com:<owner>/<repo>.git"
#
#   bash tools/sync-to-github.sh --dry-run   # 预演：只报告会改多少处
#   bash tools/sync-to-github.sh             # 执行（会 force-push）
#   bash tools/sync-to-github.sh --verify    # 只校验当前树是否已干净
#
# ## 它会做什么
#
#   1. `git archive HEAD` 导出当前树（不含 .git / 未跟踪 / 构建产物）
#   2. 按映射规则逐条替换**文本文件**里的真实值（二进制跳过）
#   3. 校验：任一真实值仍残留则中止（不推送）
#   4. `git init` + 单条提交 + force-push 到 `$SPB_GITHUB_REMOTE`
#
# ## 跳过二进制是有意的
#
# 本仓库有 44 个 golden 基线 PNG，是**逐字节比对**的。用 `perl -i` 之类的
# 文本工具处理它们会损坏文件，且 `.gitattributes` 里已把它们标为 binary。
# 故一律用 `grep -I`（跳过二进制）筛出待改文件。
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$PWD

MAP="${SPB_OS_MAP:-$HOME/.config/spb-flutter/opensource-map.env}"
EXTRA_RULES="${SPB_OS_EXTRA_RULES:-$HOME/.config/spb-flutter/extra-rules.txt}"
REMOTE="${SPB_GITHUB_REMOTE:-}"
BRANCH="${SPB_GITHUB_BRANCH:-main}"
COMMIT_MSG="${SPB_SYNC_COMMIT_MSG:-chore: import super_partyb-flutter (Flutter 客户端)}"

MODE="run"
case "${1:-}" in
  --dry-run) MODE="dry-run" ;;
  --verify) MODE="verify" ;;
  run | "") MODE="run" ;;
  -h | --help)
    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "❌ 未知参数：$1（可用：--dry-run / --verify / --help）" >&2
    exit 2
    ;;
esac

# 与 scrub-history.sh 保持同一份变量名清单。脚本只认这些**名字**，
# 值一律来自映射文件。
REAL_VARS=(
  SPB_REAL_HOST_ALT
  SPB_REAL_HOST
  SPB_REAL_API_HOST
  SPB_REAL_IP
  SPB_REAL_OIDC_CLIENT_ID
  SPB_REAL_EMAIL
  SPB_REAL_EMAIL_ALT
  SPB_REAL_SSH_HOST
  SPB_REAL_DEPLOY_SCRIPT
  SPB_REAL_IDP_DIR
  SPB_REAL_APP_DIR
)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

rules="$work/rules.txt"
: > "$rules"

# ── 载入映射 ──────────────────────────────────────────────────────────
load_map() {
  [ -f "$MAP" ] || {
    echo "❌ 找不到映射文件：$MAP" >&2
    echo "   该文件含真实值，必须放在仓库外。格式见 scrub-history.sh 头部。" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  set -a; . "$MAP"; set +a
}

# 生成 `真实值==>占位符` 规则（真实值不打印）。
build_rules() {
  local n=0
  for var in "${REAL_VARS[@]}"; do
    # 分开写：`local a=... b=${!a}` 不成立（右值先求值，a 尚未定义）。
    local real="${!var:-}"
    local ph_var="${var}_PLACEHOLDER"
    local ph="${!ph_var:-}"
    [ -n "$real" ] && [ -n "$ph" ] || continue
    printf '%s==>%s\n' "$real" "$ph" >> "$rules"
    n=$((n + 1))
  done

  # 额外规则：映射表装不下的形态（如「主机名嵌在一整条 SSH URL 里」）。
  # 同样放在仓库外——它含「待清理目标」本身。
  local extra=0
  if [ -f "$EXTRA_RULES" ]; then
    while IFS= read -r line; do
      case "$line" in '' | '#'*) continue ;; esac
      case "$line" in *'==>'*) ;; *) continue ;; esac
      printf '%s\n' "$line" >> "$rules"
      extra=$((extra + 1))
    done < "$EXTRA_RULES"
  fi

  echo "  规则：$n 条来自映射 + $extra 条来自额外规则 = $((n + extra)) 条"
}

# ── 应用规则到一棵树 ──────────────────────────────────────────────────
# $1 = 目标目录。只改**文本**文件；二进制一律跳过。
apply_rules() {
  local dir=$1
  local changed_files=0 changed_hits=0

  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    local real="${rule%%==>*}"
    local ph="${rule#*==>}"
    [ -n "$real" ] || continue

    # grep -I 跳过二进制；-l 只列文件名；-F 字面匹配（域名里的点号不解释）。
    local files
    files=$(cd "$dir" && grep -rlIF -- "$real" . 2>/dev/null || true)
    [ -n "$files" ] || continue

    local hits
    hits=$(cd "$dir" && grep -roIF -- "$real" . 2>/dev/null | wc -l)
    changed_hits=$((changed_hits + hits))

    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # 用 \Q...\E 做字面量替换，避免值里的正则元字符被解释。
      REAL="$real" PH="$ph" perl -i -pe \
        's/\Q$ENV{REAL}\E/$ENV{PH}/g' "$dir/${f#./}"
      changed_files=$((changed_files + 1))
    done <<< "$files"
  done < "$rules"

  echo "  替换：$changed_hits 处，涉及 $changed_files 个文件"
}

# ── 校验：任一真实值仍残留 ────────────────────────────────────────────
# $1 = 目标目录。返回 0 = 干净，1 = 有残留。
verify_clean() {
  local dir=$1
  local bad=0 total=0
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    local real="${rule%%==>*}"
    [ -n "$real" ] || continue
    total=$((total + 1))
    local n
    n=$(cd "$dir" && grep -rlIF -- "$real" . 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      echo "  ❌ 残留（$n 个文件）：${real:0:3}…（值已掩码）" >&2
      bad=$((bad + 1))
    fi
  done < "$rules"
  [ "$bad" -eq 0 ] && echo "  ✅ $total 条规则全部无残留"
  return $([ "$bad" -eq 0 ] && echo 0 || echo 1)
}

# ── --verify：只校验当前工作区 ────────────────────────────────────────
if [ "$MODE" = "verify" ]; then
  echo "▶ 校验当前工作区（$REPO_ROOT）"
  load_map
  build_rules
  verify_clean "$REPO_ROOT"
  exit $?
fi

# ── 前置检查 ──────────────────────────────────────────────────────────
echo "▶ 前置检查"
if [ -n "$(git status --porcelain)" ]; then
  echo "  ⚠️  工作区有未提交改动——它们**不会**进入导出（只导出 HEAD）。" >&2
  echo "     如需包含，先提交。" >&2
fi
load_map
build_rules

# ── 导出 ──────────────────────────────────────────────────────────────
src="$work/tree"
mkdir -p "$src"
git archive HEAD | tar -x -C "$src"
echo "▶ 已导出 HEAD 树：$(find "$src" -type f | wc -l) 个文件"

# ── 应用规则 ──────────────────────────────────────────────────────────
echo "▶ 应用脱敏规则"
apply_rules "$src"

# ── 校验 ──────────────────────────────────────────────────────────────
echo "▶ 校验"
if ! verify_clean "$src"; then
  echo "❌ 导出树仍有真实值残留，**不推送**。" >&2
  echo "   请在额外规则文件里补齐对应形态：$EXTRA_RULES" >&2
  exit 1
fi

if [ "$MODE" = "dry-run" ]; then
  echo
  echo "✅ 预演完成（未推送）。执行推送请去掉 --dry-run。"
  echo "   目标：${REMOTE:-<SPB_GITHUB_REMOTE 未设置>}"
  exit 0
fi

# ── 推送 ──────────────────────────────────────────────────────────────
[ -n "$REMOTE" ] || {
  echo "❌ 未设置 SPB_GITHUB_REMOTE（如 git@github.com:<owner>/<repo>.git）" >&2
  exit 1
}

echo "▶ 建立单提交仓库"
cd "$src"
git init -q -b "$BRANCH"
git add -A
# 沿用主仓库的身份，避免在公开仓库里出现意外的作者信息。
git -c user.name="$(git -C "$REPO_ROOT" config user.name)" \
  -c user.email="$(git -C "$REPO_ROOT" config user.email)" \
  commit -q -m "$COMMIT_MSG"
echo "  提交：$(git log --oneline)"
echo "  文件：$(git ls-files | wc -l)"

git remote add github "$REMOTE"
echo "▶ 推送（force，历史每次整体替换）→ $REMOTE"
git push -f -u github "$BRANCH" 2>&1 | tail -4

echo
echo "✅ 已同步。注意：这是**孤立历史**，绝不要把它与 Gitea 合并。"

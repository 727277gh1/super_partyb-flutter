#!/usr/bin/env bash
# 把历史中的真实部署标识替换为占位符（开源前一次性执行）。
#
# ## 为什么需要它
#
# 把工作区里的域名/IP 换成占位符**只影响新提交**。git 历史里旧提交的
# blob 仍然含真实值，公开推送后会永久可查、且会被搜索引擎与代码索引
# 抓取。要真正清理必须重写历史。
#
# ## 为什么本脚本里没有任何真实值
#
# 本脚本会入库、会被公开。若把「真实值 → 占位符」的映射（或真实值的
# 任何片段，如某个域名的前缀、某个内部目录名）写进脚本，清理本身就
# 成了泄露渠道——把待清理的目标集中在一处并公开。
#
# 因此本脚本**完全值无关**：真实值与占位符都从仓库外的本地映射文件读，
# 校验也直接用那份映射逐项比对。脚本里只出现变量名。
#
# ## 用法
#
#   # 1) 准备映射（仓库外，含真实值，绝不入库，chmod 600）
#   export SPB_OS_MAP="$HOME/.config/spb-flutter/opensource-map.env"
#   export SPB_OS_MAILMAP="$HOME/.config/spb-flutter/mailmap"
#
#   # 2) 先备份（重写不可逆）
#   git clone --mirror . ~/backups/super_partyb-flutter-premirror.git
#
#   # 3) 预演：只报告会改多少处，不写历史
#   bash tools/scrub-history.sh --dry-run
#
#   # 4) 执行
#   bash tools/scrub-history.sh
#
#   # 5) 校验
#   bash tools/scrub-history.sh --verify
#
# ## 映射文件格式
#
# 每行 `VAR='值'`，可由 shell source。成对出现：
#
#   SPB_REAL_HOST='<真实主域名>'
#   SPB_REAL_HOST_PLACEHOLDER='app.example.com'
#   ...
#
# 变量名须与下方 REAL_VARS 列表一致。脚本按 `$VAR` → `${VAR}_PLACEHOLDER`
# 配对。
#
# ## 它会改什么
#
# - 所有 blob 内容（--replace-text）
# - 所有提交/标签信息（--replace-message）
# - 作者/提交者/标签者姓名邮箱（--mailmap，可选）
#
# 不改提交的**结构**（数量、拓扑、时间戳不变），也不改文件路径
# （本仓库未把域名写进文件名）。
#
# ## ⚠️ 副作用
#
# 重写会改变**所有**提交哈希：其它克隆会分叉，需 force-push 才能同步。
# git-filter-repo 默认移除 `origin` 远端（防误推），事后需自行加回。
set -euo pipefail

cd "$(dirname "$0")/.."

MAP="${SPB_OS_MAP:-$HOME/.config/spb-flutter/opensource-map.env}"
MAILMAP="${SPB_OS_MAILMAP:-$HOME/.config/spb-flutter/mailmap}"
# 额外替换规则（`查找==>替换`，与 --replace-text 同格式）。
# 用于映射表装不下的形态（如内部工作流编号、内部术语）。
# 同样放在仓库外——它含「待清理目标」本身。
EXTRA_RULES="${SPB_OS_EXTRA_RULES:-$HOME/.config/spb-flutter/extra-rules.txt}"

# 真实值变量名列表。脚本只认这些**名字**，值一律来自映射文件。
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

MODE="${1:-run}"

# ── 载入映射 ──────────────────────────────────────────────────────────
load_map() {
  [ -f "$MAP" ] || {
    echo "❌ 找不到映射文件：$MAP"
    echo "   该文件含真实值，必须放在仓库外。格式见本脚本头部说明。"
    exit 1
  }
  # set -a 让 source 进来的变量自动导出，便于子进程/后续引用。
  # shellcheck disable=SC1090
  set -a; . "$MAP"; set +a
}

# 按 `$VAR` → `${VAR}_PLACEHOLDER` 生成 `真实值==>占位符` 规则，
# 再追加 EXTRA_RULES 里的额外规则。真实值不打印。
write_rules() {
  local out=$1
  : > "$out"
  local n=0 skipped=0
  for var in "${REAL_VARS[@]}"; do
    # 分开写：`local a=... b=${!a}` 不成立——bash 会先把同一 local
    # 语句里所有右值求完再赋值，此时 a 尚未定义，间接展开报错。
    local real="${!var:-}"
    local ph_var="${var}_PLACEHOLDER"
    local ph="${!ph_var:-}"
    if [ -z "$real" ] || [ -z "$ph" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    # 字面量替换（不加 regex: 前缀）：域名里的点号应当按字面匹配。
    printf '%s==>%s\n' "$real" "$ph" >> "$out"
    n=$((n + 1))
  done

  local extra=0
  if [ -f "$EXTRA_RULES" ]; then
    while IFS= read -r line; do
      # 跳过注释与空行；只接受含 `==>` 的行。
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *'==>'*) ;; *) continue ;; esac
      printf '%s\n' "$line" >> "$out"
      extra=$((extra + 1))
    done < "$EXTRA_RULES"
  fi

  echo "$n $skipped $extra"
}

# ── --verify：逐项检查真实值是否仍出现在历史/工作区/提交元数据 ────────
if [ "$MODE" = "--verify" ]; then
  load_map
  echo "=== 校验：历史 + 工作区 是否仍有真实标识 ==="
  fail=0
  for var in "${REAL_VARS[@]}"; do
    real="${!var:-}"
    [ -n "$real" ] || continue
    # -F 固定字符串：真实值含 `.` `/` 等正则元字符，必须按字面找。
    n=$(git log --all -p 2>/dev/null | grep -acF -- "$real" || true)
    if [ "$n" -ne 0 ]; then
      printf '  ❌ %-28s %s 处\n' "$var" "$n"
      fail=1
    else
      printf '  ✅ %-28s 0\n' "$var"
    fi
  done

  # 作者/提交者邮箱不在 diff 里，单独查提交元数据。
  for var in SPB_REAL_EMAIL SPB_REAL_EMAIL_ALT; do
    real="${!var:-}"
    [ -n "$real" ] || continue
    n=$(git log --all --format='%an <%ae>%n%cn <%ce>' | grep -cF -- "$real" || true)
    if [ "$n" -ne 0 ]; then
      printf '  ❌ %-28s %s 处（提交元数据）\n' "$var" "$n"
      fail=1
    else
      printf '  ✅ %-28s 0\n' "$var"
    fi
  done

  # 额外规则的「查找」侧也应归零，否则等于没清干净。
  if [ -f "$EXTRA_RULES" ]; then
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *'==>'*) ;; *) continue ;; esac
      lhs="${line%%==>*}"
      [ -n "$lhs" ] || continue
      n=$(git log --all -p 2>/dev/null | grep -acF -- "$lhs" || true)
      if [ "$n" -ne 0 ]; then
        printf '  ❌ %-28s %s 处\n' "(额外规则)" "$n"
        fail=1
      else
        printf '  ✅ %-28s 0\n' "(额外规则)"
      fi
    done < "$EXTRA_RULES"
  fi

  if [ "$fail" -eq 0 ]; then
    echo "✅ 未发现真实标识"
  else
    echo "❌ 仍有残留（检查映射是否覆盖全部形态）"
    exit 1
  fi
  exit 0
fi

# ── 前置检查 ──────────────────────────────────────────────────────────
command -v git-filter-repo >/dev/null 2>&1 || {
  echo "❌ 未找到 git-filter-repo"
  echo "   安装：pipx install git-filter-repo（或 apt install git-filter-repo）"
  exit 1
}

load_map

if [ -n "$(git status --porcelain)" ]; then
  echo "❌ 工作区不干净，先提交或 stash（重写历史时脏工作区会丢改动）"
  git status --short
  exit 1
fi

TMP_RULES=$(mktemp -d)
trap 'rm -rf "$TMP_RULES"' EXIT
CONTENT_RULES="$TMP_RULES/content.txt"
MSG_RULES="$TMP_RULES/msg.txt"

read -r n_rules n_skipped n_extra <<<"$(write_rules "$CONTENT_RULES")"
cp "$CONTENT_RULES" "$MSG_RULES"

echo "映射文件：$MAP"
echo "生成 $n_rules 条映射规则 + $n_extra 条额外规则（${n_skipped} 项未配置，已跳过；值不打印）"
echo

# ── 预演：报告命中量，不写历史 ────────────────────────────────────────
if [ "$MODE" = "--dry-run" ]; then
  echo "=== 预演（不修改历史）==="
  total=0
  while IFS= read -r rule; do
    real="${rule%%==>*}"
    [ -n "$real" ] || continue
    n=$(git log --all -p 2>/dev/null | grep -acF -- "$real" || true)
    total=$((total + n))
  done < "$CONTENT_RULES"
  echo "历史中将被替换的行数合计：$total"
  echo "（作者邮箱需 --mailmap，另行重写）"
  exit 0
fi

# ── 执行重写 ──────────────────────────────────────────────────────────
ARGS=(--force --replace-text "$CONTENT_RULES" --replace-message "$MSG_RULES")
if [ -f "$MAILMAP" ]; then
  ARGS+=(--mailmap "$MAILMAP")
  echo "将一并重写作者/提交者邮箱（$MAILMAP）"
else
  echo "⚠️  未找到 mailmap（$MAILMAP），作者邮箱将保留原样"
fi

git filter-repo "${ARGS[@]}"

echo
echo "=== 重写完成，自动校验 ==="
bash "$0" --verify

echo
echo "后续："
echo "  git remote add origin <私有仓库 URL>"
echo "  git remote add github <公开仓库 URL>"
echo "  git push -u github main"

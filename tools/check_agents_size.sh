#!/usr/bin/env bash
# 守卫：`AGENTS.md` 的体积上限 + docs/design-decisions/README.md 的索引完整性。
#
# ## 它防的是什么
#
# `AGENTS.md` 不是 wiki，是**提示词**：pi / Claude Code 每次请求都把它**全文**
# 拼进 system prompt（`resource-loader.js` → `system-prompt.js`，无任何截断）。
# 也就是说它的体积直接等于上下文预算。
#
# 2026-11 的实测代价（不是假想）：
#
# - `AGENTS.md` 长到 **522 KB**（约 159k tokens）——模型的窗口是 200k，
#   会话一开场就占掉 **79.4%**；
# - 剩下 24.7k 可用空间，于是一次排查里 **28 分钟触发了 8 次 compaction**
#   （09:06 / 09:09 / 09:13 / 09:16 / 09:18 / 09:20 / 09:21 / 09:27）；
# - 每次 compaction 后 cache 全部失效（实测 `cacheRead: 0`），等于每 2 分钟
#   全量重发 ~190k prompt；摘要越滚越大（3.4k → 26.6k 字符），细节越丢越多。
#
# 当时有三条制度在推动它增长：
#
# 1. 任务规约（`.pi/goals/*.json`）里有 65 处 acceptance 写着「AGENTS.md 新增
#    §6.x」——agent 规划任务时给自己加一条「产出文档」的验收项，然后照做；
# 2. `tools/check_agents_refs.sh` 曾要求每个 `tools/*.sh` 都被本文档提到，且
#    文档引用的标识符必须真实存在——文档成了**编译期依赖**，删内容比加内容危险；
# 3. 只有追加没有归档：103 次改动里只有 1 次让文件变小（−7 字节），
#    最近 30 次编辑 **+1968 行 / −120 行**（16:1）。
#
# 所以光拆一次不够——**没有守卫，它两周就会长回去**。这条守卫就是那个刹车。
#
# ## 为什么阈值是 20 KB
#
# 2026-11-06 从 40 KB 收紧：40 KB（约 12k tokens）允许在现状上再涨 2.5 倍，
# 「加之前先删」就只是口头约定。20 KB 是「再加一篇复盘就会撞线」的位置。
# 体积上限只防膨胀，不代表允许自主编辑；修改 AGENTS.md 仍需用户明确要求。
#
# ## 第二条判定：决策索引不得漏项
#
# 决策全文与索引统一放在 docs/design-decisions/，新增主题只维护该目录的
# README.md。守卫检查其中的相对链接，避免要求 Agent 向 AGENTS.md 追加内容。
#
# ⚠️ 豁免 `README.md`（它本身就是索引，不需要被索引）。
set -euo pipefail

cd "$(dirname "$0")/.."

DOC="AGENTS.md"
INDEX_DOC="docs/design-decisions/README.md"
# 自测要能构造「超限」样本，故阈值可注入；默认值即生产值。
LIMIT="${AGENTS_SIZE_LIMIT:-20480}"

if [ ! -f "$DOC" ]; then
  echo "❌ 未找到 $DOC"
  exit 1
fi

if [ ! -f "$INDEX_DOC" ]; then
  echo "❌ 未找到 $INDEX_DOC，请恢复设计决策索引。"
  exit 1
fi

size=$(wc -c < "$DOC" | tr -d ' ')
failed=0

if [ "$size" -gt "$LIMIT" ]; then
  echo "❌ $DOC 体积 ${size} B 超过上限 ${LIMIT} B"
  echo "   它每次请求都被全文注入——体积就是上下文预算（见脚本头）。"
  echo "   请将本次新增决策放到 docs/design-decisions/<主题>.md，索引维护在 $INDEX_DOC。"
  failed=1
fi

# ── 反向检查：决策文件必须进索引 ──────────────────────────────────
missing=()
for path in docs/design-decisions/*.md; do
  [ -e "$path" ] || continue
  name=$(basename "$path")
  [ "$name" = "README.md" ] && continue
  grep -Fq "]($name)" "$INDEX_DOC" || missing+=("$name")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "❌ 下列决策文件没有被 $INDEX_DOC 的索引提到："
  for m in "${missing[@]}"; do
    echo "   - docs/design-decisions/$m"
  done
  echo "   请在 $INDEX_DOC 的主题索引表里补上相对链接。"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "✅ AGENTS.md 体积检查通过（${size} B / 上限 ${LIMIT} B；决策文件索引无漏项）"

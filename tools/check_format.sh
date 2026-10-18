#!/usr/bin/env bash
# 格式门禁：全仓必须符合 `dart format` 的输出。
#
# WHY 需要这条门禁：`dart format` 的改动是「空白 + 尾随逗号」，不改变语义，
# 因此**不会**被 `dart analyze` 或 `flutter test` 拦下。若不单独设卡，格式会
# 持续漂移，于是某次功能改动被迫夹带几十个文件的格式噪声，审阅者再也无法
# 从 diff 里分辨「真改动」与「重新排版」——这正是本仓库 T1 任务要清理的
# 历史欠账（63 个文件）。
#
# 用 `--output=none --set-exit-if-changed` 而非 `dart format .`：
# 前者只检查不改文件，适合门禁；后者会就地重写，让「检查」变成「顺手修改」，
# 掩盖掉「谁忘了格式化」这一事实。
#
# 与 check_layering.sh 同样只用仓库根作为工作目录，保证本地与未来的 CI
# 跑的是同一条命令（见 AGENTS.md「常用命令」）。
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v dart >/dev/null 2>&1; then
  echo "❌ 未找到 dart（需 Flutter/Dart SDK 在 PATH 中）"
  exit 1
fi

# 先捕获输出与退出码：dart format 会把待格式化文件清单写到 stdout，
# 失败时要把它原样呈现给用户，否则「哪里没格式化」得靠人再跑一次才知道。
set +e
output=$(dart format --output=none --set-exit-if-changed . 2>&1)
status=$?
set -e

if [ "$status" -ne 0 ]; then
  echo "❌ 以下文件未通过 dart format："
  echo "$output" | grep '^Changed' | sed 's/^Changed /     /'
  echo ""
  echo "运行 \`dart format .\` 修复后重试。"
  exit 1
fi

echo "✅ 格式检查通过"

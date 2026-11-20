#!/usr/bin/env bash
# 同步服务端「事件契约目录」到本仓库的 vendored fixture（super_partyb#183 / 本仓 #116）。
#
# ## 它解决什么
#
# 事件契约的真源是**服务端**：`super_partyb/apps/go-api/internal/chatbus/{catalog,delivery}.go`
# → 由 `UPDATE_EVENT_CATALOG=1 go test ./internal/chatbus/ -run TestEventCatalogJSON` 生成
# `super_partyb/apps/go-api/docs/event-catalog.json`。
#
# 客户端必须与它对齐（类别闭集 / 哪些类型进时间线 / 哪些是诊断类），否则「服务端新增
# 了一个时间线事件」在本仓**完全不可见**——表现是静默丢帧，且没有任何测试会红。
#
# ## 为什么是 vendored 副本 + 手动脚本，而不是 CI 拉取
#
# 本仓库的 CI 与构建**全在 GitHub Actions**（AGENTS.md §8），到不了 `<gitea-host>`
# （私有 + 内网）。所以对拍只能读仓库内的副本：本脚本负责刷新，守卫测试
# （`packages/spb_models/test/event_catalog_test.dart`）负责比对。
#
# ## 用法
#
#   bash tools/sync_event_catalog.sh                 # 用默认路径找 Go 仓库
#   GO_API_EVENT_CATALOG=/path/to/event-catalog.json bash tools/sync_event_catalog.sh
#
# 跑完把 fixture 与随之要改的代码放在**同一个 commit**（见 fixtures/README.md）。
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${GO_API_EVENT_CATALOG:-../super_partyb/apps/go-api/docs/event-catalog.json}"
DST="packages/spb_models/fixtures/event-catalog.json"

if [ ! -f "$SRC" ]; then
  echo "找不到服务端目录：$SRC" >&2
  echo "同机开发时默认读 ../super_partyb/apps/go-api/docs/event-catalog.json；" >&2
  echo "否则用 GO_API_EVENT_CATALOG=<path> 指定。" >&2
  exit 1
fi

# 只校验「本仓真正消费的结构」，其余字段（未来加的可选位）不在这里断言：
# 服务端加字段就红会让同步变成苦差事，而那些字段本仓根本没人读。
python3 - "$SRC" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    data = json.load(f)
for k in ('schema_version', 'categories', 'envelope', 'entries', 'actions'):
    if k not in data:
        raise SystemExit(f'服务端目录缺键 {k}')
if not data['entries']:
    raise SystemExit('entries 为空：生成的目录有问题')
types = {e['type'] for e in data['entries']}
tl = sorted({e['type'] for e in data['entries'] if e.get('timeline')})
print(f'entries={len(data["entries"])} 类型={len(types)} timeline类型={len(tl)} '
      f'动作={len(data["actions"])} schema={data["schema_version"]}')
PY

cp "$SRC" "$DST.tmp"
python3 -m json.tool "$DST.tmp" > /dev/null
mv "$DST.tmp" "$DST"

echo "已写入 $DST"
if ! git diff --quiet -- "$DST"; then
  echo "⚠️ fixture 有变化：按 packages/spb_models/fixtures/README.md 的流程同步代码，"
  echo "   然后跑 (cd packages/spb_models && dart test test/event_catalog_test.dart)。"
  echo "   守卫会指出「新增但本仓没接」的类型与类别差额。"
fi

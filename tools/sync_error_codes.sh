#!/usr/bin/env bash
# 同步服务端 error code 闭集到本仓库的 vendored fixture（super_partyb#182 / #115）。
#
# ## 它解决什么
#
# `error` 事件 payload 的 `code` 闭集是**服务端**的真源：
# `super_partyb/apps/go-api/docs/error-codes.json`（由 `TestErrorCodesJSON` 生成）。
# 客户端必须与它逐条对齐（取值 + `retryable`），否则「服务端发了新 code」会被
# 客户端静默当成未知值——用户看到不带分类、可重发却必然失败的提示。
#
# ## 为什么是 vendored 副本 + 手动脚本，而不是 CI 拉取
#
# 本仓库的 CI 与构建**全在 GitHub Actions**（AGENTS.md §8），到不了
# `<gitea-host>`（私有 + 内网）。所以对拍只能读仓库内的副本：本脚本负责刷新，
# 守卫测试（`packages/spb_domain/test/error_code_test.dart`）负责比对。
#
# ## 用法
#
#   bash tools/sync_error_codes.sh                 # 用默认路径找 Go 仓库
#   GO_API_ERROR_CODES=/path/to/error-codes.json bash tools/sync_error_codes.sh
#
# 跑完把 `packages/spb_domain/test/fixtures/error_codes.json` 与
# `packages/spb_domain/lib/src/error_code.dart` 一起提交；守卫测试会指出差额。
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${GO_API_ERROR_CODES:-../super_partyb/apps/go-api/docs/error-codes.json}"
DST="packages/spb_domain/test/fixtures/error_codes.json"

if [ ! -f "$SRC" ]; then
  echo "找不到服务端清单：$SRC" >&2
  echo "同机开发时默认读 ../super_partyb/apps/go-api/docs/error-codes.json；" >&2
  echo "否则用 GO_API_ERROR_CODES=<path> 指定。" >&2
  exit 1
fi

python3 - "$SRC" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, encoding='utf-8') as f:
    data = json.load(f)
# 只锁契约三键，其余字段（未来加的可选位）不在这里断言，避免服务端加字段就红。
for row in data:
    for k in ('code', 'default_message', 'retryable'):
        if k not in row:
            raise SystemExit(f'服务端清单缺键 {k}: {row}')
print('服务端 code:', ', '.join(r['code'] for r in data))
PY

cp "$SRC" "$DST.tmp"
python3 -m json.tool "$DST.tmp" > /dev/null
mv "$DST.tmp" "$DST"

echo "已写入 $DST"
if ! git diff --quiet -- "$DST"; then
  echo "⚠️ fixture 有变化：请同步更新 packages/spb_domain/lib/src/error_code.dart 的闭集与 retryable，"
  echo "   然后跑 (cd packages/spb_domain && dart test test/error_code_test.dart)。"
fi

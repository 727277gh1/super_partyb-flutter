#!/usr/bin/env bash
# 从 Go 真源刷新客户端通知样本；CI 使用仓库内副本以保持独立构建。
set -euo pipefail
cd "$(dirname "$0")/.."
src="${GO_API_NOTIFICATION_CONTRACT:-../super_partyb/apps/go-api/docs/notification-contract.json}"
python3 - "$src" <<'PY'
import json
import pathlib
import sys
source = pathlib.Path(sys.argv[1])
data = json.loads(source.read_text())
assert data['schema_version'] == 1 and data['notices'], '通知契约为空或版本不支持'
pathlib.Path('packages/spb_models/fixtures/notification-contract.json').write_bytes(source.read_bytes())
print('通知契约样本已同步')
PY

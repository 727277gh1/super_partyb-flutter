#!/usr/bin/env bash
# super_partyb-flutter 故障演练 harness（issue #107）
# 纯 Dart 传输层钻取（无真机/无网络）；真机生命周期场景不在本机验证范围。
# 用法: scripts/rehearsal/run.sh [--out DIR]
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUT=""
[[ "${1:-}" == "--out" ]] && OUT=${2:?}
OUT=${OUT:-$ROOT/docs/rehearsal/runs/$(date +%Y%m%dT%H%M%S)}
mkdir -p "$OUT"
cd "$ROOT/packages/spb_api" || exit 1
REHEARSAL_OUT_DIR="$OUT" dart test --name "演练" 2>&1 | tee "$OUT/dart-test.log"
status=${PIPESTATUS[0]}
python3 "$ROOT/scripts/rehearsal/assemble.py" \
  --out "$OUT" --repo "dever/super_partyb-flutter" \
  --commit "$(git -C "$ROOT" rev-parse --short HEAD)" \
  --commit-full "$(git -C "$ROOT" rev-parse HEAD)" \
  --extra "dart=$(dart --version 2>&1 | head -1)" || status=$?
exit "$status"

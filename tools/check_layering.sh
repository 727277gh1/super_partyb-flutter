#!/usr/bin/env bash
# 分层规则检查：禁止纯 Dart 包依赖 Flutter。
#
# WHY 用脚本而非仅靠约定：分层一旦被破坏（比如有人图省事在 spb_api 里
# import material 做 Loading 动画），编译仍会通过，但「纯 Dart 可无头单测」
# 的能力会静默丢失，直到某天 CI 环境没有 Flutter SDK 才暴露。
#
# 这是「编译器强制」的补充——Dart 本身不提供包级依赖方向检查。
set -euo pipefail

# 纯 Dart 包：不得出现任何 flutter 依赖
PURE_DART_PKGS=(spb_core spb_models spb_api spb_domain)

failed=0

for pkg in "${PURE_DART_PKGS[@]}"; do
  dir="packages/$pkg"
  [ -d "$dir" ] || continue

  # 1) pubspec.yaml 不得声明 flutter 依赖
  if grep -qE '^\s+flutter:\s*$' "$dir/pubspec.yaml" 2>/dev/null; then
    echo "❌ $pkg/pubspec.yaml 声明了 flutter 依赖（该包必须是纯 Dart）"
    failed=1
  fi

  # 2) 源码不得 import flutter
  hits=$(grep -rn "import 'package:flutter/" "$dir/lib" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "❌ $pkg 源码中出现 flutter import："
    echo "$hits" | sed 's/^/     /'
    failed=1
  fi
done

# 3) 依赖方向检查：domain 不得依赖 data / ui / features
if [ -d packages/spb_domain/lib ]; then
  bad=$(grep -rnE "import 'package:(spb_data|spb_ui|spb_features|spb_design|spb_platform)/" \
        packages/spb_domain/lib 2>/dev/null || true)
  if [ -n "$bad" ]; then
    echo "❌ spb_domain 依赖了上层包（依赖方向必须向下）："
    echo "$bad" | sed 's/^/     /'
    failed=1
  fi
fi

# 4) api 不得依赖 domain（否则循环）
if [ -d packages/spb_api/lib ]; then
  bad=$(grep -rn "import 'package:spb_domain/" packages/spb_api/lib 2>/dev/null || true)
  if [ -n "$bad" ]; then
    echo "❌ spb_api 依赖了 spb_domain（会造成循环依赖）："
    echo "$bad" | sed 's/^/     /'
    failed=1
  fi
fi

if [ "$failed" -eq 0 ]; then
  echo "✅ 分层规则检查通过"
else
  echo ""
  echo "详见 AGENTS.md「分层规则」章节。"
  exit 1
fi

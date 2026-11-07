#!/usr/bin/env bash
# 守卫：每个成员包的 analysis_options.yaml 必须引用工作区根配置。
#
# ## 为什么需要它
#
# Dart analyzer **不会**向上继承父目录的 `analysis_options.yaml`——每个包只读
# 自己那份。因此根 `analysis_options.yaml` 里声明的跨包规则
# （`always_declare_return_types` / `avoid_print` / `unawaited_futures` /
# `prefer_const_constructors` / `prefer_const_declarations`）**只对显式
# include 了它的包生效**。
#
# 这个失效是**静默**的：`dart analyze --fatal-infos .` 照样输出
# 「No issues found!」，CI 全绿，但严格规则一条都没跑（issue #34）。
# 唯一能发现的时机是「某天有人手工把根配置挂上，突然冒出 97 条」。
#
# 所以必须有这道守卫：它检查的不是「代码有没有问题」，而是「门禁本身有没有
# 接上」——后者无法由任何 lint 规则自证。
#
# ## 为什么是「必须引用」而不是「内容一致」
#
# 各包还需要自己的基础规则集（纯 Dart 包用 `package:lints/recommended.yaml`，
# 含 Flutter 的用 `package:flutter_lints/flutter.yaml`）与包级例外
# （如 `use_null_aware_elements: false`）。故根配置是**追加**的一层，不是替换。
# 本脚本只断言「根配置在 include 列表里」，不干涉各包的其余配置。
set -euo pipefail

cd "$(dirname "$0")/.."

ROOT_CONFIG='../../analysis_options.yaml'
failed=0
checked=0

shopt -s nullglob
for f in packages/*/analysis_options.yaml apps/*/analysis_options.yaml; do
  checked=$((checked + 1))
  if ! grep -qF "$ROOT_CONFIG" "$f"; then
    echo "❌ $f 未引用根配置（$ROOT_CONFIG）"
    echo "     该包将丢失根 analysis_options.yaml 声明的跨包规则。"
    failed=1
  fi
done
shopt -u nullglob

if [ "$checked" -eq 0 ]; then
  echo "❌ 没有找到任何成员包的 analysis_options.yaml（工作目录不对？）"
  exit 1
fi

# 根配置本身也要在，且真的声明了规则——否则「引用了空文件」同样静默失效。
if [ ! -f analysis_options.yaml ]; then
  echo "❌ 根 analysis_options.yaml 不存在"
  failed=1
else
  for rule in always_declare_return_types avoid_print unawaited_futures \
              prefer_const_constructors prefer_const_declarations; do
    if ! grep -qE "^[[:space:]]*${rule}:[[:space:]]*true" analysis_options.yaml; then
      echo "❌ 根 analysis_options.yaml 未声明规则 $rule"
      failed=1
    fi
  done

  # 严格模式（issue #47 第四项）。
  #
  # 同样是「门禁本身有没有接上」：把 strict-casts 删掉后 `dart analyze`
  # 依然报「No issues found!」，没人会注意到。三项已实测全仓零告警
  # （strict-casts / strict-raw-types 零成本；strict-inference 的 103 条
  # 已在 issue #47 中全部修掉），故这里断言它们**必须在**。
  for mode in strict-casts strict-raw-types strict-inference; do
    if ! grep -qE "^[[:space:]]*${mode}:[[:space:]]*true" analysis_options.yaml; then
      echo "❌ 根 analysis_options.yaml 未开启严格模式 $mode"
      echo "     删除它不会让 dart analyze 报错——正是这道守卫要拦的静默回退。"
      failed=1
    fi
  done
fi

if [ "$failed" -eq 0 ]; then
  echo "✅ 静态分析配置检查通过（$checked 个成员包均引用根配置）"
else
  echo ""
  echo "详见 AGENTS.md「分层规则」与 issue #34。"
  exit 1
fi

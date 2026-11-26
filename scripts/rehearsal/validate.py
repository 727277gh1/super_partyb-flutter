#!/usr/bin/env python3
"""校验演练结果 JSON（schema rehearsal/v1）。

用处：各仓库的 `scripts/rehearsal/run.sh` 只负责产出与自检；跨仓汇总入口
（super_partyb `scripts/rehearsal/run-all.sh`）在汇总前统一用这里校验，
避免「格式不一导致汇总只能人工抄写」。

CLI:
    python3 validate.py <result.json> [...]    # 通过返回 0，失败打印原因返回 2
"""
from __future__ import annotations

import json
import sys

SCHEMA = "rehearsal/v1"

REQUIRED_TOP = ("schema", "run_id", "repo", "commit", "generated_at", "scenarios", "summary")
REQUIRED_SCENARIO = ("scenario_id", "repo", "injection", "scope", "criteria", "passed", "evidence")
VALID_SCOPE = ("in-process", "local-process", "tmpfs", "external")
REQUIRED_CRITERION = ("id", "requirement", "observed", "passed")


def validate(doc: dict) -> list[str]:
    errs: list[str] = []
    if doc.get("schema") != SCHEMA:
        errs.append(f"schema={doc.get('schema')!r}，期望 {SCHEMA!r}")
    for key in REQUIRED_TOP:
        if key not in doc:
            errs.append(f"缺少顶层字段 {key}")
    scenarios = doc.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        errs.append("scenarios 必须是非空数组")
        return errs

    for i, sc in enumerate(scenarios):
        where = f"scenarios[{i}]"
        if not isinstance(sc, dict):
            errs.append(f"{where} 不是对象")
            continue
        where = f"scenarios[{i}:{sc.get('scenario_id', '?')}]"
        for key in REQUIRED_SCENARIO:
            if key not in sc:
                errs.append(f"{where} 缺少字段 {key}")
        if sc.get("scope") not in VALID_SCOPE:
            errs.append(f"{where} scope={sc.get('scope')!r} 不在 {VALID_SCOPE} 内")
        if not isinstance(sc.get("passed"), bool):
            errs.append(f"{where} passed 必须是布尔值")
        criteria = sc.get("criteria")
        if not isinstance(criteria, list) or not criteria:
            errs.append(f"{where} criteria 必须是非空数组")
        else:
            for j, c in enumerate(criteria):
                for key in REQUIRED_CRITERION:
                    if key not in c:
                        errs.append(f"{where}.criteria[{j}] 缺少 {key}")
                if not isinstance(c.get("passed"), bool):
                    errs.append(f"{where}.criteria[{j}] passed 必须是布尔值")
        if not isinstance(sc.get("evidence"), list) or not sc.get("evidence"):
            errs.append(f"{where} evidence 必须是非空数组（证据不能缺席）")

    summary = doc.get("summary") or {}
    total = len(scenarios)
    passed = sum(1 for sc in scenarios if isinstance(sc, dict) and sc.get("passed") is True)
    if summary.get("total") != total:
        errs.append(f"summary.total={summary.get('total')!r}，实际 {total}")
    if summary.get("passed") != passed:
        errs.append(f"summary.passed={summary.get('passed')!r}，实际 {passed}")
    if summary.get("failed") != total - passed:
        errs.append(f"summary.failed={summary.get('failed')!r}，实际 {total - passed}")
    return errs


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: validate.py <result.json> [...]", file=sys.stderr)
        return 2
    rc = 0
    for path in argv[1:]:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"FAIL {path}: 读取/解析失败 {exc}", file=sys.stderr)
            rc = 2
            continue
        errs = validate(doc)
        if errs:
            print(f"FAIL {path}", file=sys.stderr)
            for e in errs:
                print(f"  - {e}", file=sys.stderr)
            rc = 2
        else:
            print(f"OK   {path} ({len(doc['scenarios'])} 个场景)")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

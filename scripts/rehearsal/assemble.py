#!/usr/bin/env python3
"""把钻取测试产出的场景 JSON 汇总成一份 rehearsal/v1 结果。

各仓的 drill 测试只在 $REHEARSAL_OUT_DIR 下写「单个场景」的 JSON
（scenario_id / injection / criteria / metrics...），跨仓可比的元信息
（run_id / commit / 汇总）在这里补齐，随后用 validate.py 自检。

CLI:
    assemble.py --out DIR --repo dever/xxx --commit <short> [--commit-full <sha>]
                [--extra key=value ...]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from validate import validate  # noqa: E402


def load_scenarios(out_dir: str) -> list[dict]:
    scenarios = []
    for name in sorted(os.listdir(out_dir)):
        if not name.endswith(".json") or name == "rehearsal.json":
            continue
        path = os.path.join(out_dir, name)
        with open(path, "r", encoding="utf-8") as fh:
            doc = json.load(fh)
        if "scenario_id" not in doc:
            continue  # 不是场景文件（如工具写入的其它 json）
        doc.setdefault("evidence", [])
        scenarios.append(doc)
    return scenarios


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="结果目录（drill 测试写入的同一目录）")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--commit-full", default="")
    ap.add_argument("--run-id", default="")
    ap.add_argument("--extra", action="append", default=[], metavar="KEY=VALUE")
    args = ap.parse_args()

    scenarios = load_scenarios(args.out)
    if not scenarios:
        print(f"FAIL: {args.out} 下没有任何场景 JSON（drill 测试可能没跑或没写结果）", file=sys.stderr)
        return 2

    passed = sum(1 for sc in scenarios if sc.get("passed") is True)
    doc = {
        "schema": "rehearsal/v1",
        "run_id": args.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        "repo": args.repo,
        "commit": args.commit,
        "commit_full": args.commit_full,
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "scenarios": scenarios,
        "summary": {"total": len(scenarios), "passed": passed, "failed": len(scenarios) - passed},
        "extra": dict(kv.split("=", 1) for kv in args.extra if "=" in kv),
    }

    result_path = os.path.join(args.out, "rehearsal.json")
    with open(result_path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    errs = validate(doc)
    if errs:
        print(f"FAIL {result_path}", file=sys.stderr)
        for e in errs:
            print(f"  - {e}", file=sys.stderr)
        return 2
    print(f"OK   {result_path}: {len(scenarios)} 个场景，通过 {passed}，失败 {len(scenarios) - passed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

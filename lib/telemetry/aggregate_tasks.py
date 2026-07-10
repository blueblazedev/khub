#!/usr/bin/env python3
"""Aggregate output tokens per task/ticket across all captured sessions.

Reads every `metrics/<id>.json` (each carries `tokens_by_task: {task: {output,
input, ...}}`) and prints a descending table of total tokens per task. This is how
`khub metrics --by-task` answers "how many tokens did ticket X cost across however
many sessions it took". Read-only; a bad/absent file is skipped, never fatal.
"""
import json
import os
import sys


def main():
    mdir = sys.argv[1] if len(sys.argv) > 1 else "."
    totals = {}   # task -> {output, input, sessions}
    try:
        names = sorted(os.listdir(mdir))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(mdir, name), encoding="utf-8") as fh:
                m = json.load(fh)
        except Exception:
            continue
        tbt = m.get("tokens_by_task")
        if not isinstance(tbt, dict):
            continue
        for task, tok in tbt.items():
            if not isinstance(tok, dict):
                continue
            agg = totals.setdefault(str(task), {"output": 0, "input": 0, "sessions": 0})
            try:
                agg["output"] += int(tok.get("output", 0) or 0)
                agg["input"] += int(tok.get("input", 0) or 0)
            except (TypeError, ValueError):
                pass
            agg["sessions"] += 1

    if not totals:
        print("  no task attribution yet — run some sessions with telemetry enabled")
        return
    rows = sorted(totals.items(), key=lambda kv: kv[1]["output"], reverse=True)
    width = max((len(t) for t, _ in rows), default=4)
    for task, a in rows:
        print("  %-*s   out %d · in %d   (%d session%s)"
              % (width, task, a["output"], a["input"], a["sessions"],
                 "" if a["sessions"] == 1 else "s"))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

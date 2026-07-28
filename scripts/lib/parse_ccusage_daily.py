#!/usr/bin/env python3
"""Parse `ccusage daily --json --by-agent` output into shell-friendly totals."""

import argparse
import json
import sys


def _num(value, default=0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _tokens(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _cost(row):
    if "totalCost" in row:
        return _num(row.get("totalCost"), 0.0)
    return _num(row.get("costUSD"), 0.0)


def _row_date(row):
    if row.get("period"):
        return row.get("period"), "period"
    if row.get("date"):
        return row.get("date"), "date"
    return "", "unknown"


def _agent_totals(row, agent):
    agents = row.get("agents")
    if isinstance(agents, list):
        tokens = 0
        cost = 0.0
        for item in agents:
            if not isinstance(item, dict) or item.get("agent") != agent:
                continue
            tokens += _tokens(item.get("totalTokens", 0))
            cost += _cost(item)
        return tokens, cost

    row_agent = row.get("agent")
    if row_agent == agent:
        return _tokens(row.get("totalTokens", 0)), _cost(row)

    # Do not treat agent:"all" or missing agent as Claude. That would mix
    # Codex usage into Claude totals under the new ccusage default.
    return 0, 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--agent", choices=("claude", "codex"), required=True)
    parser.add_argument("--today", required=True)
    parser.add_argument("--since", required=True)
    args = parser.parse_args()

    try:
        data = json.load(sys.stdin)
    except Exception:
        data = {}

    tokens_24h = 0
    cost_24h = 0.0
    tokens_range = 0
    cost_range = 0.0
    rows = 0
    keystyle = "unknown"

    for row in data.get("daily", []):
        if not isinstance(row, dict):
            continue
        day, style = _row_date(row)
        if style != "unknown" and keystyle == "unknown":
            keystyle = style
        if not day or day < args.since or day > args.today:
            continue

        rows += 1
        tokens, cost = _agent_totals(row, args.agent)
        tokens_range += tokens
        cost_range += cost
        if day == args.today:
            tokens_24h += tokens
            cost_24h += cost

    print(f"TOKENS_24H={tokens_24h}")
    print(f"COST_24H={cost_24h}")
    print(f"TOKENS_RANGE={tokens_range}")
    print(f"COST_RANGE={cost_range}")
    print(f"ROWS={rows}")
    print(f"KEYSTYLE={keystyle}")


if __name__ == "__main__":
    main()

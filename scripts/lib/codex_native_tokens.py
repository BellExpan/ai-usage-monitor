#!/usr/bin/env python3
"""Native Codex token aggregation from session JSONL.

This intentionally does not depend on ccusage.  It reads Codex
``token_count`` events directly and estimates session token usage from
``payload.info.total_token_usage``.  When a session reports a monotonic total,
positive deltas are summed; if a session only has one total-bearing event, that
total is counted once.
"""

import argparse
import datetime as dt
import glob
import json
import os
import sys
import time


def _parse_ts(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _num(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def _usage_total(value):
    """Return the session's total token count from a ``total_token_usage`` dict.

    Codex reports overlapping fields — summing them double counts::

        {"input_tokens": 95848,        # includes cached_input_tokens
         "cached_input_tokens": 71168, # subset of input_tokens
         "output_tokens": 2822,        # includes reasoning_output_tokens
         "reasoning_output_tokens": 1411,
         "total_tokens": 98670}        # == input_tokens + output_tokens

    Summing every non-cache key yields ~2x the real value because
    ``total_tokens`` is added on top of its own components.  That inflation made
    the cross-check against ccusage fire ``token_source_mismatch`` on perfectly
    healthy data (2026-07-28: 31.3M vs 14.6M = 2.15x), i.e. the drift detector
    cried wolf — which is worse than no detector at all (alert fatigue).

    Rules:
      * prefer the authoritative ``total_tokens`` when present
      * otherwise add only the two top-level buckets (input + output);
        ``cached_*`` and ``reasoning_*`` are subsets and must not be added
    """
    if isinstance(value, (int, float, str)):
        return _num(value)
    if not isinstance(value, dict):
        return 0

    # 1) authoritative total
    for key in ("total_tokens", "total_token_count"):
        if isinstance(value.get(key), (int, float, str)):
            total = _num(value[key])
            if total:
                return total

    # 2) top-level buckets only (subsets excluded)
    total = 0
    for key in ("input_tokens", "output_tokens"):
        if isinstance(value.get(key), (int, float, str)):
            total += _num(value[key])
    if total:
        return total

    # 3) Some snapshots nest model/category totals one level down.
    for val in value.values():
        if isinstance(val, dict):
            total += _usage_total(val)
    return total


def _event_usage(row):
    payload = row.get("payload") if isinstance(row, dict) else {}
    if not isinstance(payload, dict) or payload.get("type") != "token_count":
        return 0
    info = payload.get("info")
    if not isinstance(info, dict):
        return 0
    return _usage_total(info.get("total_token_usage"))


def aggregate(sessions_dir, today=None, now=None):
    now = time.time() if now is None else now
    if today is None:
        today = dt.datetime.fromtimestamp(now).strftime("%Y-%m-%d")
    since_24h = now - 86400
    today_start = dt.datetime.strptime(today, "%Y-%m-%d").replace(tzinfo=None).timestamp()

    tokens_today = 0
    tokens_24h = 0
    events_today = 0
    events_24h = 0

    files = sorted(glob.glob(os.path.join(sessions_dir, "**", "*.jsonl"), recursive=True))
    for path in files:
        day_totals = []
        totals_24h = []
        try:
            fp = open(path, encoding="utf-8")
        except OSError:
            continue
        with fp:
            for line in fp:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                total = _event_usage(row)
                if total <= 0:
                    continue
                ts = _parse_ts(row.get("timestamp"))
                if ts is None:
                    try:
                        ts = os.path.getmtime(path)
                    except OSError:
                        ts = now
                if ts >= today_start:
                    day_totals.append(total)
                    events_today += 1
                if ts >= since_24h:
                    totals_24h.append(total)
                    events_24h += 1

        tokens_today += _session_total(day_totals)
        tokens_24h += _session_total(totals_24h)

    return {
        "TOKENS_TODAY": tokens_today,
        "TOKENS_24H": tokens_24h,
        "EVENTS_TODAY": events_today,
        "EVENTS_24H": events_24h,
    }


def _session_total(totals):
    if not totals:
        return 0
    if len(totals) == 1:
        return totals[0]
    out = totals[0]
    prev = totals[0]
    for cur in totals[1:]:
        if cur >= prev:
            out += cur - prev
        else:
            out += cur
        prev = cur
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions_dir", nargs="?", default=os.path.expanduser("~/.codex/sessions"))
    parser.add_argument("--today")
    args = parser.parse_args()

    for key, value in aggregate(args.sessions_dir, today=args.today).items():
        print(f"{key}={value}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"codex_native_tokens: {exc}", file=sys.stderr)
        sys.exit(1)

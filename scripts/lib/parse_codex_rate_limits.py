#!/usr/bin/env python3
"""Codex rate_limits parser.

Reads the newest usable token_count event from ~/.codex/sessions/**/*.jsonl and
prints KEY=VALUE lines for short-term and weekly Codex rate-limit windows.

Codex changed the rate_limits shape around 2026-07-12: the weekly window moved
from secondary to primary and secondary became null. The parser therefore does
not assume primary=5h and secondary=week. It collects every dict-valued
rate_limits entry with used_percent, then classifies by window_minutes:

  * 0 < window_minutes < 1440: short window (5h-style)
  * window_minutes >= 1440: long window (weekly-style)

If multiple candidates exist, the shortest short window and longest long window
are selected. Entries with missing/zero window_minutes are classification
unknown and do not populate either window.

Output keys are stable KEY=VALUE lines so callers can ignore future additions:

  P5_AVAILABLE P5_USED_PCT P5_REMAINING_PCT P5_RESETS_AT P5_WINDOW_MIN
  WK_AVAILABLE WK_USED_PCT WK_REMAINING_PCT WK_RESETS_AT WK_WINDOW_MIN
  FRESH SCHEMA

Broken JSONL lines are skipped line-by-line. Events with no usable frame entry
are skipped, generalizing the old primary=null/secondary=null marker defense.
Remaining percentages are clamped to [0, 100]. Freshness uses aware datetime
epoch conversion to avoid timezone-boundary drift.
"""

import datetime
import glob
import json
import os
import sys
import time


def _frame_candidates(rate_limits):
    if not isinstance(rate_limits, dict):
        return []

    out = []
    for name, value in rate_limits.items():
        if not isinstance(value, dict) or "used_percent" not in value:
            continue
        try:
            used = float(value.get("used_percent", 0) or 0)
        except (TypeError, ValueError):
            used = 0.0
        try:
            window = int(value.get("window_minutes", 0) or 0)
        except (TypeError, ValueError):
            window = 0
        try:
            resets_at = int(value.get("resets_at", 0) or 0)
        except (TypeError, ValueError):
            resets_at = 0
        out.append(
            {
                "name": name,
                "used_percent": used,
                "window_minutes": window,
                "resets_at": resets_at,
            }
        )
    return out


def _remaining(used):
    return round(max(0.0, min(100.0, 100.0 - used)), 1)


def _window_output(prefix, frame):
    if not frame:
        return {
            f"{prefix}_AVAILABLE": "0",
            f"{prefix}_USED_PCT": "0",
            f"{prefix}_REMAINING_PCT": "100",
            f"{prefix}_RESETS_AT": "0",
            f"{prefix}_WINDOW_MIN": "0",
        }

    used = frame["used_percent"]
    return {
        f"{prefix}_AVAILABLE": "1",
        f"{prefix}_USED_PCT": str(used),
        f"{prefix}_REMAINING_PCT": f"{_remaining(used):.1f}",
        f"{prefix}_RESETS_AT": str(frame["resets_at"]),
        f"{prefix}_WINDOW_MIN": str(frame["window_minutes"]),
    }


def _classify(frames):
    short_candidates = [f for f in frames if 0 < f["window_minutes"] < 1440]
    long_candidates = [f for f in frames if f["window_minutes"] >= 1440]

    short = min(short_candidates, key=lambda f: f["window_minutes"], default=None)
    long = max(long_candidates, key=lambda f: f["window_minutes"], default=None)
    return short, long


def _schema(short, long):
    if short and long:
        return "legacy_5h_week"
    if long:
        return "week_only"
    if short:
        return "short_only"
    return "none"


def _fresh(timestamp):
    if not timestamp:
        return 0
    try:
        epoch = datetime.datetime.fromisoformat(
            timestamp.replace("Z", "+00:00")
        ).timestamp()
        return 1 if (time.time() - epoch) < 86400 else 0
    except Exception:
        return 0


def _defaults():
    out = {}
    out.update(_window_output("P5", None))
    out.update(_window_output("WK", None))
    out["FRESH"] = "0"
    out["SCHEMA"] = "none"
    return out


def _print(out):
    for key in (
        "P5_AVAILABLE",
        "P5_USED_PCT",
        "P5_REMAINING_PCT",
        "P5_RESETS_AT",
        "P5_WINDOW_MIN",
        "WK_AVAILABLE",
        "WK_USED_PCT",
        "WK_REMAINING_PCT",
        "WK_RESETS_AT",
        "WK_WINDOW_MIN",
        "FRESH",
        "SCHEMA",
    ):
        print(f"{key}={out[key]}")


def main():
    sessions_dir = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.expanduser("~/.codex/sessions")
    )
    files = sorted(
        glob.glob(os.path.join(sessions_dir, "**", "*.jsonl"), recursive=True)
    )

    selected_frames = None
    selected_ts = ""
    for f in reversed(files):
        try:
            fp = open(f)
        except OSError:
            continue
        with fp:
            for line in fp:
                try:
                    d = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(d, dict) or d.get("type") != "event_msg":
                    continue
                payload = d.get("payload", {})
                if not isinstance(payload, dict):
                    continue
                if payload.get("type") != "token_count" or "rate_limits" not in payload:
                    continue
                frames = _frame_candidates(payload.get("rate_limits"))
                if frames:
                    selected_frames = frames
                    selected_ts = d.get("timestamp", "")
        if selected_frames:
            break

    if not selected_frames:
        _print(_defaults())
        return

    short, long = _classify(selected_frames)

    out = {}
    out.update(_window_output("P5", short))
    out.update(_window_output("WK", long))
    out["FRESH"] = str(_fresh(selected_ts))
    out["SCHEMA"] = _schema(short, long)
    _print(out)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Codex rate_limits パーサ（Issue #7）。

~/.codex/sessions/**/*.jsonl の最新 token_count イベントから
5h(primary)/週(secondary) 枠の使用率・残量・リセット epoch を抽出する。

出力(stdout, スペース区切り 7 値):
  p5_used p5_remaining p5_resets_at wk_used wk_remaining wk_resets_at fresh

設計判断（クラッシュ防止の要）:
  Codex は週枠枯渇時に `limit_id=premium` / `primary=null` / `secondary=null`
  の credits 切替マーカーイベントを emit する。このイベントは window 情報を
  持たないため、5h/週枠の表示には使えない。
  primary か secondary のどちらかが非 null の「有効な」rate_limits のみを採用し、
  null マーカーはスキップする。これを怠ると pri.get() で AttributeError となり、
  呼び出し側がデフォルト（残100% / RESETS_AT=0）にフォールバックして
  「枯渇中の Codex を残100% / ↺非表示」と誤表示する。
"""
import datetime
import glob
import json
import os
import sys
import time


def main():
    sessions_dir = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.expanduser("~/.codex/sessions")
    )
    files = sorted(
        glob.glob(os.path.join(sessions_dir, "**", "*.jsonl"), recursive=True)
    )

    rate_limits = None
    ts = ""
    for f in reversed(files):
        try:
            with open(f) as fp:
                for line in fp:
                    d = json.loads(line)
                    if d.get("type") != "event_msg":
                        continue
                    p = d.get("payload", {})
                    if p.get("type") == "token_count" and "rate_limits" in p:
                        rl = p["rate_limits"]
                        # primary/secondary が両方 null のイベント
                        # （premium 切替・週枯渇マーカー）は window 情報なし
                        # → スキップし、直近の有効な rate_limits を採用する
                        if rl and (rl.get("primary") or rl.get("secondary")):
                            rate_limits = rl
                            ts = d.get("timestamp", "")
            if rate_limits:
                break
        except Exception:
            pass

    if not rate_limits:
        print("0 100 0 0 100 0 0")
        return

    pri = rate_limits.get("primary") or {}
    sec = rate_limits.get("secondary") or {}
    p5u = float(pri.get("used_percent", 0))
    wku = float(sec.get("used_percent", 0))
    p5r = round(100 - p5u, 1)
    wkr = round(100 - wku, 1)
    p5at = int(pri.get("resets_at", 0))
    wkat = int(sec.get("resets_at", 0))

    # 24h 以内のデータか（既存挙動を踏襲）
    fresh = 0
    if ts:
        try:
            epoch = time.mktime(
                datetime.datetime.fromisoformat(
                    ts.replace("Z", "+00:00")
                ).timetuple()
            )
            fresh = 1 if (time.time() - epoch) < 86400 else 0
        except Exception:
            fresh = 0

    print(p5u, p5r, p5at, wku, wkr, wkat, fresh)


if __name__ == "__main__":
    main()

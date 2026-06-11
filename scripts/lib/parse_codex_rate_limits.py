#!/usr/bin/env python3
"""Codex rate_limits パーサ（Issue #7）。

~/.codex/sessions/**/*.jsonl の最新 token_count イベントから
5h(primary)/週(secondary) 枠の使用率・残量・リセット epoch を抽出する。

出力(stdout, スペース区切り 9 値):
  p5_used p5_remaining p5_resets_at wk_used wk_remaining wk_resets_at fresh \
  p5_window_minutes wk_window_minutes

window_minutes は resets_at が過去になった時の「次リセット」ロールフォワード投影に使う
（Issue #18: Codex 未使用で fresh データが来ないと resets_at が過去固定 → ↺soon 永久固定を解消）。
欠落イベントでは 0（= window 不明 → 投影しない安全側）を出す。

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
            fp = open(f)
        except OSError:
            continue
        with fp:
            for line in fp:
                # 壊れ行・書き込み途中のトランケート末尾行は「その行だけ」
                # スキップする。try をファイル全体に掛けると、有効イベントより
                # 前に1行でも壊れ行があるとファイル丸ごと捨てて
                # デフォルト（残100%）にフォールバックし、本修正が直す
                # 「枯渇を残100%」バグを別経路で再発させる（RI-1）。
                try:
                    d = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(d, dict) or d.get("type") != "event_msg":
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

    if not rate_limits:
        print("0 100 0 0 100 0 0 0 0")
        return

    pri = rate_limits.get("primary") or {}
    sec = rate_limits.get("secondary") or {}
    p5u = float(pri.get("used_percent", 0))
    wku = float(sec.get("used_percent", 0))
    # 残量は [0,100] にクランプ（異常値で負/超過残量が下流の閾値比較を
    # 誤らせるのを防ぐ・RI-3）
    p5r = round(max(0.0, min(100.0, 100 - p5u)), 1)
    wkr = round(max(0.0, min(100.0, 100 - wku)), 1)
    p5at = int(pri.get("resets_at", 0))
    wkat = int(sec.get("resets_at", 0))
    # window_minutes（5h=300 / 週=10080）。欠落時は 0 = 投影しない安全側（#18）。
    p5win = int(pri.get("window_minutes", 0) or 0)
    wkwin = int(sec.get("window_minutes", 0) or 0)

    # 24h 以内のデータか。aware datetime の .timestamp() で正しい epoch を得る
    # （旧 mktime(timetuple()) は naive 解釈で TZ オフセット分ズレ境界判定が
    # 反転しうる・RI-2）
    fresh = 0
    if ts:
        try:
            epoch = datetime.datetime.fromisoformat(
                ts.replace("Z", "+00:00")
            ).timestamp()
            fresh = 1 if (time.time() - epoch) < 86400 else 0
        except Exception:
            fresh = 0

    print(p5u, p5r, p5at, wku, wkr, wkat, fresh, p5win, wkwin)


if __name__ == "__main__":
    main()

#!/bin/bash
# lib/reset-label.sh — リセット残り時間ラベルの純粋関数（Codex/Claude 対称・Issue #15）
#
# statusline が5秒ごとに実行されるため、cache に丸め込まれた整数時間ではなく
# resets_at（epoch）と現在時刻から都度計算する。これにより:
#   - 残り <1h が整数除算で 0 に丸められ "↺" が消える構造バグを解消
#   - cache 更新（5分間隔）のラグを受けず、リセット直前/直後も正確
#
# 仕様（新規絵文字追加禁止・既存 ↺ のみ使用）:
#   resets_at <= 0          → 非表示（空文字。epoch 未知 = データ無し）
#   secs <= 0  (過去)        → "↺soon"（resets_at は既知だが now を過ぎた = cache ラグ）
#   0 < secs < 3600         → "↺<1h"（残り1時間未満。0h 誤読防止）
#   3600 <= secs            → "↺Nh"（N = secs/3600、常に時間単位・上限なし）
#
# 使い方:
#   label=$(reset_label_from_epoch "$RESETS_AT_EPOCH" "$(date +%s)")
#   本関数が "↺" 込みの完成ラベル本体（色なし）を返す。色は呼び出し側で付与。

# 引数: $1 = resets_at（epoch 秒）, $2 = now（epoch 秒）
# 出力: ラベル本体（"↺36h" / "↺<1h" / "↺soon" / 空）。色コードは含めない。
reset_label_from_epoch() {
  local resets_at="${1:-0}" now="${2:-0}" secs hours
  # 非数値ガード（外部 JSONL / cache 由来の汚染値を弾く）
  # 整数のみ許容（先頭 - は許容）。"12-" / "--5" / "1-2" 等のダッシュ混入も弾く。
  [[ "$resets_at" =~ ^-?[0-9]+$ ]] || resets_at=0
  [[ "$now"       =~ ^-?[0-9]+$ ]] || now=0
  # epoch 未知 = データ無し → 非表示
  [ "$resets_at" -le 0 ] 2>/dev/null && { printf ''; return 0; }
  secs=$(( resets_at - now ))
  if   [ "$secs" -le 0 ];    then printf '↺soon'
  elif [ "$secs" -lt 3600 ]; then printf '↺<1h'
  else
    hours=$(( secs / 3600 ))
    printf '↺%sh' "$hours"
  fi
}

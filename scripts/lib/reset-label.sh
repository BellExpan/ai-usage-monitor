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

# roll_resets_at_forward — 過去になった resets_at を window 周期分だけ未来へ巻き進める（Issue #18）
#
# Codex/Claude の rate_limit window はリセット時刻が固定の周期境界。Codex を使わない等で
# fresh データが来ないと、resets_at が過去のまま居座り "↺soon" が永久固定される（更新されない）。
# window_minutes（5h=300 / 週=10080）が既知なら、ウィンドウは決定論的に周期リセット済みと分かるため
# 次の境界まで巻き進められる。これにより fresh データ無しでも正しい次リセット時刻を投影できる。
#
# 引数: $1 = resets_at（epoch 秒）, $2 = now（epoch 秒）, $3 = window_minutes
# 出力: 未来側に巻き進めた epoch（window 不明/未来/未知 epoch の場合は入力をそのまま返す）
roll_resets_at_forward() {
  local resets_at="${1:-0}" now="${2:-0}" window_min="${3:-0}" window_secs elapsed steps
  [[ "$resets_at"  =~ ^-?[0-9]+$ ]] || resets_at=0
  [[ "$now"        =~ ^-?[0-9]+$ ]] || now=0
  [[ "$window_min" =~ ^[0-9]+$    ]] || window_min=0
  # window 不明 / epoch 未知 / 既に未来 → 触らずそのまま返す
  if [ "$window_min" -le 0 ] || [ "$resets_at" -le 0 ] || [ "$resets_at" -gt "$now" ]; then
    printf '%s' "$resets_at"; return 0
  fi
  window_secs=$(( window_min * 60 ))
  # 経過分を一発で周期数に変換（巨大ギャップでも O(1)・ループ無し）。
  # steps = floor(elapsed/window)+1 で必ず now を超える最小の周期境界に着地する。
  elapsed=$(( now - resets_at ))
  steps=$(( elapsed / window_secs + 1 ))
  printf '%s' "$(( resets_at + steps * window_secs ))"
}

# 引数: $1 = resets_at（epoch 秒）, $2 = now（epoch 秒）, $3 = window_minutes（任意・Issue #18）
# 出力: ラベル本体（"↺36h" / "↺<1h" / "↺soon" / 空）。色コードは含めない。
# window_minutes を渡すと、過去 resets_at を次リセットへ巻き進めてから判定する（↺soon 固定の解消）。
# 省略時（2引数）は従来挙動（過去 → soon）を維持＝後方互換。
reset_label_from_epoch() {
  local resets_at="${1:-0}" now="${2:-0}" window_min="${3:-0}" secs hours
  # 非数値ガード（外部 JSONL / cache 由来の汚染値を弾く）
  # 整数のみ許容（先頭 - は許容）。"12-" / "--5" / "1-2" 等のダッシュ混入も弾く。
  [[ "$resets_at" =~ ^-?[0-9]+$ ]] || resets_at=0
  [[ "$now"       =~ ^-?[0-9]+$ ]] || now=0
  # epoch 未知 = データ無し → 非表示
  [ "$resets_at" -le 0 ] 2>/dev/null && { printf ''; return 0; }
  # window 既知なら過去 resets_at を次リセットへ巻き進める（fresh データ無しでの soon 固定を解消）
  resets_at=$(roll_resets_at_forward "$resets_at" "$now" "$window_min")
  secs=$(( resets_at - now ))
  if   [ "$secs" -le 0 ];    then printf '↺soon'
  elif [ "$secs" -lt 3600 ]; then printf '↺<1h'
  else
    hours=$(( secs / 3600 ))
    printf '↺%sh' "$hours"
  fi
}

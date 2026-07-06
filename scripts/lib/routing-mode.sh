#!/bin/bash
# shellcheck disable=SC2034  # 出力はグローバル変数（ROUTING_MODE 等）で呼び出し側 cache-update.sh が参照する
# lib/routing-mode.sh — バランスギャップに基づくルーティングモード判定（純粋関数・Issue #28）
#
# 目的: Claude / Codex の週次残量を均衡（±10%以内）に保つよう「今どちらに振るべきか」を決める。
#   BALANCE_GAP = Claude7d残 - Codex週残
#     +（Claude余裕）→ 余っている Claude を使い Codex を温存  = claude_first
#     -（Codex 余裕）→ 余っている Codex を使い Claude を温存  = codex_first
#
#   ⚠️ 2026-07-06 Issue #28: この first 系2分岐が cache-update.sh で逆転していた
#      （Codex余裕なのに claude_first を提案しギャップを広げる回帰）。
#      判定を本 lib に集約し bats（tests/routing-mode.bats）で方向を固定した。
#      hooks/session-start.sh:59 の自動昇格（Codex余裕→codex_first）が正方向で、
#      cache-update.sh 側だけが逆だったのが根拠。
#
# 優先順位: Claude保護 > Codex保護 > Burn(リセット前の使い切り) > バランス(first / normal)
#
# 入力（環境変数・未設定/空はデフォルト値。呼び出し側で整数化して渡すこと）:
#   CLA_7D_REM_INT              Claude 週次残 %      (default 100)
#   CDX_5H_REM_INT             Codex 5h 残 %        (default 100)
#   CDX_WEEK_REM_INT           Codex 週次残 %       (default 100)
#   CDX_RATE_LIMITS_FRESH      Codex データ鮮度 0/1 (default 0)
#   CLA_OAUTH_FRESH            Claude データ鮮度 0/1 (default 0)
#   CDX_HOURS_UNTIL_RESET      Codex リセットまで時間  (default 168)
#   CLA_7D_HOURS_UNTIL_RESET   Claude リセットまで時間 (default 168)
#   DAILY_BURN_PCT             1日あたり消費ペース %   (default 20)
#
# 出力（グローバル変数を設定。副作用は変数設定のみ・冪等）:
#   ROUTING_MODE               claude_critical / save_claude / protect_codex /
#                              codex_burn / claude_burn / codex_first / claude_first / normal
#   BALANCE_GAP                Claude7d残 - Codex週残（stale時は 0）
#   CDX_AVAILABLE              Codex使用可否 0/1
#   CDX_PROJECTED_AT_RESET     Codex週残のリセット時予測 %
#   CLA_PROJECTED_AT_RESET     Claude週残のリセット時予測 %
aum_decide_routing_mode() {
  local cla7d="${CLA_7D_REM_INT:-100}"
  local cdx5h="${CDX_5H_REM_INT:-100}"
  local cdxwk="${CDX_WEEK_REM_INT:-100}"
  local cdx_fresh="${CDX_RATE_LIMITS_FRESH:-0}"
  local cla_fresh="${CLA_OAUTH_FRESH:-0}"
  local cdx_hrs="${CDX_HOURS_UNTIL_RESET:-168}"
  local cla_hrs="${CLA_7D_HOURS_UNTIL_RESET:-168}"
  local burn="${DAILY_BURN_PCT:-20}"

  # BALANCE_GAP: stale データ時は 0 として扱う（満タン誤認による誤ルーティング防止）
  if [ "$cdx_fresh" = "1" ]; then
    BALANCE_GAP=$(( cla7d - cdxwk ))
  else
    BALANCE_GAP=0
  fi

  # Codex使用可否: 5h残 >= 20% かつ リセット考慮の動的週次閾値以上
  CDX_AVAILABLE=1
  [ "$cdx5h" -lt 20 ] && CDX_AVAILABLE=0
  local cdx_week_thr
  if   [ "$cdx_hrs" -le 24 ]; then cdx_week_thr=3
  elif [ "$cdx_hrs" -le 48 ]; then cdx_week_thr=5
  else                             cdx_week_thr=10
  fi
  [ "$cdxwk" -lt "$cdx_week_thr" ] && CDX_AVAILABLE=0

  # Claude保護閾値（リセットまでの時間でスケール・ceil。floor だと保護閾値が1低くなる #41）
  local cla_crit_thr cla_save_thr
  cla_crit_thr=$(awk "BEGIN{v=5*${cla_hrs}/168; c=int(v); if(v>c)c++; if(c<1)c=1; printf \"%d\", c}")
  cla_save_thr=$(awk "BEGIN{v=15*${cla_hrs}/168; c=int(v); if(v>c)c++; if(c<2)c=2; printf \"%d\", c}")

  # Burn機会検出: リセットまでに使い切れない余剰（projected >= 25）。fresh かつ reset既知時のみ算出
  CDX_PROJECTED_AT_RESET=0; local cdx_burn=0
  if [ "$cdx_fresh" = "1" ] && [ "$cdx_hrs" -gt 0 ]; then
    CDX_PROJECTED_AT_RESET=$(awk "BEGIN{v=${cdxwk}-${cdx_hrs}*${burn}/24; if(v<0)v=0; printf \"%d\", v}")
    [ "$CDX_PROJECTED_AT_RESET" -ge 25 ] && cdx_burn=1
  fi
  CLA_PROJECTED_AT_RESET=0; local cla_burn=0
  if [ "$cla_fresh" = "1" ] && [ "$cla_hrs" -gt 0 ]; then
    CLA_PROJECTED_AT_RESET=$(awk "BEGIN{v=${cla7d}-${cla_hrs}*${burn}/24; if(v<0)v=0; printf \"%d\", v}")
    [ "$CLA_PROJECTED_AT_RESET" -ge 25 ] && cla_burn=1
  fi

  if   [ "$cla7d" -lt "$cla_crit_thr" ]; then
    ROUTING_MODE="claude_critical"  # 緊急: 全力でCodexへ逃がす
  elif [ "$cla7d" -lt "$cla_save_thr" ]; then
    ROUTING_MODE="save_claude"      # Codex最大活用でClaudeを温存
  elif [ "$CDX_AVAILABLE" -eq 0 ]; then
    ROUTING_MODE="protect_codex"    # Codex枯渇 → Claude維持
  elif [ "$cdx_burn" -eq 1 ] && [ "$cla_burn" -eq 0 ]; then
    ROUTING_MODE="codex_burn"       # Codexリセット前に余剰 → ガンガンCodexへ
  elif [ "$cla_burn" -eq 1 ] && [ "$cdx_burn" -eq 0 ]; then
    ROUTING_MODE="claude_burn"      # Claudeリセット前に余剰 → Claude積極使用
  elif [ "$BALANCE_GAP" -gt 10 ]; then
    ROUTING_MODE="claude_first"     # Claude余裕(+10%超) → 余っているClaudeを使いCodex温存
  elif [ "$BALANCE_GAP" -lt -10 ]; then
    ROUTING_MODE="codex_first"      # Codex余裕(-10%超) → 余っているCodexを使いClaude温存
  else
    ROUTING_MODE="normal"           # ±10%以内 → バランス中
  fi
}

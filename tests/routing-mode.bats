#!/usr/bin/env bats
# Tests for aum_decide_routing_mode (Issue #28)
# balance-gap の first モード判定が逆転していた回帰を固定する。
# Run: bats tests/routing-mode.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/routing-mode.sh
  source "$REPO_ROOT/scripts/lib/routing-mode.sh"
}

# 各テストは入力を env で与え、関数を直接呼んで（run はサブシェルで global が見えないため）
# 関数がセットするグローバル ROUTING_MODE / BALANCE_GAP 等を検証する。
# reset_inputs: テスト間の env リークを防ぐため全入力を明示 unset する。
reset_inputs() {
  unset CLA_7D_REM_INT CDX_5H_REM_INT CDX_WEEK_REM_INT \
        CDX_RATE_LIMITS_FRESH CLA_OAUTH_FRESH \
        CDX_HOURS_UNTIL_RESET CLA_7D_HOURS_UNTIL_RESET DAILY_BURN_PCT
  ROUTING_MODE=""; BALANCE_GAP=""
  CDX_AVAILABLE=""; CDX_PROJECTED_AT_RESET=""; CLA_PROJECTED_AT_RESET=""
}

# ─────────────────────────────────────────────────────────────
# 回帰の核: Codex が余っている（gap < -10）→ 余っている Codex を使う = codex_first
# ─────────────────────────────────────────────────────────────
@test "regression #28: Claude56/Codex94 (Codex余裕) -> codex_first, gap=-38" {
  reset_inputs
  CLA_7D_REM_INT=56 CDX_5H_REM_INT=97 CDX_WEEK_REM_INT=94 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=119 CLA_7D_HOURS_UNTIL_RESET=102
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "codex_first" ]
  [ "$BALANCE_GAP" = "-38" ]
}

@test "Claude余裕 (gap > +10) -> claude_first" {
  reset_inputs
  CLA_7D_REM_INT=90 CDX_5H_REM_INT=50 CDX_WEEK_REM_INT=70 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "claude_first" ]
  [ "$BALANCE_GAP" = "20" ]
}

# ─────────────────────────────────────────────────────────────
# ±10% 境界（strict >10 / <-10・境界ちょうどは normal）
# ─────────────────────────────────────────────────────────────
@test "gap == +10 -> normal (境界は first にしない)" {
  reset_inputs
  CLA_7D_REM_INT=80 CDX_5H_REM_INT=60 CDX_WEEK_REM_INT=70 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "normal" ]
  [ "$BALANCE_GAP" = "10" ]
}

@test "gap == +11 -> claude_first" {
  reset_inputs
  CLA_7D_REM_INT=81 CDX_5H_REM_INT=60 CDX_WEEK_REM_INT=70 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "claude_first" ]
}

@test "gap == -10 -> normal (境界は first にしない)" {
  reset_inputs
  CLA_7D_REM_INT=70 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=80 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "normal" ]
  [ "$BALANCE_GAP" = "-10" ]
}

@test "gap == -11 -> codex_first" {
  reset_inputs
  CLA_7D_REM_INT=70 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=81 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "codex_first" ]
}

# ─────────────────────────────────────────────────────────────
# stale データ（Codex未取得）は GAP=0 扱いで誤ルーティングしない
# ─────────────────────────────────────────────────────────────
@test "Codex stale -> BALANCE_GAP=0, normal (満タン誤認しない)" {
  reset_inputs
  CLA_7D_REM_INT=56 CDX_5H_REM_INT=97 CDX_WEEK_REM_INT=94 \
    CDX_RATE_LIMITS_FRESH=0 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=119 CLA_7D_HOURS_UNTIL_RESET=102
  aum_decide_routing_mode
  [ "$BALANCE_GAP" = "0" ]
  [ "$ROUTING_MODE" = "normal" ]
}

# ─────────────────────────────────────────────────────────────
# 保護モード（first より高優先）
# ─────────────────────────────────────────────────────────────
@test "Claude残 < crit閾値 -> claude_critical" {
  reset_inputs
  CLA_7D_REM_INT=3 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=90 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "claude_critical" ]
}

@test "Claude残 < save閾値 -> save_claude" {
  reset_inputs
  CLA_7D_REM_INT=10 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=90 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "save_claude" ]
}

@test "Codex 5h残 < 20% -> protect_codex" {
  reset_inputs
  CLA_7D_REM_INT=80 CDX_5H_REM_INT=10 CDX_WEEK_REM_INT=80 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "protect_codex" ]
}

@test "Codex 週残 < 動的閾値 -> protect_codex" {
  reset_inputs
  CLA_7D_REM_INT=80 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=2 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "protect_codex" ]
}

# ─────────────────────────────────────────────────────────────
# Burn モード（自身の資源を使い切る方向・first より高優先）
# ─────────────────────────────────────────────────────────────
@test "Codexリセット直前で余剰 -> codex_burn, projection実測" {
  reset_inputs
  CLA_7D_REM_INT=80 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=90 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=1 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "codex_burn" ]
  # projected = 90 - 1*20/24 = 89.17 -> %d = 89（burn判定の根拠値を固定・B-5）
  [ "$CDX_PROJECTED_AT_RESET" = "89" ]
  [ "$CLA_PROJECTED_AT_RESET" = "0" ]
}

@test "Claudeリセット直前で余剰 -> claude_burn" {
  reset_inputs
  CLA_7D_REM_INT=90 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=90 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=1
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "claude_burn" ]
}

# ─────────────────────────────────────────────────────────────
# 優先順位の交差（保護 > burn > first を実データで固定・B-4）
# ─────────────────────────────────────────────────────────────
@test "優先順位: Claude critical は gap による codex_first を上書き" {
  reset_inputs
  CLA_7D_REM_INT=3 CDX_5H_REM_INT=97 CDX_WEEK_REM_INT=94 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "claude_critical" ]
}

@test "優先順位: codex_burn は first圏(gap>+10=claude_first)を上書き" {
  reset_inputs
  # gap = 95-80 = +15（本来 claude_first 圏）だが Codex がリセット直前で余剰 → burn が勝つ
  CLA_7D_REM_INT=95 CDX_5H_REM_INT=90 CDX_WEEK_REM_INT=80 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=1 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$BALANCE_GAP" = "15" ]
  [ "$ROUTING_MODE" = "codex_burn" ]
}

@test "優先順位: protect_codex は first圏(gap<-10=codex_first)を上書き" {
  reset_inputs
  # gap = 70-85 = -15（本来 codex_first 圏）だが Codex 5h 枯渇 → protect が勝つ
  CLA_7D_REM_INT=70 CDX_5H_REM_INT=10 CDX_WEEK_REM_INT=85 \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET=168 CLA_7D_HOURS_UNTIL_RESET=168
  aum_decide_routing_mode
  [ "$BALANCE_GAP" = "-15" ]
  [ "$ROUTING_MODE" = "protect_codex" ]
}

# ─────────────────────────────────────────────────────────────
# 入力の頑健性（非数値・空でも abort せず安全側に丸める・A-3）
# ─────────────────────────────────────────────────────────────
@test "非数値入力でも abort せず normal に丸める" {
  reset_inputs
  CLA_7D_REM_INT="N/A" CDX_5H_REM_INT="" CDX_WEEK_REM_INT="oops" \
    CDX_RATE_LIMITS_FRESH=1 CLA_OAUTH_FRESH=1 \
    CDX_HOURS_UNTIL_RESET="x" CLA_7D_HOURS_UNTIL_RESET="y"
  aum_decide_routing_mode
  # 全入力が既定(100/100/100/168/168)へ丸められ gap=0 -> normal
  [ "$ROUTING_MODE" = "normal" ]
  [ "$BALANCE_GAP" = "0" ]
}

# ─────────────────────────────────────────────────────────────
# デフォルト（入力なし）: fresh=0 なので gap=0 -> normal
# ─────────────────────────────────────────────────────────────
@test "入力なし -> normal (安全側)" {
  reset_inputs
  aum_decide_routing_mode
  [ "$ROUTING_MODE" = "normal" ]
  [ "$BALANCE_GAP" = "0" ]
}

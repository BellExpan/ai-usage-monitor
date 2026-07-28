#!/usr/bin/env bats
# Tests for usage-source-selfcheck.sh.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SELF_CHECK="$REPO_ROOT/scripts/usage-source-selfcheck.sh"
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR="$(mktemp -d)"
  export HOME
  HOME="$(mktemp -d)"
  CACHE_DIR="$(bash -c "source '$REPO_ROOT/scripts/lib/cache-path.sh'; echo \"\$AI_USAGE_DIR\"")"
  mkdir -p "$CACHE_DIR" "$HOME/.codex/sessions/2026/07/28"
  CACHE="$CACHE_DIR/cache"
  TODAY="$(date +%Y-%m-%d)"
  YESTERDAY="$(date -v-1d +%Y-%m-%d)"
  FIVE_DAYS_AGO="$(date -v-5d +%Y-%m-%d)"
  NOW="$(date +%s)"
  FUTURE=$(( NOW + 604800 ))
}

teardown() {
  rm -rf "$AI_USAGE_BASE_DIR" "$HOME"
  unset AI_USAGE_BASE_DIR HOME AI_USAGE_SELFCHECK_FORCE_EXCEPTION
}

write_cache() {
  cat > "$CACHE" <<EOF
CLA_OAUTH_FRESH=${1:-1}
CLA_24H_TOKENS=${2:-500}
CDX_24H_TOKENS=${3:-1200}
EOF
}

codex_line() {
  local total="${1:-1200}" wk="${2:-1}" resets="${3:-$FUTURE}"
  if [ "$wk" = "1" ]; then
    printf '{"type":"event_msg","timestamp":"%sT12:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' "$TODAY" "$total" "$resets"
  else
    printf '{"type":"event_msg","timestamp":"%sT12:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' "$TODAY" "$total" "$resets"
  fi
}

@test "正常 cache + 正常セッション -> ok" {
  write_cache 1 500 1200
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/ok.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [ "$output" = "USAGE_SRC_HEALTH=ok" ]
}

@test "活動あり + CDX_24H_TOKENS=0 -> codex_tokens_zero_despite_activity" {
  write_cache 1 500 0
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/activity.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [[ "$output" == *"codex_tokens_zero_despite_activity"* ]]
}

@test "昨日23時台に活動 + 今日は活動なし・トークン0 -> degraded にならない" {
  write_cache 1 0 0
  mkdir -p "$HOME/.codex/sessions/yesterday"
  printf '{"type":"event_msg","timestamp":"%sT23:10:00","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' \
    "$YESTERDAY" "$FUTURE" > "$HOME/.codex/sessions/yesterday/activity.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [ "$output" = "USAGE_SRC_HEALTH=ok" ]
}

@test "WK_AVAILABLE=0 相当のセッション -> rate_limit_schema_drift" {
  write_cache 1 500 1200
  codex_line 1200 0 > "$HOME/.codex/sessions/2026/07/28/short-only.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [[ "$output" == *"rate_limit_schema_drift"* ]]
}

@test "rate_limits イベントが古いだけなら rate_limit_schema_drift にしない" {
  write_cache 1 0 0
  mkdir -p "$HOME/.codex/sessions/old"
  printf '{"type":"event_msg","timestamp":"%sT12:00:00","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":300,"resets_at":%s},"secondary":null}}}\n' \
    "$FIVE_DAYS_AGO" "$FUTURE" > "$HOME/.codex/sessions/old/short-only.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [[ "$output" != *"rate_limit_schema_drift"* ]]
  [ "$output" = "USAGE_SRC_HEALTH=ok" ]
}

@test "CLA_OAUTH_FRESH=0 -> claude_oauth_unavailable" {
  write_cache 0 500 1200
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/ok.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [[ "$output" == *"claude_oauth_unavailable"* ]]
}

@test "自前集計と ccusage 値が 3 倍乖離 -> token_source_mismatch" {
  write_cache 1 500 900
  codex_line 300 1 > "$HOME/.codex/sessions/2026/07/28/mismatch.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [[ "$output" == *"token_source_mismatch"* ]]
}

@test "判定処理が例外を吐いても unknown かつ exit 0" {
  write_cache 1 500 1200
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/ok.jsonl"

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" AI_USAGE_SELFCHECK_FORCE_EXCEPTION=1 bash "$SELF_CHECK"

  [ "$status" -eq 0 ]
  [ "$output" = "USAGE_SRC_HEALTH=unknown" ]
}

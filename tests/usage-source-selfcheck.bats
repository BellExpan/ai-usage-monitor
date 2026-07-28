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
  # 鮮度ゲート（GENERATED_AT が今日 / TIMESTAMP が新しい）を満たす cache を書く。
  # ゲートを満たさないと token 突き合わせ自体が skip され、判定テストが素通りする。
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
GENERATED_AT=${TODAY}T12:00:00+0900
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

# --- PR #38 レビュー指摘（2回目）: stale token cache の誤警報防止 ---
# cache のトークンが stale（取得失敗で前回値を保持した状態）のとき、それは
# 「昨日の today bucket」でありうる。today 基準の native と比較すると必ず乖離し
# token_source_mismatch が誤発火する。stale は「計測が壊れている」ではなく
# 「今回取れなかった」なので、トークン突き合わせ自体を skip する。

write_cache_stale() {
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
GENERATED_AT=${TODAY}T12:00:00+0900
CLA_OAUTH_FRESH=1
CLA_24H_TOKENS=${1:-500}
CDX_24H_TOKENS=${2:-0}
CDX_TOKENS_STALE=${3:-1}
EOF
}

@test "CDX_TOKENS_STALE=1 なら token_source_mismatch を出さない（値が大きく乖離していても）" {
  write_cache_stale 500 999999999 1
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/stale.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"token_source_mismatch"* ]]
}

@test "CDX_TOKENS_STALE=1 なら codex_tokens_zero_despite_activity も出さない" {
  write_cache_stale 500 0 1
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/stale0.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex_tokens_zero_despite_activity"* ]]
}

@test "CDX_TOKENS_STALE=0 なら従来通り検知する（skip が効きすぎない回帰防止）" {
  write_cache_stale 500 0 0
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/fresh0.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex_tokens_zero_despite_activity"* ]]
}

# --- PR #38 レビュー指摘（3回目）: cache 鮮度ゲート / stale フラグの分離 ---

write_cache_dated() {
  # $1: GENERATED_AT の日付 / $2: TIMESTAMP / $3: CDX_24H_TOKENS
  cat > "$CACHE" <<EOF2
TIMESTAMP=${2}
GENERATED_AT=${1}T12:00:00+0900
CLA_OAUTH_FRESH=1
CLA_24H_TOKENS=500
CDX_24H_TOKENS=${3}
EOF2
}

@test "前日生成の cache なら token 突き合わせをしない（誤発火防止）" {
  write_cache_dated "$YESTERDAY" "$(( NOW - 86400 ))" 0
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/oldcache.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex_tokens_zero_despite_activity"* ]]
  [[ "$output" != *"token_source_mismatch"* ]]
}

@test "当日生成でも TIMESTAMP が古すぎる cache なら token 突き合わせをしない" {
  write_cache_dated "$TODAY" "$(( NOW - 100000 ))" 0
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/staleTs.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex_tokens_zero_despite_activity"* ]]
}

@test "当日生成かつ fresh な cache なら従来通り検知する（ゲートが効きすぎない回帰防止）" {
  write_cache_dated "$TODAY" "$NOW" 0
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/freshcache.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex_tokens_zero_despite_activity"* ]]
}

@test "CLA_BLOCKS_STALE=1 だけでは Claude 24h 判定を殺さない（false negative 防止）" {
  cat > "$CACHE" <<EOF2
TIMESTAMP=$NOW
GENERATED_AT=${TODAY}T12:00:00+0900
CLA_OAUTH_FRESH=1
CLA_24H_TOKENS=0
CDX_24H_TOKENS=1200
CLA_BLOCKS_STALE=1
CLA_TOKENS_STALE=0
EOF2
  mkdir -p "$HOME/.claude/projects/x"
  printf '{"timestamp":"%sT12:00:00.000Z"}\n' "$TODAY" > "$HOME/.claude/projects/x/a.jsonl"
  codex_line 1200 1 > "$HOME/.codex/sessions/2026/07/28/blocksstale.jsonl"
  run bash "$SELF_CHECK" --cache "$CACHE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude_tokens_zero_despite_activity"* ]]
}

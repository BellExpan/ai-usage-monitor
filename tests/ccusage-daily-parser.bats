#!/usr/bin/env bats
# Tests for ccusage daily parser.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PARSER="$REPO_ROOT/scripts/lib/parse_ccusage_daily.py"
  TMP_JSON="$(mktemp)"
}

teardown() {
  rm -f "$TMP_JSON"
}

kv() {
  printf '%s\n' "$output" | awk -F= -v k="$1" '$1 == k { print $2; exit }'
}

@test "period key with agents array separates codex and claude" {
  printf '%s\n' \
    '{"daily":[{"agent":"all","period":"2026-07-28","totalTokens":999,"totalCost":9.99,"agents":[{"agent":"claude","totalTokens":100,"totalCost":1.5},{"agent":"codex","totalTokens":200,"totalCost":2.5}]},{"agent":"all","period":"2026-07-27","totalTokens":99,"totalCost":0.99,"agents":[{"agent":"claude","totalTokens":10,"totalCost":0.1},{"agent":"codex","totalTokens":30,"totalCost":0.3}]}]}' \
    > "$TMP_JSON"

  run python3 "$PARSER" --agent codex --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"
  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "200" ]
  [ "$(kv COST_24H)" = "2.5" ]
  [ "$(kv TOKENS_RANGE)" = "230" ]
  [ "$(kv COST_RANGE)" = "2.8" ]
  [ "$(kv KEYSTYLE)" = "period" ]

  run python3 "$PARSER" --agent claude --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"
  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "100" ]
  [ "$(kv COST_24H)" = "1.5" ]
  [ "$(kv TOKENS_RANGE)" = "110" ]
  [ "$(kv COST_RANGE)" = "1.6" ]
  [ "$(kv KEYSTYLE)" = "period" ]
}

@test "date key old format remains readable" {
  printf '%s\n' \
    '{"daily":[{"date":"2026-07-28","agent":"claude","totalTokens":123,"totalCost":1.23},{"date":"2026-07-27","agent":"claude","totalTokens":7,"totalCost":0.07}]}' \
    > "$TMP_JSON"

  run python3 "$PARSER" --agent claude --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"

  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "123" ]
  [ "$(kv COST_24H)" = "1.23" ]
  [ "$(kv TOKENS_RANGE)" = "130" ]
  [ "$(kv COST_RANGE)" = "1.3" ]
  [ "$(kv KEYSTYLE)" = "date" ]
}

@test "agent all without agents array is not mixed into claude or codex" {
  printf '%s\n' \
    '{"daily":[{"period":"2026-07-28","agent":"all","totalTokens":999,"totalCost":9.99}]}' \
    > "$TMP_JSON"

  run python3 "$PARSER" --agent claude --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"
  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "0" ]
  [ "$(kv COST_24H)" = "0.0" ]
  [ "$(kv TOKENS_RANGE)" = "0" ]
  [ "$(kv COST_RANGE)" = "0.0" ]
  [ "$(kv ROWS)" = "1" ]

  run python3 "$PARSER" --agent codex --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"
  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "0" ]
  [ "$(kv TOKENS_RANGE)" = "0" ]
}

@test "rows outside requested range are excluded" {
  printf '%s\n' \
    '{"daily":[{"period":"2026-07-21","agents":[{"agent":"codex","totalTokens":1000,"totalCost":10.0}]},{"period":"2026-07-22","agents":[{"agent":"codex","totalTokens":20,"totalCost":0.2}]},{"period":"2026-07-28","agents":[{"agent":"codex","totalTokens":80,"totalCost":0.8}]},{"period":"2026-07-29","agents":[{"agent":"codex","totalTokens":2000,"totalCost":20.0}]}]}' \
    > "$TMP_JSON"

  run python3 "$PARSER" --agent codex --today 2026-07-28 --since 2026-07-22 < "$TMP_JSON"

  [ "$status" -eq 0 ]
  [ "$(kv TOKENS_24H)" = "80" ]
  [ "$(kv COST_24H)" = "0.8" ]
  [ "$(kv TOKENS_RANGE)" = "100" ]
  [ "$(kv COST_RANGE)" = "1.0" ]
  [ "$(kv ROWS)" = "2" ]
}

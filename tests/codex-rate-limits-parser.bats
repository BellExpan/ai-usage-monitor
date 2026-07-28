#!/usr/bin/env bats
# Tests for Codex rate_limits parser.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PARSER="$REPO_ROOT/scripts/lib/parse_codex_rate_limits.py"
  SESS="$(mktemp -d)"
  mkdir -p "$SESS/2026/07/28"
}

teardown() {
  rm -rf "$SESS"
}

kv() {
  printf '%s\n' "$output" | awk -F= -v k="$1" '$1 == k { print $2; exit }'
}

_legacy_line() {
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

_week_only_line() {
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s},"secondary":null}}}\n' \
    "$1" "$2" "$3"
}

_null_marker_line() {
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}\n' \
    "$1"
}

@test "new schema primary=10080 secondary=null is classified as week_only" {
  _week_only_line "2026-07-28T08:44:00.000Z" 2.0 1785823197 \
    > "$SESS/2026/07/28/001-week-only.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv WK_AVAILABLE)" = "1" ]
  [ "$(kv WK_WINDOW_MIN)" = "10080" ]
  [ "$(kv WK_USED_PCT)" = "2.0" ]
  [ "$(kv WK_RESETS_AT)" = "1785823197" ]
  [ "$(kv P5_AVAILABLE)" = "0" ]
  [ "$(kv SCHEMA)" = "week_only" ]
}

@test "legacy schema primary=300 secondary=10080 is split into short and week" {
  _legacy_line "2026-07-28T08:44:00.000Z" 12.0 1781088377 40.0 1781161744 \
    > "$SESS/2026/07/28/001-legacy.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv P5_AVAILABLE)" = "1" ]
  [ "$(kv P5_USED_PCT)" = "12.0" ]
  [ "$(kv P5_REMAINING_PCT)" = "88.0" ]
  [ "$(kv P5_WINDOW_MIN)" = "300" ]
  [ "$(kv WK_AVAILABLE)" = "1" ]
  [ "$(kv WK_USED_PCT)" = "40.0" ]
  [ "$(kv WK_REMAINING_PCT)" = "60.0" ]
  [ "$(kv WK_WINDOW_MIN)" = "10080" ]
  [ "$(kv SCHEMA)" = "legacy_5h_week" ]
}

@test "only null marker events produce none schema and safe defaults" {
  _null_marker_line "2026-07-28T08:49:00.000Z" \
    > "$SESS/2026/07/28/001-null-marker.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv P5_AVAILABLE)" = "0" ]
  [ "$(kv P5_REMAINING_PCT)" = "100" ]
  [ "$(kv P5_RESETS_AT)" = "0" ]
  [ "$(kv WK_AVAILABLE)" = "0" ]
  [ "$(kv WK_REMAINING_PCT)" = "100" ]
  [ "$(kv WK_RESETS_AT)" = "0" ]
  [ "$(kv FRESH)" = "0" ]
  [ "$(kv SCHEMA)" = "none" ]
}

@test "broken jsonl before a valid event does not discard the file" {
  {
    printf '{ this is a truncated broken line\n'
    _legacy_line "2026-07-28T08:44:00.000Z" 5.0 1781088377 100.0 1781161744
  } > "$SESS/2026/07/28/001-broken-then-valid.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv WK_REMAINING_PCT)" = "0.0" ]
  [ "$(kv WK_RESETS_AT)" = "1781161744" ]
  [ "$(kv SCHEMA)" = "legacy_5h_week" ]
}

@test "remaining percentages are clamped to 0..100" {
  _legacy_line "2026-07-28T08:44:00.000Z" 150.0 1781088377 -5.0 1781161744 \
    > "$SESS/2026/07/28/001-out-of-range.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv P5_REMAINING_PCT)" = "0.0" ]
  [ "$(kv WK_REMAINING_PCT)" = "100.0" ]
}

@test "valid event before a later null marker is still selected" {
  {
    _legacy_line "2026-07-28T08:44:00.000Z" 5.0 1781088377 100.0 1781161744
    _null_marker_line "2026-07-28T08:49:00.000Z"
  } > "$SESS/2026/07/28/001-mixed.jsonl"

  run python3 "$PARSER" "$SESS"

  [ "$status" -eq 0 ]
  [ "$(kv WK_REMAINING_PCT)" = "0.0" ]
  [ "$(kv WK_RESETS_AT)" = "1781161744" ]
}

@test "missing sessions dir does not crash" {
  run python3 "$PARSER" "$SESS/nonexistent"

  [ "$status" -eq 0 ]
  [ "$(kv SCHEMA)" = "none" ]
  [ "$(kv P5_REMAINING_PCT)" = "100" ]
  [ "$(kv WK_REMAINING_PCT)" = "100" ]
}

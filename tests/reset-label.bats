#!/usr/bin/env bats
# Tests for reset_label_from_epoch (Issue #15)
# Run: bats tests/reset-label.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/reset-label.sh
  source "$REPO_ROOT/scripts/lib/reset-label.sh"
  NOW=1781000000
}

# ---- 境界値: 残り時間 ----

@test "exactly 0 seconds (resets_at == now) -> soon" {
  run reset_label_from_epoch "$NOW" "$NOW"
  [ "$output" = "↺soon" ]
}

@test "59 minutes remaining -> <1h (the core bug case)" {
  run reset_label_from_epoch "$(( NOW + 3540 ))" "$NOW"   # 59m
  [ "$output" = "↺<1h" ]
}

@test "58 seconds remaining -> <1h (observed bug reproduction)" {
  run reset_label_from_epoch "$(( NOW + 58 ))" "$NOW"
  [ "$output" = "↺<1h" ]
}

@test "exactly 1 hour remaining -> 1h" {
  run reset_label_from_epoch "$(( NOW + 3600 ))" "$NOW"
  [ "$output" = "↺1h" ]
}

@test "23h59m remaining -> 23h" {
  run reset_label_from_epoch "$(( NOW + 86340 ))" "$NOW"
  [ "$output" = "↺23h" ]
}

@test "exactly 24 hours remaining -> 24h (time unit, not days)" {
  run reset_label_from_epoch "$(( NOW + 86400 ))" "$NOW"
  [ "$output" = "↺24h" ]
}

@test "167 hours remaining (Codex weekly max-ish) -> 167h" {
  run reset_label_from_epoch "$(( NOW + 167*3600 ))" "$NOW"
  [ "$output" = "↺167h" ]
}

# ---- データラグ・未知 ----

@test "resets_at in the past (cache lag) -> soon" {
  run reset_label_from_epoch "$(( NOW - 100 ))" "$NOW"
  [ "$output" = "↺soon" ]
}

@test "resets_at == 0 (unknown / no data) -> hidden (empty)" {
  run reset_label_from_epoch 0 "$NOW"
  [ -z "$output" ]
}

@test "resets_at unset defaults to 0 -> hidden" {
  run reset_label_from_epoch "" "$NOW"
  [ -z "$output" ]
}

# ---- 汚染値ガード ----

@test "non-numeric resets_at is treated as unknown -> hidden" {
  run reset_label_from_epoch "abc" "$NOW"
  [ -z "$output" ]
}

@test "dash-mixed resets_at is treated as unknown -> hidden (no math error)" {
  run reset_label_from_epoch "12-" "$NOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "dash-mixed now is treated as 0 -> no math error" {
  run reset_label_from_epoch "$(( NOW + 36000 ))" "1-2-3"
  [ "$status" -eq 0 ]
  [[ "$output" == ↺*h ]]
}

@test "non-numeric now is treated as 0 -> shows full hours" {
  # now=0 扱い → secs = resets_at(=NOW+10h) - 0 = 巨大 → Nh で出る（クラッシュしない）
  run reset_label_from_epoch "$(( NOW + 36000 ))" "garbage"
  [ "$status" -eq 0 ]
  [[ "$output" == ↺*h ]]
}

@test "no crash with both args empty" {
  run reset_label_from_epoch
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # resets_at=0 -> hidden
}

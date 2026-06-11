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

# ---- window_minutes ロールフォワード（Issue #18）----
# resets_at が過去でも window_minutes 既知なら次リセットへ巻き進め、↺soon 固定を解消する。

@test "roll_resets_at_forward: 既に未来なら変更しない" {
  run roll_resets_at_forward "$(( NOW + 36000 ))" "$NOW" 10080
  [ "$output" = "$(( NOW + 36000 ))" ]
}

@test "roll_resets_at_forward: window 不明(0)なら変更しない" {
  run roll_resets_at_forward "$(( NOW - 100 ))" "$NOW" 0
  [ "$output" = "$(( NOW - 100 ))" ]
}

@test "roll_resets_at_forward: 1周期だけ過去 → +1window" {
  # 100s 過去・週枠(10080min=604800s) → +1 window
  run roll_resets_at_forward "$(( NOW - 100 ))" "$NOW" 10080
  [ "$output" = "$(( NOW - 100 + 604800 ))" ]
}

@test "roll_resets_at_forward: 複数周期過去 → 未来に着地（O(1)・巨大ギャップ）" {
  # 3週間+α 過去 → 未来へ。結果は必ず now より大きい
  local past=$(( NOW - 3*604800 - 50 ))
  run roll_resets_at_forward "$past" "$NOW" 10080
  [ "$output" -gt "$NOW" ]
  # 1周期分だけ未来に収まる（過剰に飛ばさない）
  [ "$output" -le "$(( NOW + 604800 ))" ]
}

@test "roll_resets_at_forward: epoch 未知(0)は触らない" {
  run roll_resets_at_forward 0 "$NOW" 10080
  [ "$output" = "0" ]
}

@test "reset_label: 過去 resets_at + window 既知 → soon ではなく ↺Nh" {
  # 100s 過去・週枠 → +604800s ≈ 167h
  run reset_label_from_epoch "$(( NOW - 100 ))" "$NOW" 10080
  [ "$output" = "↺167h" ]
}

@test "reset_label: window 未指定なら従来通り soon（後方互換）" {
  run reset_label_from_epoch "$(( NOW - 100 ))" "$NOW"
  [ "$output" = "↺soon" ]
}

@test "reset_label: 過去 resets_at が window 直後 → 残<1h を正しく表示" {
  # 604700s 過去（604800s window の 100s 手前）→ ロール後 残100s → <1h
  run reset_label_from_epoch "$(( NOW - 604700 ))" "$NOW" 10080
  [ "$output" = "↺<1h" ]
}

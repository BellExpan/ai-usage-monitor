#!/usr/bin/env bats
# Tests for Codex rate_limits parser (Issue #7)
# Run: bats tests/codex-rate-limits-parser.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  PARSER="$REPO_ROOT/scripts/lib/parse_codex_rate_limits.py"
  SESS="$(mktemp -d)"
  mkdir -p "$SESS/2026/06/10"
}

teardown() {
  rm -rf "$SESS"
}

# 有効イベント行: $1=ts $2=p5used $3=p5at $4=wkused $5=wkat
_valid_line() {
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' \
    "$1" "$2" "$3" "$4" "$5"
}

# premium/null マーカー行（週枯渇時に emit される credits 切替イベント）: $1=ts
_premium_null_line() {
  printf '{"type":"event_msg","timestamp":"%s","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}}}\n' \
    "$1"
}

@test "premium/null マーカーをスキップし直近の有効データを採用（週枯渇を正しく検知）" {
  _valid_line "2026-06-10T08:44:00.000Z" 5.0 1781088377 100.0 1781161744 \
    > "$SESS/2026/06/10/001-valid.jsonl"
  _premium_null_line "2026-06-10T08:49:00.000Z" \
    > "$SESS/2026/06/10/002-premium-null.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  # p5u p5r p5at wku wkr wkat fresh
  read -r p5u p5r p5at wku wkr wkat fresh <<< "$output"
  [ "$p5r" = "95.0" ]
  [ "$wkr" = "0.0" ]            # 枯渇を正しく検知（100 ではない = バグ再発防止）
  [ "$wkat" = "1781161744" ]   # resets_at が populated（0 ではない = ↺表示の前提）
  [ "$p5at" = "1781088377" ]
}

@test "有効データのみ: 正しくパースする" {
  _valid_line "2026-06-10T08:44:00.000Z" 12.0 1781088377 40.0 1781161744 \
    > "$SESS/2026/06/10/001-valid.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh p5win wkwin <<< "$output"
  [ "$p5r" = "88.0" ]
  [ "$wkr" = "60.0" ]
  [ "$wkat" = "1781161744" ]
}

@test "window_minutes を出力する（ロールフォワード投影の前提・Issue #18）" {
  _valid_line "2026-06-10T08:44:00.000Z" 12.0 1781088377 40.0 1781161744 \
    > "$SESS/2026/06/10/001-valid.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh p5win wkwin <<< "$output"
  [ "$p5win" = "300" ]      # 5h 枠
  [ "$wkwin" = "10080" ]    # 週枠
}

@test "rate_limits が一切ない: window_minutes も 0 デフォルト（9値出力）" {
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  [ "$output" = "0 100 0 0 100 0 0 0 0" ]
}

@test "window_minutes 欠落イベントでも 0 デフォルトでクラッシュしない" {
  printf '{"type":"event_msg","timestamp":"2026-06-10T08:44:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":30.0,"resets_at":1781088377},"secondary":{"used_percent":40.0,"resets_at":1781161744}}}}\n' \
    > "$SESS/2026/06/10/001-no-window.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh p5win wkwin <<< "$output"
  [ "$p5win" = "0" ]
  [ "$wkwin" = "0" ]
}

@test "rate_limits が一切ない: デフォルト '0 100 0 0 100 0 0 0 0'" {
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  [ "$output" = "0 100 0 0 100 0 0 0 0" ]
}

@test "同一ファイル内で premium/null が有効イベントの後に来ても有効データを採用" {
  {
    _valid_line "2026-06-10T08:44:00.000Z" 5.0 1781088377 100.0 1781161744
    _premium_null_line "2026-06-10T08:49:00.000Z"
  } > "$SESS/2026/06/10/001-mixed.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh <<< "$output"
  [ "$wkr" = "0.0" ]
  [ "$wkat" = "1781161744" ]
}

@test "存在しない sessions_dir: クラッシュせずデフォルト出力" {
  run python3 "$PARSER" "$SESS/nonexistent"
  [ "$status" -eq 0 ]
  [ "$output" = "0 100 0 0 100 0 0 0 0" ]
}

@test "有効イベントの前に壊れ jsonl 行があってもファイルを捨てず採用（RI-1 回帰）" {
  {
    printf '{ this is a truncated broken line\n'
    _valid_line "2026-06-10T08:44:00.000Z" 5.0 1781088377 100.0 1781161744
  } > "$SESS/2026/06/10/001-broken-then-valid.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh <<< "$output"
  [ "$wkr" = "0.0" ]            # 壊れ行で捨てず枯渇を検知（100 にフォールバックしない）
  [ "$wkat" = "1781161744" ]
}

@test "片側のみ非 null（secondary=null）でもクラッシュせず採用側を出力" {
  printf '{"type":"event_msg","timestamp":"2026-06-10T08:44:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":30.0,"window_minutes":300,"resets_at":1781088377},"secondary":null}}}\n' \
    > "$SESS/2026/06/10/001-half-null.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh <<< "$output"
  [ "$p5r" = "70.0" ]
  [ "$p5at" = "1781088377" ]
  # secondary 欠落 → 週枠は安全側デフォルト（残100% / resets_at 0）
  [ "$wkr" = "100.0" ]
  [ "$wkat" = "0" ]
}

@test "残量は [0,100] にクランプ（used_percent 異常値防御・RI-3）" {
  printf '{"type":"event_msg","timestamp":"2026-06-10T08:44:00.000Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":150.0,"window_minutes":300,"resets_at":1781088377},"secondary":{"used_percent":-5.0,"window_minutes":10080,"resets_at":1781161744}}}}\n' \
    > "$SESS/2026/06/10/001-out-of-range.jsonl"
  run python3 "$PARSER" "$SESS"
  [ "$status" -eq 0 ]
  read -r p5u p5r p5at wku wkr wkat fresh <<< "$output"
  [ "$p5r" = "0.0" ]      # 150% used → 残0%（負にしない）
  [ "$wkr" = "100.0" ]    # -5% used → 残100%（超過しない）
}

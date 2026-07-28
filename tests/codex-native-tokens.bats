#!/usr/bin/env bats
# codex_native_tokens.py の集計規約を固定する。
#
# 背景（2026-07-28）: total_token_usage は重複するフィールドを持つ。
#   input_tokens（cached_input_tokens を含む） / output_tokens（reasoning_output_tokens を含む）
#   / total_tokens（= input_tokens + output_tokens）
# 非 cache キーを全部足す実装だと total_tokens とその内訳を二重加算し **約2倍**に膨らむ。
# その結果、健全なデータで cross-check が token_source_mismatch を出し続けた
#（実測 31.3M vs ccusage 14.6M = 2.15x）。誤警報するドリフト検知は無いより悪い（alert fatigue）。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/lib/codex_native_tokens.py"
  SESS="$BATS_TEST_TMPDIR/sessions/2026/07/28"
  mkdir -p "$SESS"
}

# 実際の Codex 出力と同じキー構造でイベントを 1 件書く
write_event() {
  local file="$1" ts="$2" input="$3" cached="$4" output="$5" reasoning="$6" total="$7"
  printf '{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"output_tokens":%s,"reasoning_output_tokens":%s,"total_tokens":%s}}}}\n' \
    "$ts" "$input" "$cached" "$output" "$reasoning" "$total" >> "$file"
}

@test "total_tokens を採用し、内訳との二重加算をしない（2倍膨張の回帰防止）" {
  write_event "$SESS/a.jsonl" "2026-07-28T01:00:00.000Z" 95848 71168 2822 1411 98670
  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"
  [ "$status" -eq 0 ]
  # 98670 のみ。198751（= 95848+2822+1411+98670）になってはいけない
  [[ "$output" == *"TOKENS_TODAY=98670"* ]]
  [[ "$output" != *"TOKENS_TODAY=198751"* ]]
}

@test "セッションごとに最終累計を採用する（イベント毎の累計を足し込まない）" {
  # 同一セッションの累計が 100 → 300 と増える
  write_event "$SESS/b.jsonl" "2026-07-28T01:00:00.000Z" 90 0 10 0 100
  write_event "$SESS/b.jsonl" "2026-07-28T02:00:00.000Z" 270 0 30 0 300
  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"
  [ "$status" -eq 0 ]
  # 最終累計 300 のみ。400（=100+300）になってはいけない
  [[ "$output" == *"TOKENS_TODAY=300"* ]]
}

@test "total_tokens が無い場合は input+output のみを足す（subset を足さない）" {
  printf '{"timestamp":"2026-07-28T03:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":5}}}}\n' \
    > "$SESS/c.jsonl"
  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"
  [ "$status" -eq 0 ]
  # 120 のみ。205（cached/reasoning を足す）や 100+20+80+5 になってはいけない
  [[ "$output" == *"TOKENS_TODAY=120"* ]]
}

@test "別日のイベントは当日集計に含めない" {
  write_event "$SESS/d.jsonl" "2026-07-27T01:00:00.000Z" 900 0 100 0 1000
  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKENS_TODAY=0"* ]]
}

@test "日付境界をまたぐ同一セッションは当日 delta のみを集計する" {
  write_event "$SESS/e.jsonl" "2026-07-27T23:50:00" 900000 0 100000 0 1000000
  write_event "$SESS/e.jsonl" "2026-07-28T00:10:00" 900900 0 100100 0 1001000

  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"

  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKENS_TODAY=1000"* ]]
}

@test "累計が減少した場合は負の delta を加算せず新 baseline にする" {
  write_event "$SESS/f.jsonl" "2026-07-27T23:50:00" 900 0 100 0 1000
  write_event "$SESS/f.jsonl" "2026-07-28T00:10:00" 810 0 90 0 900
  write_event "$SESS/f.jsonl" "2026-07-28T00:20:00" 990 0 110 0 1100

  run python3 "$SCRIPT" --today 2026-07-28 "$SESS"

  [ "$status" -eq 0 ]
  [[ "$output" == *"TOKENS_TODAY=200"* ]]
}

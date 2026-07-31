#!/usr/bin/env bats
# E2E: 実際の scripts/statusline.sh を本物の stdin JSON で走らせ、
#      「終わったのか / bg で動いているのか / 他 terminal のか」が出力に現れることを検証する（Issue #42）。
#
# 単体テスト（statusline-session-scope.bats）は lib の契約を守る。
# こちらは配線（parser → 集計 → 描画）が実際につながっていることを守る。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CLAUDE_TASKS_ROOT CLAUDE_TURN_STATE_DIR
  CLAUDE_TASKS_ROOT="$(mktemp -d)"
  CLAUDE_TURN_STATE_DIR="$(mktemp -d)"

  # 実マシンの $HOME/.local/bin/ai-org-progress（進捗行に ✅ を含む）が
  # 出力に混入すると状態アサートが偽陽性で落ちるため、HOME を空の一時 dir に分離する。
  FAKE_HOME="$(mktemp -d)"

  OWN="aaaa1111-1111-1111-1111-111111111111"
  OTHER="bbbb2222-2222-2222-2222-222222222222"
  mkdir -p "$CLAUDE_TASKS_ROOT/-proj/$OWN/tasks" "$CLAUDE_TASKS_ROOT/-proj/$OTHER/tasks"

  # iTerm2 の実セッションを絶対に触らないよう、存在しない id を入れておく
  FAKE_ITERM="w9t9p9:DEADBEEF-0000-0000-0000-000000000000"
}

teardown() {
  rm -rf "$CLAUDE_TASKS_ROOT" "$CLAUDE_TURN_STATE_DIR" "$FAKE_HOME"
  unset CLAUDE_TASKS_ROOT CLAUDE_TURN_STATE_DIR
}

_set_turn() { printf '%s 1700000000 %s\n' "$1" "$FAKE_ITERM" > "$CLAUDE_TURN_STATE_DIR/turn-$OWN.state"; }
_own_bg()   { : > "$CLAUDE_TASKS_ROOT/-proj/$OWN/tasks/$1.output"; }
_other_bg() { : > "$CLAUDE_TASKS_ROOT/-proj/$OTHER/tasks/$1.output"; }

_run_statusline() {
  local json
  json="{\"session_id\":\"$OWN\",\"workspace\":{\"current_dir\":\"/tmp/ai-org\"},\
\"model\":{\"display_name\":\"Opus 5\"},\
\"context_window\":{\"used_percentage\":42,\"context_window_size\":1000000}}"
  printf '%s' "$json" | HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/statusline.sh" 2>/dev/null \
    | sed $'s/\033\\[[0-9;]*m//g'
}

@test "E2E: turn ended with no bg of its own → shows 完了 (input awaited)" {
  _set_turn idle
  _other_bg b901; _other_bg b902     # 他 terminal は動いていても自分は完了
  run _run_statusline
  [[ "$output" == *"✅ 完了"* ]]
  [[ "$output" != *"🔶"* ]]
  [[ "$output" != *"🔵"* ]]
}

@test "E2E: other terminals' bg tasks are shown separately, not as one's own" {
  _set_turn idle
  _other_bg b901; _other_bg b902
  run _run_statusline
  [[ "$output" == *"他term"* ]]      # 存在は伝える
  [[ "$output" == *"⚡0 bg"* ]]       # だが自分の bg は 0 のまま
}

@test "E2E: turn ended with its own bg → shows it will auto-resume" {
  # statusline.sh の bg 行生成は `stat -f '%m %N'`（BSD 専用書式）に依存するため、
  # Linux CI では bash_count が 0 になり 🔵 判定に到達しない。本 repo は macOS 専用（README 冒頭）。
  # Linux CI では skip する。macOS self-hosted runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  _set_turn idle
  _own_bg b111; _own_bg b222
  run _run_statusline
  [[ "$output" == *"🔶 bg 2"* ]]
  [[ "$output" == *"自動再開"* ]]
}

@test "E2E: turn ended with a running agent bg (symlink) → shows 作業中, not 完了" {
  # 2026-07-31 オーナー実観測の真因その1: agent bg は id 長フィルタで bash_count から
  # 除外され、完了待ちでも「✅ 完了 — 入力待ち」に転倒していた。
  _set_turn idle
  : > "$CLAUDE_TASKS_ROOT/-proj/$OWN/agent-live.jsonl"
  ln -s "$CLAUDE_TASKS_ROOT/-proj/$OWN/agent-live.jsonl" \
        "$CLAUDE_TASKS_ROOT/-proj/$OWN/tasks/a123456789abcdef0.output"
  run _run_statusline
  [[ "$output" == *"🔶 bg 1"* ]]
  [[ "$output" != *"✅ 完了"* ]]
}

@test "E2E: turn running → shows 実行中" {
  _set_turn busy
  run _run_statusline
  [[ "$output" == *"⏳ 実行中"* ]]
}

@test "E2E: permission prompt → shows 要操作" {
  _set_turn wait
  run _run_statusline
  [[ "$output" == *"🔴 要操作"* ]]
}

@test "E2E: no turn-state file → degrades to the previous output (fail-open)" {
  run _run_statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"bg"* ]]
  [[ "$output" != *"✅"* ]]
  [[ "$output" != *"⏳ 実行中"* ]]
}

@test "E2E: without a session id, other-terminal bg is not double counted" {
  # degrade 経路では自分の分を差し引けないため「+N 他term」を出さない
  # （出すと ⚡N と同じファイルを二重に見せることになる）
  _set_turn idle
  _other_bg b901
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp/ai-org\"}}' \
    | bash '$REPO_ROOT/scripts/statusline.sh' 2>/dev/null | sed \$'s/\033\\[[0-9;]*m//g'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"他term"* ]]
}

@test "E2E: no session_id in the payload → still renders (fail-open)" {
  run bash -c "printf '%s' '{\"model\":{\"display_name\":\"Opus 5\"}}' | bash '$REPO_ROOT/scripts/statusline.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

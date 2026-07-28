#!/usr/bin/env bats
# Tests for session-scoped background task counting + turn state banner (Issue #42)
# Run: bats tests/statusline-session-scope.bats
#
# 背景: bg 集計が全セッション再帰だったため、複数 terminal 運用時に
#       「このterminalが終わったのか／bg で動いているのか」を判別できなかった。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/session-state.sh
  source "$REPO_ROOT/scripts/lib/session-state.sh"

  export CLAUDE_TASKS_ROOT CLAUDE_TURN_STATE_DIR
  CLAUDE_TASKS_ROOT="$(mktemp -d)"
  CLAUDE_TURN_STATE_DIR="$(mktemp -d)"

  OWN="aaaaaaaa-1111-1111-1111-111111111111"
  OTHER="bbbbbbbb-2222-2222-2222-222222222222"
  PROJ="$CLAUDE_TASKS_ROOT/-Volumes-proj"
  mkdir -p "$PROJ/$OWN/tasks" "$PROJ/$OTHER/tasks"
}

teardown() {
  rm -rf "$CLAUDE_TASKS_ROOT" "$CLAUDE_TURN_STATE_DIR"
  unset CLAUDE_TASKS_ROOT CLAUDE_TURN_STATE_DIR CLAUDE_BG_FRESH_MINS
}

_age_out() {  # _age_out <file> <minutes-ago>
  touch -t "$(date -v-"$2"M +%Y%m%d%H%M 2>/dev/null || date -d "$2 minutes ago" +%Y%m%d%H%M)" "$1"
}

# ---- tasks dir 解決 ----

@test "session_tasks_dir resolves the dir for the given session id" {
  run session_tasks_dir "$OWN"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ/$OWN/tasks" ]
}

@test "session_tasks_dir is empty for an unknown session id" {
  run session_tasks_dir "cccccccc-3333-3333-3333-333333333333"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session_tasks_dir is empty when session id is empty (fail-open)" {
  run session_tasks_dir ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- 自セッションのみを数える（本 Issue の中核）----

@test "session_bg_count counts only the own session" {
  : > "$PROJ/$OWN/tasks/b111111.output"
  : > "$PROJ/$OTHER/tasks/b222222.output"
  : > "$PROJ/$OTHER/tasks/b333333.output"
  run session_bg_count "$OWN"
  [ "$output" = "1" ]
}

@test "session_other_bg_count counts only the other sessions" {
  : > "$PROJ/$OWN/tasks/b111111.output"
  : > "$PROJ/$OTHER/tasks/b222222.output"
  : > "$PROJ/$OTHER/tasks/b333333.output"
  run session_other_bg_count "$OWN"
  [ "$output" = "2" ]
}

@test "session_bg_count excludes stale outputs beyond the fresh window" {
  : > "$PROJ/$OWN/tasks/fresh.output"
  : > "$PROJ/$OWN/tasks/stale.output"
  _age_out "$PROJ/$OWN/tasks/stale.output" 60
  run session_bg_count "$OWN"
  [ "$output" = "1" ]
}

@test "session_bg_count returns 0 when the tasks root is absent (fail-open)" {
  export CLAUDE_TASKS_ROOT="/nonexistent/path/$$"
  run session_bg_count "$OWN"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "session_bg_count returns 0 for an empty session id (fail-open)" {
  : > "$PROJ/$OWN/tasks/b111111.output"
  run session_bg_count ""
  [ "$output" = "0" ]
}

# ---- ターン状態 ----

@test "turn_state_read returns the recorded state" {
  printf 'busy 1700000000 w1t0p0:XYZ\n' > "$CLAUDE_TURN_STATE_DIR/turn-$OWN.state"
  run turn_state_read "$OWN"
  [ "$output" = "busy" ]
}

@test "turn_state_read returns unknown when no state file exists" {
  run turn_state_read "$OWN"
  [ "$output" = "unknown" ]
}

@test "turn_state_read rejects a garbage state value" {
  printf 'pwned;rm -rf / 1700000000\n' > "$CLAUDE_TURN_STATE_DIR/turn-$OWN.state"
  run turn_state_read "$OWN"
  [ "$output" = "unknown" ]
}

@test "turn_state_iterm_id extracts the iTerm session id" {
  printf 'idle 1700000000 w1t0p0:ABC-123\n' > "$CLAUDE_TURN_STATE_DIR/turn-$OWN.state"
  run turn_state_iterm_id "$OWN"
  [ "$output" = "ABC-123" ]
}

# ---- バナー（終わったのか / bg なのかを 1 目で ）----

@test "turn_banner: idle with no bg means fully done" {
  run turn_banner idle 0
  [[ "$output" == "✅"* ]]
}

@test "turn_banner: idle with bg means it will auto-resume" {
  run turn_banner idle 2
  [[ "$output" == "🔵"* ]]
  [[ "$output" == *"2"* ]]
}

@test "turn_banner: busy means the turn is running" {
  run turn_banner busy 0
  [[ "$output" == "⏳"* ]]
}

@test "turn_banner: wait means the owner must act" {
  run turn_banner wait 0
  [[ "$output" == "🔴"* ]]
}

@test "turn_banner: unknown state renders nothing (fail-open)" {
  run turn_banner unknown 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---- タイトル生成 ----

@test "session_title composes an at-a-glance tab title" {
  run session_title idle 0 "ai-org"
  [[ "$output" == "✅ ai-org" ]]
}

@test "session_title includes the bg count when bg is running" {
  run session_title idle 3 "ai-org"
  [[ "$output" == *"ai-org"* ]]
  [[ "$output" == *"3"* ]]
  [[ "$output" == "🔵"* ]]
}

@test "session_title strips quotes and control chars (AppleScript injection)" {
  run session_title idle 0 "$(printf 'ev"il\\ x')"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"'* ]]
  [[ "$output" != *'\'* ]]
}

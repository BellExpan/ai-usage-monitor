#!/usr/bin/env bats
# Tests for hooks/turn-state.sh (Issue #42)

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  HOOK="$REPO_ROOT/hooks/turn-state.sh"
  export CLAUDE_TURN_STATE_DIR
  CLAUDE_TURN_STATE_DIR="$(mktemp -d)"
  SID="aaaa1111-1111-1111-1111-111111111111"
  JSON="{\"session_id\":\"$SID\",\"cwd\":\"/tmp/x\"}"
}

teardown() {
  rm -rf "$CLAUDE_TURN_STATE_DIR"
  unset CLAUDE_TURN_STATE_DIR
}

_state_of() { LC_ALL=C awk 'NR==1{print $1}' "$CLAUDE_TURN_STATE_DIR/turn-$SID.state"; }

@test "records busy" {
  printf '%s' "$JSON" | bash "$HOOK" busy
  [ "$(_state_of)" = "busy" ]
}

@test "records idle" {
  printf '%s' "$JSON" | bash "$HOOK" idle
  [ "$(_state_of)" = "idle" ]
}

@test "records wait" {
  printf '%s' "$JSON" | bash "$HOOK" wait
  [ "$(_state_of)" = "wait" ]
}

@test "records the iTerm session id as the third field" {
  ITERM_SESSION_ID="w2t0p0:ABC-123" bash -c "printf '%s' '$JSON' | bash '$HOOK' idle"
  [ "$(LC_ALL=C awk 'NR==1{print $3}' "$CLAUDE_TURN_STATE_DIR/turn-$SID.state")" = "w2t0p0:ABC-123" ]
}

@test "unknown state argument is a no-op" {
  printf '%s' "$JSON" | bash "$HOOK" bogus
  [ ! -e "$CLAUDE_TURN_STATE_DIR/turn-$SID.state" ]
}

@test "missing session_id is a no-op (fail-open)" {
  run bash -c "printf '%s' '{}' | bash '$HOOK' idle"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$CLAUDE_TURN_STATE_DIR")" ]
}

@test "session_id with path traversal cannot escape the state dir" {
  run bash -c "printf '%s' '{\"session_id\":\"../../etc/pwned\"}' | bash '$HOOK' idle"
  [ "$status" -eq 0 ]
  [ ! -e /etc/pwned.state ]
  # サニタイズ後も state dir 直下に 1 ファイルだけ
  [ "$(ls -1 "$CLAUDE_TURN_STATE_DIR" | wc -l | tr -d ' ')" -le 1 ]
}

@test "repeated same state does not rewrite the file (PreToolUse cost guard)" {
  # 書き込みのたびに 2 列目の epoch が更新されるため、epoch 据え置き＝再書き込みなし。
  # stat の書式指定は BSD/GNU で非互換なので、ファイル内容で判定する（Linux CI でも動く）。
  printf '%s' "$JSON" | bash "$HOOK" busy
  local before after
  before="$(LC_ALL=C awk 'NR==1{print $2}' "$CLAUDE_TURN_STATE_DIR/turn-$SID.state")"
  sleep 1
  printf '%s' "$JSON" | bash "$HOOK" busy
  after="$(LC_ALL=C awk 'NR==1{print $2}' "$CLAUDE_TURN_STATE_DIR/turn-$SID.state")"
  [ "$before" = "$after" ]
}

@test "state transition does rewrite the file" {
  printf '%s' "$JSON" | bash "$HOOK" busy
  printf '%s' "$JSON" | bash "$HOOK" idle
  [ "$(_state_of)" = "idle" ]
}

@test "always exits 0 even when the state dir is not writable (fail-open)" {
  export CLAUDE_TURN_STATE_DIR=/dev/null/nope
  run bash -c "printf '%s' '$JSON' | bash '$HOOK' idle"
  [ "$status" -eq 0 ]
}

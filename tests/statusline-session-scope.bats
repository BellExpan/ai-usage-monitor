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

# ---- タブ名（Claude Code の会話タイトルに前置する）----

@test "state_glyph maps each state" {
  run state_glyph idle 0; [ "$output" = "✅" ]
  run state_glyph idle 3; [ "$output" = "🔵3" ]
  run state_glyph busy 0; [ "$output" = "⏳" ]
  run state_glyph wait 0; [ "$output" = "🔴" ]
}

@test "state_glyph renders nothing for unknown (fail-open)" {
  run state_glyph unknown 0
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "strip_state_prefix removes an existing glyph (no double prefixing)" {
  run strip_state_prefix "⏳ CrispPage v1 出荷準備"
  [ "$output" = "CrispPage v1 出荷準備" ]
  run strip_state_prefix "🔵12 SnoreReel"
  [ "$output" = "SnoreReel" ]
}

@test "strip_state_prefix leaves an unprefixed name untouched" {
  run strip_state_prefix "⠐ CrispPage v1 出荷準備"
  [ "$output" = "⠐ CrispPage v1 出荷準備" ]
}

@test "strip_job_suffix removes the iTerm job name (no (caffeinate)(caffeinate))" {
  run strip_job_suffix "⠐ CrispPage v1 出荷準備 (caffeinate)"
  [ "$output" = "⠐ CrispPage v1 出荷準備" ]
}

@test "strip_job_suffix has a known limitation: a short trailing (token) is also stripped" {
  # iTerm2 は job 名を単独取得できないため形で判定するしかなく、
  # "(v2)" のような会話タイトル末尾も剥がれる。表示上その token が消えるのみ（既知・許容）。
  run strip_job_suffix "SnoreReel (v2)"
  [ "$output" = "SnoreReel" ]
}

@test "strip_job_suffix keeps parenthesised text that is not a job suffix" {
  run strip_job_suffix "CrispPage (v1 出荷)"
  [ "$output" = "CrispPage (v1 出荷)" ]
}

@test "prefix composition is idempotent across repeated applications" {
  local n="⠐ CrispPage v1 出荷準備 (caffeinate)"
  n="$(strip_state_prefix "$(strip_job_suffix "$n")")"
  n="⏳ $n"
  # 2 回目: 既存 glyph を剥がしてから付け直す → 多重化しない
  local again
  again="⏳ $(strip_state_prefix "$(strip_job_suffix "$n")")"
  [ "$again" = "⏳ ⠐ CrispPage v1 出荷準備" ]
  [ "$again" = "$n" ]
}

@test "iterm_apply_state_prefix is a no-op for an empty glyph or id (fail-open)" {
  run iterm_apply_state_prefix "" "ABC-123"
  [ "$status" -eq 0 ]
  run iterm_apply_state_prefix "⏳" ""
  [ "$status" -eq 0 ]
}

@test "iterm_get_name sanitizes its id (no AppleScript injection)" {
  run iterm_get_name '"; do shell script "touch /tmp/pwned"; --'
  [ "$status" -eq 0 ]
  [ ! -e /tmp/pwned ]
}

# ---- ウィンドウタイトル（1窓1タブでタブバーが隠れる環境向け・Issue #51）----

@test "strip_cc_marker removes the Claude Code idle marker" {
  run strip_cc_marker "✳ CrispPage の完成状況確認"
  [ "$output" = "CrispPage の完成状況確認" ]
}

@test "strip_cc_marker leaves a braille spinner frame alone (busy only; we never write then)" {
  # 点字スピナーは実行中にしか出ず、実行中は window_title_apply が書かないので剥がす必要がない。
  # マルチバイト文字クラスは GNU sed / C ロケールで動かず Linux CI が落ちたため対象外にした。
  run strip_cc_marker "⠐ CrispPage v1 出荷準備"
  [ "$output" = "⠐ CrispPage v1 出荷準備" ]
}

@test "strip_cc_marker leaves a plain title untouched" {
  run strip_cc_marker "CrispPage v1 出荷準備"
  [ "$output" = "CrispPage v1 出荷準備" ]
}

@test "window_title_apply does nothing while busy (leaves the spinner alone)" {
  run window_title_apply busy 0 "ABC-123"
  [ "$status" -eq 0 ]
}

@test "window_title_apply does nothing for unknown state (fail-open)" {
  run window_title_apply unknown 0 "ABC-123"
  [ "$status" -eq 0 ]
}

@test "window_title_apply is a no-op without an iterm session id (fail-open)" {
  run window_title_apply idle 0 ""
  [ "$status" -eq 0 ]
}

@test "iterm_tty sanitizes its id (no AppleScript injection)" {
  run iterm_tty '"; do shell script "touch /tmp/pwned2"; --'
  [ "$status" -eq 0 ]
  [ ! -e /tmp/pwned2 ]
}

@test "window_title_apply refuses a tty path outside /dev/tty* (Codex #52)" {
  # iterm_tty を差し替えて任意パスを返させる → 書き込まれないこと
  iterm_tty() { printf '%s' "$CLAUDE_TURN_STATE_DIR/evil.txt"; }
  iterm_window_name() { printf '✳ topic'; }
  : > "$CLAUDE_TURN_STATE_DIR/evil.txt"
  run window_title_apply idle 0 "ABC-123"
  [ "$status" -eq 0 ]
  [ ! -s "$CLAUDE_TURN_STATE_DIR/evil.txt" ]   # 空のまま＝書き込まれていない
}

@test "window_title_apply refuses a non-character-device under /dev (Codex #52)" {
  iterm_tty() { printf '/dev/null/nope'; }
  iterm_window_name() { printf '✳ topic'; }
  run window_title_apply idle 0 "ABC-123"
  [ "$status" -eq 0 ]
}

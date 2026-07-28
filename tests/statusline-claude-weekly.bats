#!/usr/bin/env bats
# Tests for Claude 1w (週次) が statusline に常に表示されること
# Run: bats tests/statusline-claude-weekly.bats
#
# 背景: Claude の週次残量は stdin JSON には来ず（実 stdin は five_hour のみ）、
# 必ずキャッシュ（CLA_7D_REMAINING_PCT）依存。macOS の temp dir は定期的に
# クリアされるため「cache 不在」は常態。Codex は CDX_WEEK_REMAINING_PCT を
# :-100 で default するため 1w が常に出るが、Claude には週次フォールバックが
# 無く、cache 不在の瞬間に 1w だけ静かに消えていた（owner 報告: 1w 未表示）。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STATUSLINE="$REPO_ROOT/scripts/statusline.sh"
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR="$(mktemp -d)"
  CACHE_DIR="$(bash -c "source '$REPO_ROOT/scripts/lib/cache-path.sh'; echo \"\$AI_USAGE_DIR\"")"
  mkdir -p "$CACHE_DIR"
  CACHE="$CACHE_DIR/cache"
  NOW="$(date +%s)"
}

teardown() {
  rm -rf "$AI_USAGE_BASE_DIR"
  unset AI_USAGE_BASE_DIR
}

# stdin は Claude Code が実際に渡す形（five_hour のみ・weekly なし）
_STDIN='{"model":{"display_name":"Claude Opus 4.8"},"context_window":{"used_percentage":5,"context_window_size":1000000},"rate_limits":{"five_hour":{"used_percentage":0}}}'

# ANSI 除去して Claude セグメント（Claude:... の塊）を取り出す
_claude_seg() {
  echo "$_STDIN" | bash "$STATUSLINE" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'Claude:[^ ]+' | head -1
}

@test "cache 不在でも Claude 1w が表示される（バグ再現の本丸）" {
  rm -f "$CACHE"   # cache を消す（temp dir クリア直後を再現）
  run _claude_seg
  [[ "$output" == *"5h"* ]]
  [[ "$output" == *"1w"* ]]    # 1w が消えない
}

@test "cache 不在でも integer expected 等の stderr エラーを吐かない" {
  rm -f "$CACHE"
  run bash -c "echo '$_STDIN' | bash '$STATUSLINE' 2>&1 1>/dev/null"
  [[ "$output" != *"integer expected"* ]]
  [[ "$output" != *"行:"* ]]
  [[ "$output" != *"line "* ]]
}

@test "cache あり（CLA_7D_REMAINING_PCT）→ 実値の 1w を表示" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
CLA_OAUTH_FRESH=1
CDX_RATE_LIMITS_FRESH=1
CLA_5H_REMAINING_PCT=99
CLA_7D_REMAINING_PCT=88
CLA_7D_SONNET_REMAINING_PCT=99
CLA_7D_RESETS_AT=$(( NOW + 125*3600 ))
ROUTING_MODE=normal
EOF
  run _claude_seg
  [[ "$output" == *"5h99%"* ]]
  [[ "$output" == *"1w88%"* ]]
  [[ "$output" == *"Snt1w99%"* ]]
}

@test "USAGE_SRC_HEALTH degraded -> statusline に ⚠src が出る" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
CLA_OAUTH_FRESH=1
CDX_RATE_LIMITS_FRESH=1
CLA_5H_REMAINING_PCT=99
CLA_7D_REMAINING_PCT=88
CLA_7D_SONNET_REMAINING_PCT=77
CDX_5H_REMAINING_PCT=66
CDX_WEEK_REMAINING_PCT=55
USAGE_SRC_HEALTH=degraded:token_source_mismatch
ROUTING_MODE=normal
EOF
  run bash -c "echo '$_STDIN' | AI_USAGE_BASE_DIR='$AI_USAGE_BASE_DIR' bash '$STATUSLINE' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'"
  [[ "$output" == *"⚠src"* ]]
}

@test "CLA_OAUTH_FRESH=0 -> 5h? 表示になり 100% にならない" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
CLA_OAUTH_FRESH=0
CDX_RATE_LIMITS_FRESH=1
CLA_5H_REMAINING_PCT=100
CLA_7D_REMAINING_PCT=100
CLA_7D_SONNET_REMAINING_PCT=100
CDX_5H_REMAINING_PCT=66
CDX_WEEK_REMAINING_PCT=55
ROUTING_MODE=normal
EOF
  run _claude_seg
  [[ "$output" == *"5h?"* ]]
  [[ "$output" == *"1w?"* ]]
  [[ "$output" != *"100%"* ]]
}

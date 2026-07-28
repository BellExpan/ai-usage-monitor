#!/usr/bin/env bats
# Tests that cache-update.sh preserves previous values on upstream failures.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CACHE_UPDATE="$REPO_ROOT/scripts/cache-update.sh"
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR="$(mktemp -d)"
  export HOME
  HOME="$(mktemp -d)"
  NODE_BIN="$HOME/.nvm/versions/node/v99/bin"
  mkdir -p "$NODE_BIN" "$HOME/.codex/sessions/2026/07/28"
  CACHE_DIR="$(bash -c "source '$REPO_ROOT/scripts/lib/cache-path.sh'; echo \"\$AI_USAGE_DIR\"")"
  mkdir -p "$CACHE_DIR"
  CACHE="$CACHE_DIR/cache"
  TODAY="$(date +%Y-%m-%d)"
  export AUM_TEST_TODAY="$TODAY"
  FUTURE=$(( $(date +%s) + 604800 ))
  cat > "$HOME/.codex/sessions/2026/07/28/rate.jsonl" <<EOF
{"type":"event_msg","timestamp":"${TODAY}T12:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":111}},"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":$FUTURE},"secondary":null}}}
EOF
  write_stubs
}

teardown() {
  rm -rf "$AI_USAGE_BASE_DIR" "$HOME"
  unset AI_USAGE_BASE_DIR HOME AUM_TEST_TODAY AUM_CCUSAGE_FAIL
  unset AUM_CCUSAGE_EMPTY
}

write_stubs() {
  cat > "$NODE_BIN/security" <<'EOF'
#!/bin/bash
exit 1
EOF
  cat > "$NODE_BIN/curl" <<'EOF'
#!/bin/bash
exit 22
EOF
  cat > "$NODE_BIN/claude" <<'EOF'
#!/bin/bash
echo "claude 2.1.0"
EOF
  cat > "$NODE_BIN/codex" <<'EOF'
#!/bin/bash
echo "codex 0.1.0"
EOF
  cat > "$NODE_BIN/npx" <<'EOF'
#!/bin/bash
if printf '%s\n' "$*" | grep -q "blocks"; then
  echo '{"blocks":[{"isActive":true,"totalTokens":222,"endTime":"2026-07-28T17:00:00Z"}]}'
  exit 0
fi
if [ "${AUM_CCUSAGE_FAIL:-0}" = "1" ]; then
  echo '{"daily":[]}'
  exit 42
fi
if [ "${AUM_CCUSAGE_EMPTY:-0}" = "1" ]; then
  echo '{"daily":[]}'
  exit 0
fi
cat <<JSON
{"daily":[{"period":"${AUM_TEST_TODAY}","agents":[{"agent":"claude","totalTokens":333,"totalCost":0.33},{"agent":"codex","totalTokens":111,"totalCost":0.11}]}]}
JSON
EOF
  chmod +x "$NODE_BIN/security" "$NODE_BIN/curl" "$NODE_BIN/claude" "$NODE_BIN/codex" "$NODE_BIN/npx"
}

@test "既存 cache がある状態で OAuth 取得失敗 -> 前回残量保持 + CLA_VALUES_STALE=1" {
  # cache-update.sh は macOS 前提（Keychain / BSD date -v / DARWIN_USER_TEMP_DIR）。
  # Linux CI では skip する。macOS runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  cat > "$CACHE" <<EOF
TIMESTAMP=1
CLA_OAUTH_FRESH=1
CLA_5H_USED_PCT=58
CLA_5H_REMAINING_PCT=42
CLA_7D_USED_PCT=67
CLA_7D_REMAINING_PCT=33
CLA_7D_SONNET_USED_PCT=75
CLA_7D_SONNET_REMAINING_PCT=25
CLA_5H_RESETS_AT=$FUTURE
CLA_7D_RESETS_AT=$FUTURE
EOF

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$CACHE_UPDATE"

  [ "$status" -eq 0 ]
  run grep -E '^(CLA_5H_REMAINING_PCT|CLA_7D_REMAINING_PCT|CLA_7D_SONNET_REMAINING_PCT|CLA_VALUES_STALE)=' "$CACHE"
  [[ "$output" == *"CLA_5H_REMAINING_PCT=42"* ]]
  [[ "$output" == *"CLA_7D_REMAINING_PCT=33"* ]]
  [[ "$output" == *"CLA_7D_SONNET_REMAINING_PCT=25"* ]]
  [[ "$output" == *"CLA_VALUES_STALE=1"* ]]
}

@test "ccusage daily が exit 0 かつ daily:[] -> トークン 0 を書き stale にしない" {
  # cache-update.sh は macOS 前提（Keychain / BSD date -v / DARWIN_USER_TEMP_DIR）。
  # Linux CI では skip する。macOS runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  cat > "$CACHE" <<EOF
TIMESTAMP=1
CLA_OAUTH_FRESH=1
CLA_24H_TOKENS=444
CDX_24H_TOKENS=777
EOF

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" AUM_CCUSAGE_EMPTY=1 bash "$CACHE_UPDATE"

  [ "$status" -eq 0 ]
  run grep -E '^(CLA_24H_TOKENS|CDX_24H_TOKENS|CLA_TOKENS_STALE|CDX_TOKENS_STALE)=' "$CACHE"
  [[ "$output" == *"CLA_24H_TOKENS=0"* ]]
  [[ "$output" == *"CDX_24H_TOKENS=0"* ]]
  [[ "$output" == *"CLA_TOKENS_STALE=0"* ]]
  [[ "$output" == *"CDX_TOKENS_STALE=0"* ]]
}

@test "ccusage daily が非ゼロ終了 -> トークンが 0 に化けず前回値保持 + CDX_TOKENS_STALE=1" {
  # cache-update.sh は macOS 前提（Keychain / BSD date -v / DARWIN_USER_TEMP_DIR）。
  # Linux CI では skip する。macOS runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  cat > "$CACHE" <<EOF
TIMESTAMP=1
CLA_OAUTH_FRESH=1
CLA_24H_TOKENS=444
CLA_24H_COST=4.44
CLA_7D_TOKENS=555
CLA_7D_COST=5.55
CDX_24H_TOKENS=777
CDX_24H_COST=7.77
CDX_WEEK_TOKENS=888
CDX_WEEK_COST=8.88
EOF

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" AUM_CCUSAGE_FAIL=1 bash "$CACHE_UPDATE"

  [ "$status" -eq 0 ]
  run grep -E '^(CDX_24H_TOKENS|CDX_WEEK_TOKENS|CDX_TOKENS_STALE|CLA_24H_TOKENS)=' "$CACHE"
  [[ "$output" == *"CDX_24H_TOKENS=777"* ]]
  [[ "$output" == *"CDX_WEEK_TOKENS=888"* ]]
  [[ "$output" == *"CLA_24H_TOKENS=444"* ]]
  [[ "$output" == *"CDX_TOKENS_STALE=1"* ]]
}

@test "破損した数値 cache は復元せず awk エラーなしで既定値を使う" {
  # cache-update.sh は macOS 前提（Keychain / BSD date -v / DARWIN_USER_TEMP_DIR）。
  # Linux CI では skip する。macOS runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  cat > "$CACHE" <<EOF
TIMESTAMP=1
CLA_5H_REMAINING_PCT=abc
EOF

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" HOME="$HOME" bash "$CACHE_UPDATE"

  [ "$status" -eq 0 ]
  run grep -E '^(CLA_5H_REMAINING_PCT|CLA_5H_REMAINING_MINS|CLA_VALUES_STALE)=' "$CACHE"
  [[ "$output" == *"CLA_5H_REMAINING_PCT=100"* ]]
  [[ "$output" == *"CLA_5H_REMAINING_MINS=300"* ]]
  [[ "$output" == *"CLA_VALUES_STALE=0"* ]]
}

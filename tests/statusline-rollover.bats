#!/usr/bin/env bats
# Tests for statusline Codex リセット ロールオーバー投影（Issue #18）
# Run: bats tests/statusline-rollover.bats
#
# 検証対象: cache の resets_at が過去（= ウィンドウ周期リセット済みだが Codex 未使用で
# fresh データが来ない）状況で、statusline が「↺soon + 残stale」固定ではなく
# 次リセット（↺Nh）+ fresh（残100%）を投影して描画すること。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  STATUSLINE="$REPO_ROOT/scripts/statusline.sh"
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR="$(mktemp -d)"
  # cache パスを解決して cache ファイルを用意
  CACHE_DIR="$(bash -c "source '$REPO_ROOT/scripts/lib/cache-path.sh'; echo \"\$AI_USAGE_DIR\"")"
  mkdir -p "$CACHE_DIR"
  CACHE="$CACHE_DIR/cache"
  NOW="$(date +%s)"
}

teardown() {
  rm -rf "$AI_USAGE_BASE_DIR"
  unset AI_USAGE_BASE_DIR
}

# ANSI 除去して Codex セグメント（残%と ↺ラベル）を取り出す
_codex_seg() {
  echo '{}' | bash "$STATUSLINE" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'Codex:[^ ]+ ↺[^ ]+' | head -1
}

@test "週枯渇 + 過去 resets_at → 1w100% ↺Nh に投影（バグ再現の本丸）" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$(( NOW - 100 ))
CDX_5H_REMAINING_PCT=99
CDX_5H_RESETS_AT=$(( NOW + 3600 ))
CDX_5H_WINDOW_MIN=300
CDX_WEEK_REMAINING_PCT=0
CDX_WEEK_RESETS_AT=$(( NOW - 100 ))
CDX_WEEK_WINDOW_MIN=10080
CDX_RATE_LIMITS_FRESH=1
ROUTING_MODE=normal
EOF
  run _codex_seg
  [[ "$output" == *"1w100%"* ]]   # 残stale(0%)ではなく fresh
  [[ "$output" == *"↺"*"h"* ]]    # ↺soon ではなく時間表示
  [[ "$output" != *"↺soon"* ]]
}

@test "旧 cache 形式（window 変数なし）でも fallback で投影される" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$(( NOW - 100 ))
CDX_5H_REMAINING_PCT=99
CDX_5H_RESETS_AT=$(( NOW + 3600 ))
CDX_WEEK_REMAINING_PCT=0
CDX_WEEK_RESETS_AT=$(( NOW - 100 ))
CDX_RATE_LIMITS_FRESH=1
ROUTING_MODE=normal
EOF
  run _codex_seg
  [[ "$output" == *"1w100%"* ]]
  [[ "$output" != *"↺soon"* ]]
}

@test "正常系（未来 resets_at）は投影せずそのまま表示（回帰防止）" {
  cat > "$CACHE" <<EOF
TIMESTAMP=$NOW
CDX_5H_REMAINING_PCT=82
CDX_5H_RESETS_AT=$(( NOW + 3*3600 ))
CDX_5H_WINDOW_MIN=300
CDX_WEEK_REMAINING_PCT=97
CDX_WEEK_RESETS_AT=$(( NOW + 167*3600 ))
CDX_WEEK_WINDOW_MIN=10080
CDX_RATE_LIMITS_FRESH=1
ROUTING_MODE=normal
EOF
  run _codex_seg
  [[ "$output" == *"1w97%"* ]]    # 97% のまま（100% に化けない）
  [[ "$output" == *"↺167h"* ]]
}

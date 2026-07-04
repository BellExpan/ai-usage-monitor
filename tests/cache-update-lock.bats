#!/usr/bin/env bats
# Tests for cache-update.sh self-lock (Issue #24)
# lock 所有権が cache-update.sh に集約され、ロック保持中は API 実行前に skip する
# （launchd 定期実行と SessionStart hook の二重更新防止 + lock leak 解消）ことを検証する。
# dead-pid の stale 掃除ロジック自体は session-start-lock.bats がインライン検証済み。
# ここでは network に到達しない skip 経路のみを決定的にテストする。
# Run: bats tests/cache-update-lock.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR=$(mktemp -d)
  # shellcheck source=../scripts/lib/cache-path.sh
  source "$REPO_ROOT/scripts/lib/cache-path.sh"
  init_cache_dir
  rm -rf "$LOCK_DIR"
}

teardown() {
  rm -rf "$LOCK_DIR"
  rm -rf "$AI_USAGE_BASE_DIR"
  unset AI_USAGE_BASE_DIR
}

# ロックが生きた PID で保持されている間は、cache-update.sh が API 実行前に exit 0 し
# キャッシュを書かない（二重更新防止）。self PID を書くので stale 掃除もされない。
# lock 取得は init_cache_dir 直後・全 API より前にあるため network に到達しない。
@test "cache-update skips (exit 0, no cache write) when lock held by live pid" {
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"      # 自分自身 = 生きている PID
  [ ! -f "$CACHE_FILE" ]         # 前提: cache 未作成

  run env AI_USAGE_BASE_DIR="$AI_USAGE_BASE_DIR" bash "$REPO_ROOT/scripts/cache-update.sh"
  [ "$status" -eq 0 ]            # skip は正常終了
  [ ! -f "$CACHE_FILE" ]         # API に到達せず cache を書いていない
  [ -d "$LOCK_DIR" ]             # 他者のロックを奪っていない
  run cat "$LOCK_DIR/pid"
  [ "$output" = "$$" ]           # ロック保持者は変わっていない
}

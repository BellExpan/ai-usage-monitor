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
  # macOS 依存（BSD stat の mtime 粒度 / ps の出力形式 / launchd plist）。
  # Linux CI では skip する。macOS self-hosted runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
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

# プロセス同一性判定（起動時刻）: 同一 live プロセスは stale 扱いしない（time-independent）。
# cache-update.sh の stale 判定ロジックをインラインで再現して検証する。
_is_stale() {
  local pid start cur
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  start=$(cat "$LOCK_DIR/start" 2>/dev/null)
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    cur=$(ps -o lstart= -p "$pid" 2>/dev/null)
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    if [ -n "$start" ] && [ "$cur" != "$start" ]; then return 0; fi
  fi
  return 1
}

@test "same live process (matching start) is NOT stale regardless of time" {
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"
  ps -o lstart= -p $$ > "$LOCK_DIR/start" 2>/dev/null || skip "ps unavailable in this sandbox"
  run _is_stale
  [ "$status" -ne 0 ]            # not stale
}

@test "reused pid (mismatching start) IS stale" {
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"
  echo "Mon Jan  1 00:00:00 2001" > "$LOCK_DIR/start"   # 実際の起動時刻と不一致
  run _is_stale
  [ "$status" -eq 0 ]            # stale（別プロセスが pid を再利用したと判定）
}

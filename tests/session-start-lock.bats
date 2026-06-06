#!/usr/bin/env bats
# Tests for session-start.sh lock logic (Issue #17)
# Run: bats tests/session-start-lock.bats

setup() {
  export _UID
  _UID=$(id -u)
  # テスト用一時ディレクトリを SANDBOX として確保し、本番パス（DARWIN_USER_TEMP_DIR）に触れない
  export AI_USAGE_BASE_DIR
  AI_USAGE_BASE_DIR=$(mktemp -d)
  # 本体と同じ lib を source してパスを取得
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/cache-path.sh
  source "$REPO_ROOT/scripts/lib/cache-path.sh"
  mkdir -p "$(dirname "$LOCK_DIR")"
  rm -rf "$LOCK_DIR"
}

teardown() {
  rm -rf "$LOCK_DIR"
  rm -rf "$AI_USAGE_BASE_DIR"
  unset AI_USAGE_BASE_DIR
}

# 1. mkdir atomic lock: lockdir がない場合は mkdir が成功すること
@test "mkdir succeeds when lockdir absent" {
  run mkdir "$LOCK_DIR"
  [ "$status" -eq 0 ]
  [ -d "$LOCK_DIR" ]
}

# 2. 二重起動防止: lockdir がある場合は mkdir が失敗すること
@test "mkdir fails when lockdir exists (prevents double-start)" {
  mkdir "$LOCK_DIR"
  run mkdir "$LOCK_DIR" 2>/dev/null
  [ "$status" -ne 0 ]
}

# 3. 空 PID は stale 判定されない（初期化中保護）
@test "empty pid file does not trigger stale cleanup" {
  mkdir "$LOCK_DIR"
  # pid ファイルを空で作成
  touch "$LOCK_DIR/pid"

  _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  # 数値 PID ガード: 空文字は ^[0-9]+$ にマッチしない
  if [[ "$_lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_lock_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
  fi

  # lockdir が保護されている（削除されていない）
  [ -d "$LOCK_DIR" ]
}

# 4. 数値の死亡 PID は stale 解放される
@test "dead numeric pid triggers stale cleanup" {
  mkdir "$LOCK_DIR"
  # 存在しない PID（99999999 は通常存在しない）
  echo "99999999" > "$LOCK_DIR/pid"

  _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [[ "$_lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_lock_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
  fi

  # lockdir が解放されている
  [ ! -d "$LOCK_DIR" ]
}

# 5. 生きている PID は stale 解放されない
@test "live pid is not evicted" {
  mkdir "$LOCK_DIR"
  # 自分自身の PID（確実に生きている）
  echo $$ > "$LOCK_DIR/pid"

  _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  if [[ "$_lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_lock_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"
  fi

  # lockdir が保護されている
  [ -d "$LOCK_DIR" ]
}

# 6. 親 PID 即書込: mkdir 直後に pid が書かれていること
@test "parent pid written immediately after mkdir" {
  mkdir "$LOCK_DIR"
  echo $$ > "$LOCK_DIR/pid"
  _pid=$(cat "$LOCK_DIR/pid")
  [ "$_pid" = "$$" ]
}

# 7. キャッシュパス: AI_USAGE_BASE_DIR/ai-usage-monitor/cache 形式であること
@test "cache file path uses AI_USAGE_BASE_DIR sandbox directory" {
  # サンドボックスパスを参照していること
  [[ "$CACHE_FILE" == *"ai-usage-monitor/cache" ]]
  [[ "$CACHE_FILE" == "${AI_USAGE_BASE_DIR%/}/ai-usage-monitor/cache" ]]
}

# 8. squatting 対策 positive: 自分所有ディレクトリは init_cache_dir が受け入れる
@test "init_cache_dir accepts self-owned directory" {
  rm -rf "$AI_USAGE_DIR"
  run bash -c "
    export AI_USAGE_BASE_DIR='$AI_USAGE_BASE_DIR'
    source '$REPO_ROOT/scripts/lib/cache-path.sh'
    init_cache_dir
  "
  [ "$status" -eq 0 ]
  [ -d "$AI_USAGE_DIR" ]
  [ -O "$AI_USAGE_DIR" ]
}

# 9. squatting 対策 negative: 他ユーザー所有の既存ディレクトリは init_cache_dir が拒否する
# /System/Library は macOS で root 所有の既存ディレクトリ。mkdir -p は成功（既存）するが
# [ -O ] は false になるため init_cache_dir が return 1 を返す。
@test "init_cache_dir rejects non-owned directory (squatting protection)" {
  if [ "$(id -u)" -eq 0 ]; then skip "Running as root — ownership check always succeeds"; fi
  # /System/Library は macOS 専用（Linux では存在しない）
  if [[ "$OSTYPE" != "darwin"* ]]; then skip "macOS-only test using /System/Library as root-owned dir"; fi
  run bash -c "
    export AI_USAGE_BASE_DIR='$AI_USAGE_BASE_DIR'
    source '$REPO_ROOT/scripts/lib/cache-path.sh'
    AI_USAGE_DIR='/System/Library'
    init_cache_dir
  "
  [ "$status" -ne 0 ]
}

# 10. init_cache_dir: AI_USAGE_DIR がファイルとして既存なら mkdir 失敗で return 1
@test "init_cache_dir fails when AI_USAGE_DIR exists as regular file" {
  # setup() が AI_USAGE_DIR をディレクトリとして作成済みなので先に削除する
  rm -rf "$AI_USAGE_DIR"
  touch "$AI_USAGE_DIR"
  run bash -c "
    export AI_USAGE_BASE_DIR='$AI_USAGE_BASE_DIR'
    source '$REPO_ROOT/scripts/lib/cache-path.sh'
    init_cache_dir
  "
  [ "$status" -ne 0 ]
  rm -f "$AI_USAGE_DIR"
}

# 11. init_cache_dir: AI_USAGE_DIR が symlink なら return 1
@test "init_cache_dir rejects symlink AI_USAGE_DIR" {
  # setup() が AI_USAGE_DIR をディレクトリとして作成済みなので先に削除する
  rm -rf "$AI_USAGE_DIR"
  _target=$(mktemp -d)
  ln -s "$_target" "$AI_USAGE_DIR"
  run bash -c "
    export AI_USAGE_BASE_DIR='$AI_USAGE_BASE_DIR'
    source '$REPO_ROOT/scripts/lib/cache-path.sh'
    init_cache_dir
  "
  [ "$status" -ne 0 ]
  rm -rf "$_target" "$AI_USAGE_DIR"
}

# 12. double source 冪等性: 2回 source しても AI_USAGE_DIR が変わらない
@test "double source does not change AI_USAGE_DIR" {
  local first_dir="$AI_USAGE_DIR"
  source "$REPO_ROOT/scripts/lib/cache-path.sh"
  [ "$AI_USAGE_DIR" = "$first_dir" ]
}

# 11 (旧8). trailing-slash 回帰テスト: cache-path.sh を末尾スラッシュ付きベースで再 source して // にならない
@test "trailing slash in base dir does not produce double slash" {
  # AI_USAGE_BASE_DIR に末尾スラッシュを付けて lib を再 source し、本体コードの join を検証
  export AI_USAGE_BASE_DIR="${AI_USAGE_BASE_DIR}/"
  source "$REPO_ROOT/scripts/lib/cache-path.sh"
  [[ "$AI_USAGE_DIR" != *"//"* ]]
  # 末尾スラッシュを strip した期待値と一致すること
  expected="${AI_USAGE_BASE_DIR%/}/ai-usage-monitor"
  [[ "$AI_USAGE_DIR" == "$expected" ]]
}

#!/usr/bin/env bats
# tests/find_active_root_pin.bats
#
# Issue #73 — ai-org-subagent-watch.sh の find_active_root_pin が
#   1) `sa:` のみ除外していて `cdx-pr*` / `xcb` を root に誤推定
#   2) glob 順 (= sorted by filename) だが、複数 active root が並んだとき
#      明示的な sort + 決定的 tie-break が無く、状況依存で別 root を返す
# という 2 件の問題を検出する単体テスト。
#
# このテストは:
#   - find_active_root_pin の対象になる pin ファイルを一時 PROGRESS_DIR に作り
#   - sa: / cdx-pr* / xcb / その他 prefix を混在させ
#   - 「ホワイトリスト的に subagent 系 prefix を全除外」「最新 updated を優先」
#     という修正後の挙動を assert する
#
# 実行: bats tests/find_active_root_pin.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-subagent-watch.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-subagent-watch.sh not found"

  # 専用 progress dir を tmp に作成
  TEST_PROGRESS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-org-progress-test.XXXXXX")"
  export TEST_PROGRESS_DIR
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# 修正後の find_active_root_pin と挙動を一致させた純粋関数
# (script からロジックを抽出。修正後の正典: 接頭辞ホワイトリスト + 最新 updated 優先)
find_active_root_pin_test() {
  local progress_dir="$1"
  local now
  now=$(date +%s)
  local best_id=""
  local best_updated=0
  local id parent updated age
  for j in "$progress_dir"/*.json ; do
    [ -f "$j" ] || continue
    id=$(basename "$j" .json)
    parent=$(jq -r '.parent // empty' "$j" 2>/dev/null)
    updated=$(jq -r '.updated // 0' "$j" 2>/dev/null)
    age=$(( now - updated ))
    # parent あり → root 候補から除外
    [ -n "$parent" ] && continue
    # 180 秒以内 active のみ
    [ "$age" -ge 180 ] && continue
    # subagent / 子プロセス系 prefix は root から除外
    case "$id" in
      sa:*|cdx-pr*|xcb) continue ;;
    esac
    # 最新 updated を優先 (tie-break は id の C ロケール辞書順で安定化)
    if [ -z "$best_id" ]; then
      best_updated="$updated"
      best_id="$id"
    elif [ "$updated" -gt "$best_updated" ]; then
      best_updated="$updated"
      best_id="$id"
    elif [ "$updated" -eq "$best_updated" ] && \
         [ "$(printf '%s\n%s\n' "$id" "$best_id" | LC_ALL=C sort | head -1)" = "$id" ] && \
         [ "$id" != "$best_id" ]; then
      best_id="$id"
    fi
  done
  if [ -n "$best_id" ]; then echo "$best_id"; fi
  return 0
}

# pin file を作るヘルパ
write_pin() {
  local id=$1 updated=$2 parent=${3:-}
  if [ -n "$parent" ]; then
    printf '{"id":"%s","updated":%s,"parent":"%s","step":1,"total":1,"label":"x"}\n' \
      "$id" "$updated" "$parent" > "$TEST_PROGRESS_DIR/$id.json"
  else
    printf '{"id":"%s","updated":%s,"step":1,"total":1,"label":"x"}\n' \
      "$id" "$updated" > "$TEST_PROGRESS_DIR/$id.json"
  fi
}

# ──────────────────────────────────────────────────────────────
# 旧バグ再現: cdx-pr / xcb が root と誤認識される
# ──────────────────────────────────────────────────────────────

@test "cdx-pr582 のみ active なら root は無し (旧バグ: cdx-pr が root にされる)" {
  write_pin "cdx-pr582" "$(date +%s)"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "xcb のみ active なら root は無し (旧バグ: xcb が root にされる)" {
  write_pin "xcb" "$(date +%s)"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sa:abc のみ active なら root は無し (既存除外、回帰防止)" {
  write_pin "sa:abc1234567" "$(date +%s)"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "impl-73 (実 root) + cdx-pr582 + xcb + sa:foo 混在 → impl-73 が選ばれる" {
  local now
  now=$(date +%s)
  write_pin "impl-73" "$now"
  write_pin "cdx-pr582" "$now"
  write_pin "xcb" "$now"
  write_pin "sa:foo1234567" "$now"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "impl-73" ]
}

# ──────────────────────────────────────────────────────────────
# 非決定性解消: 複数 root active の時、最新 updated を返す
# ──────────────────────────────────────────────────────────────

@test "複数 root active → updated が最新の root が選ばれる (非決定性解消)" {
  local now
  now=$(date +%s)
  # zzz-old は 60 秒前、aaa-new は今 → updated が最新 = aaa-new
  # (旧実装は glob 辞書順で zzz-old より先に aaa-new が見つかる場合と
  #  そうでない場合があり、状況依存で割れる)
  write_pin "zzz-old-root" "$((now - 60))"
  write_pin "aaa-new-root" "$now"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "aaa-new-root" ]
}

@test "updated tie の時は id 辞書順で最小 → 決定的" {
  local now
  now=$(date +%s)
  write_pin "bbb-root" "$now"
  write_pin "aaa-root" "$now"
  write_pin "ccc-root" "$now"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "aaa-root" ]
}

# ──────────────────────────────────────────────────────────────
# parent 持ち / age 超過 / 何もなし
# ──────────────────────────────────────────────────────────────

@test "parent 持ちは root から除外" {
  write_pin "child-pin" "$(date +%s)" "some-parent"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "180 秒超過 active は root から除外" {
  write_pin "stale-root" "$(( $(date +%s) - 200 ))"
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pin が 1 つも無ければ空" {
  run find_active_root_pin_test "$TEST_PROGRESS_DIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ──────────────────────────────────────────────────────────────
# 実 script との parity: production の find_active_root_pin を呼び出して
# 同じ fixture で同じ結果を返すことを確認 (重要・回帰防止)
# ──────────────────────────────────────────────────────────────

run_production_find() {
  # script の `case "$cmd"` 末尾 dispatch を避けるため、関数定義部分だけを抽出して source。
  # find_active_root_pin の関数定義 (コメント付き) を awk で切り出す。
  local fn_body
  fn_body=$(awk '/^# 起動中 root pin/,/^}$/' "$SCRIPT")
  # awk 抽出失敗 (空文字) の場合は明示的に失敗させる
  [ -n "$fn_body" ] || { echo "ERROR: awk failed to extract find_active_root_pin from $SCRIPT" >&2; return 1; }
  bash -c "$fn_body
find_active_root_pin '$1'" 2>/dev/null
}

@test "[parity] production: cdx-pr582 のみ → 空" {
  write_pin "cdx-pr582" "$(date +%s)"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ -z "$result" ]
}

@test "[parity] production: xcb のみ → 空" {
  write_pin "xcb" "$(date +%s)"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ -z "$result" ]
}

@test "[parity] production: sa:foo のみ → 空" {
  write_pin "sa:foo1234567" "$(date +%s)"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ -z "$result" ]
}

@test "[parity] production: 混在 → impl-73" {
  local now
  now=$(date +%s)
  write_pin "impl-73" "$now"
  write_pin "cdx-pr582" "$now"
  write_pin "xcb" "$now"
  write_pin "sa:foo1234567" "$now"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ "$result" = "impl-73" ]
}

@test "[parity] production: 複数 root → 最新 updated を返す" {
  local now
  now=$(date +%s)
  write_pin "zzz-old-root" "$((now - 60))"
  write_pin "aaa-new-root" "$now"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ "$result" = "aaa-new-root" ]
}

@test "[parity] production: tie → 辞書順最小" {
  local now
  now=$(date +%s)
  write_pin "bbb-root" "$now"
  write_pin "aaa-root" "$now"
  write_pin "ccc-root" "$now"
  result=$(run_production_find "$TEST_PROGRESS_DIR" || true)
  [ "$result" = "aaa-root" ]
}

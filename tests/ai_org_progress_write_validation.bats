#!/usr/bin/env bats
# tests/ai_org_progress_write_validation.bats
#
# Issue #258 — `write` サブコマンドの cur / total 入力バリデーション追加
#
# 修正内容:
#   1. cur / total が非負整数でない場合 exit 2 で早期 fail
#   2. jq 呼び出しに 2>/dev/null を付与 (他 3 箇所と一貫)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-bats-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"
  WRAPPER="$SCRIPT"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# ──────────────────────────────────────────────────────────────
# 正常ケース: 既存動作が変わらない
# ──────────────────────────────────────────────────────────────

@test "write: 正常な cur/total で exit 0 + JSON ファイル生成" {
  run "$WRAPPER" write my-job 3 10 "valid write"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/my-job.json" ]
  [ "$(jq -r '.current' "$TEST_PROGRESS_DIR/my-job.json")" = "3" ]
  [ "$(jq -r '.total'   "$TEST_PROGRESS_DIR/my-job.json")" = "10" ]
}

@test "write: cur=0 total=0 (ゼロ) は非負整数として許可" {
  run "$WRAPPER" write zero-job 0 0 "zero"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/zero-job.json" ]
}

@test "write: cur と total が等しい (100%) でも exit 0" {
  run "$WRAPPER" write full-job 5 5 "full"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.current' "$TEST_PROGRESS_DIR/full-job.json")" = "5" ]
}

@test "write: label なし (省略) でも exit 0" {
  run "$WRAPPER" write no-label-job 1 4
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/no-label-job.json" ]
}

# ──────────────────────────────────────────────────────────────
# 異常ケース: cur が非負整数でない → exit 2
# ──────────────────────────────────────────────────────────────

@test "write: cur が負数 (-1) → exit 2" {
  run "$WRAPPER" write bad-cur -1 10 "bad cur"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cur"* ]]
}

@test "write: cur が文字列 (abc) → exit 2" {
  run "$WRAPPER" write bad-cur-str abc 10 "bad cur str"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cur"* ]]
}

@test "write: cur が小数 (1.5) → exit 2" {
  run "$WRAPPER" write bad-cur-float 1.5 10 "bad cur float"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cur"* ]]
}

@test "write: cur が空文字 → exit 2" {
  run "$WRAPPER" write bad-cur-empty "" 10 "bad cur empty"
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# 異常ケース: total が非負整数でない → exit 2
# ──────────────────────────────────────────────────────────────

@test "write: total が負数 (-5) → exit 2" {
  run "$WRAPPER" write bad-total 3 -5 "bad total"
  [ "$status" -eq 2 ]
  [[ "$output" == *"total"* ]]
}

@test "write: total が文字列 (ten) → exit 2" {
  run "$WRAPPER" write bad-total-str 3 ten "bad total str"
  [ "$status" -eq 2 ]
  [[ "$output" == *"total"* ]]
}

@test "write: total が小数 (2.5) → exit 2" {
  run "$WRAPPER" write bad-total-float 3 2.5 "bad total float"
  [ "$status" -eq 2 ]
  [[ "$output" == *"total"* ]]
}

# ──────────────────────────────────────────────────────────────
# バリデーション失敗時は既存ファイルを破壊しない
# ──────────────────────────────────────────────────────────────

@test "write: cur 不正で失敗しても既存 JSON を上書きしない" {
  "$WRAPPER" write existing-job 2 5 "existing"
  original_total="$(jq -r '.total' "$TEST_PROGRESS_DIR/existing-job.json")"

  run "$WRAPPER" write existing-job bad-cur 5 "overwrite attempt"
  [ "$status" -eq 2 ]

  # JSON は元のまま保持されている
  [ -f "$TEST_PROGRESS_DIR/existing-job.json" ]
  [ "$(jq -r '.total' "$TEST_PROGRESS_DIR/existing-job.json")" = "$original_total" ]
}

@test "write: total 不正で失敗しても既存 JSON を上書きしない" {
  "$WRAPPER" write existing-job2 1 3 "original"
  original_cur="$(jq -r '.current' "$TEST_PROGRESS_DIR/existing-job2.json")"

  run "$WRAPPER" write existing-job2 2 bad-total "overwrite attempt"
  [ "$status" -eq 2 ]

  [ -f "$TEST_PROGRESS_DIR/existing-job2.json" ]
  [ "$(jq -r '.current' "$TEST_PROGRESS_DIR/existing-job2.json")" = "$original_cur" ]
}

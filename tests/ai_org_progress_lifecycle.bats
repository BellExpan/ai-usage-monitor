#!/usr/bin/env bats
# tests/ai_org_progress_lifecycle.bats
#
# Issue #77 — clear / pin ライフサイクル
#
# 修正対象:
#   1. `clear` が `trash` 未インストール環境で silent fail
#      → trash がなければ rm -f fallback して必ず削除する
#   2. `complete` が完了 pin を残し続けて `--short` に粘着
#      → completed pin (current==total && total>0) は SHORT_STICKY_SEC (default 60s)
#        経過後 `--short` で自動非表示。`show` では COMPLETED_HIDE_SEC (default 600s)
#        まで残る (既存挙動)。ファイル自体は履歴用に残す。
#   3. `complete` / `set-parent` の jq 失敗時に空 tmpfile が atomic mv で
#      既存 JSON を破壊する
#      → jq exit status と `[[ -s "$tmpfile" ]]` を mv 前に検証、失敗なら
#        tmp を削除して既存ファイルを温存し exit 非ゼロ + stderr 警告

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-bats-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"

  # script は AI_ORG_PROGRESS_DIR_OVERRIDE を natively 受け付けるので
  # wrapper は env 引き継ぎだけで十分
  WRAPPER="$SCRIPT"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# ──────────────────────────────────────────────────────────────
# 1. clear: trash 未存在環境で fallback 削除する
# ──────────────────────────────────────────────────────────────

@test "clear: trash 未インストール環境でも進捗ファイルを削除する" {
  "$WRAPPER" write target_x 1 3 "target X"
  [ -f "$TEST_PROGRESS_DIR/target_x.json" ]

  # trash を完全に排除した PATH を構築:
  # 必要 binary (jq, mktemp, sed, mv, rm, cat, awk, basename, date, tr, printf, chmod, mkdir, dirname)
  # を STUB_PATH_DIR に symlink で揃え、/usr/bin/trash は含めない
  STUB_PATH_DIR="$TEST_PROGRESS_DIR/no-trash-bin"
  mkdir -p "$STUB_PATH_DIR"
  for bin in jq mktemp sed mv rm cat awk basename date tr printf chmod mkdir dirname tee head tail grep cut wc echo bash sh ls find sort uniq stat; do
    src=$(command -v "$bin" 2>/dev/null || true)
    [ -n "$src" ] && ln -sf "$src" "$STUB_PATH_DIR/$bin"
  done
  # trash は意図的に置かない

  run env -i HOME="$HOME" \
      PATH="$STUB_PATH_DIR" \
      AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR" \
      bash "$WRAPPER" clear target_x
  [ "$status" -eq 0 ]

  # ファイルが削除されていること (trash fallback が機能)
  [ ! -f "$TEST_PROGRESS_DIR/target_x.json" ]
}

@test "clear: 存在しない id でもエラーなく no-op" {
  run "$WRAPPER" clear nonexistent_y
  [ "$status" -eq 0 ]
}

@test "clear: symlink (悪意ある link) は削除しない" {
  # PROGRESS_DIR の外を指す symlink を作って、それを clear しても外部ファイル削除されないこと
  echo "outside content" > "$TEST_PROGRESS_DIR/outside.txt"
  ln -s "$TEST_PROGRESS_DIR/outside.txt" "$TEST_PROGRESS_DIR/evil.json"

  run "$WRAPPER" clear evil
  [ "$status" -eq 0 ]

  # 外部ファイルは温存されている
  [ -f "$TEST_PROGRESS_DIR/outside.txt" ]
}

# ──────────────────────────────────────────────────────────────
# 2. complete: completed pin が --short に粘着しない
# ──────────────────────────────────────────────────────────────

@test "complete 直後 (60s 以内): --short に completed pin が表示される (sticky)" {
  "$WRAPPER" write fresh_a 1 1 "fresh A"
  "$WRAPPER" complete fresh_a

  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh_a"* ]]
}

@test "complete 後 60s 経過: --short から自動非表示 (sticky 解除)" {
  "$WRAPPER" write old_b 1 1 "old B"
  "$WRAPPER" complete old_b

  # updated を 120 秒前に偽装 (sticky=60s 超え)
  past=$(($(date +%s) - 120))
  tmpf="$TEST_PROGRESS_DIR/old_b.json"
  jq --argjson u "$past" '.updated = $u' "$tmpf" > "$tmpf.new"
  mv "$tmpf.new" "$tmpf"

  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  # 出力に old_b が含まれていない (空 or 他 pin のみ)
  [[ "$output" != *"old_b"* ]]
}

@test "complete 後 60s 経過: show には COMPLETED_HIDE_SEC まで残る (履歴)" {
  "$WRAPPER" write hist_c 1 1 "hist C"
  "$WRAPPER" complete hist_c

  past=$(($(date +%s) - 120))
  tmpf="$TEST_PROGRESS_DIR/hist_c.json"
  jq --argjson u "$past" '.updated = $u' "$tmpf" > "$tmpf.new"
  mv "$tmpf.new" "$tmpf"

  # show コマンドは default 600s まで残るので、120s 経過なら表示される
  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"hist_c"* ]]
}

@test "complete: ファイルは履歴のため残る (clear で削除)" {
  "$WRAPPER" write keep_d 1 1 "keep D"
  "$WRAPPER" complete keep_d
  [ -f "$TEST_PROGRESS_DIR/keep_d.json" ]

  "$WRAPPER" clear keep_d
  [ ! -f "$TEST_PROGRESS_DIR/keep_d.json" ]
}

# ──────────────────────────────────────────────────────────────
# 3. jq 失敗時に既存 JSON を破壊しない
# ──────────────────────────────────────────────────────────────

@test "complete: 壊れた JSON でも既存ファイルは破壊しない" {
  # 既存 JSON が壊れている (jq が失敗するケース) を模擬
  echo "{ this is not valid json" > "$TEST_PROGRESS_DIR/broken_e.json"
  original=$(cat "$TEST_PROGRESS_DIR/broken_e.json")

  run "$WRAPPER" complete broken_e
  # 失敗するか、no-op で抜けるかどちらか。既存ファイルを 0 byte にしてはいけない
  current=$(cat "$TEST_PROGRESS_DIR/broken_e.json")
  # 0 byte でないこと (空 tmpfile が atomic mv で破壊するパターン検出)
  [ -s "$TEST_PROGRESS_DIR/broken_e.json" ]
}

@test "set-parent: 壊れた JSON でも既存ファイルは破壊しない" {
  echo "{ broken json" > "$TEST_PROGRESS_DIR/broken_f.json"
  "$WRAPPER" write parent_f 0 5 "parent F"

  run "$WRAPPER" set-parent broken_f parent_f
  # 既存 broken file が 0 byte 化していないこと
  [ -s "$TEST_PROGRESS_DIR/broken_f.json" ]
}

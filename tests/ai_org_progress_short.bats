#!/usr/bin/env bats
# tests/ai_org_progress_short.bats
#
# Issue #617 — ai-org-progress --short の出力契約テスト
#
# オーナー指示 (2026-06-07): bg job ごとに改行して表示する（status line が縦に伸びてOK）。
# 旧 Issue #78 の「1 行 (改行なし) 契約」は廃止。新契約:
#   - **出力行数 = 表示pin数**（job 間は改行で区切る・末尾改行なし）
#   - 表示対象は root + 直下 child（2階層）。孫以降は root に集約され表示行に出ない
#   - label 内の改行は write 時 + print_short_row（row単位）で除去され「行数を増やさない」
#   - pin なし時は空出力
#
# したがって内部改行数 = 表示pin数 − 1。
#
# 実行: bats tests/ai_org_progress_short.bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  # テスト用の隔離 PROGRESS_DIR (各テストで独立)
  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-test-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# ヘルパ: PROGRESS_DIR を上書き可能な形でスクリプト実行
# 現状スクリプトは PROGRESS_DIR 固定 (/tmp/ai-org-progress) なので、
# AI_ORG_PROGRESS_DIR_OVERRIDE 環境変数で上書きできるよう実装される想定。
# (override 未対応なら全テスト skip — RED 段階での回帰確認用)
run_progress() {
  AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR" \
    bash "$SCRIPT" "$@"
}

# ──────────────────────────────────────────────────────────────
# 単一 pin の --short 出力は改行を含まない
# ──────────────────────────────────────────────────────────────
@test "short_single: 1 pin の --short 出力は 1 行" {
  run_progress write t1 1 5 "task one"
  run run_progress --short
  [ "$status" -eq 0 ]
  # wc -l は末尾改行を行数としてカウントする (POSIX)。
  # 1 行 (改行なし) なら wc -l は 0、1 行末尾改行付き or 多行なら >= 1。
  # 本契約は「改行を含まない 1 行」なので grep -c で検証する。
  newline_count=$(printf '%s' "$output" | awk 'BEGIN{n=0} /\n/{n++} END{print n}')
  # awk pattern では \n は普通マッチしないので、より直接的に:
  # output を tr で改行カウント
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# 複数 root pin の --short は job ごと改行（行数 = job 数 / 内部改行 = job数-1）
# ──────────────────────────────────────────────────────────────
@test "short_multi_root: 複数 root pin は job ごと改行（3 jobs → 改行 2）" {
  run_progress write t1 1 5 "task one"
  run_progress write t2 2 5 "task two"
  run_progress write t3 3 5 "task three"
  run run_progress --short
  [ "$status" -eq 0 ]
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 2 ]                 # 3 job → 内部改行 2（末尾改行なし）
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 3 ]   # 3 行
}

# ──────────────────────────────────────────────────────────────
# 親子関係 pin も job ごと改行（root + child = 2 行 → 改行 1）
# ──────────────────────────────────────────────────────────────
@test "short_parent_child: 親子 pin は job ごと改行（2 行 → 改行 1）" {
  run_progress write parent1 0 3 "parent job"
  run_progress write child1 1 5 "child task" parent1
  run run_progress --short
  [ "$status" -eq 0 ]
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 1 ]
}

# ──────────────────────────────────────────────────────────────
# label に改行が含まれていても --short は 1 行
# (実際に \n リテラル文字列が write で渡されるケース)
# ──────────────────────────────────────────────────────────────
@test "short_label_newline: label に literal newline を含んでも 1 行" {
  # printf %b で \n を実改行に変換してから渡す
  label_with_nl=$(printf 'line1\nline2\nline3')
  run_progress write t1 1 5 "$label_with_nl"
  run run_progress --short
  [ "$status" -eq 0 ]
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# 孫 pin は root に集約され表示行には出ない（表示は root + 直下 child の2階層）
# ──────────────────────────────────────────────────────────────
@test "short_grandchild: 孫 pin は表示行に出ない（root+child=2行）" {
  run_progress write root1 0 9 "root job"
  run_progress write child1 1 5 "child job" root1
  run_progress write grand1 1 5 "grandchild job" child1
  run run_progress --short
  [ "$status" -eq 0 ]
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 1 ]                                   # root + child = 2行（孫は非表示）
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  [[ "$output" != *"grandchild job"* ]]                    # 孫 label は出ない
}

# ──────────────────────────────────────────────────────────────
# 直接生成 JSON（write 経由でない）の改行 label でも row 単位防御で 1 行
# ──────────────────────────────────────────────────────────────
@test "short_label_newline_direct: 直接JSONの改行labelでも1行（row単位正規化）" {
  _now=$(date +%s)
  printf '{"current":1,"total":5,"label":"line1\\nline2\\nline3","updated":%s,"started":%s}\n' \
    "$_now" "$_now" > "$TEST_PROGRESS_DIR/direct.json"
  run run_progress --short
  [ "$status" -eq 0 ]
  nl_actual=$(printf '%s' "$output" | tr -cd '\n' | wc -c | tr -d ' ')
  [ "$nl_actual" -eq 0 ]                                   # 1 job = 0 改行（改行labelでも増えない）
  [[ "$output" != *$'\n'* ]]
}

# ──────────────────────────────────────────────────────────────
# pin が空 (jobs なし) 時は何も出力しない (改行も出さない)
# ──────────────────────────────────────────────────────────────
@test "short_empty: pin なし時は改行も出さない" {
  run run_progress --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

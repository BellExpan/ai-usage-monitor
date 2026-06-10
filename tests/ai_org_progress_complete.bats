#!/usr/bin/env bats
# tests/ai_org_progress_complete.bats
#
# Issue #71 — `ai-org-progress complete` を idempotent 化する。
#
# 背景: 現実装は同一 id に対して `complete` を複数回呼ぶと、毎回
#   親 (parent) の `.current` を +1 する。subagent retry / launchd 再起動 /
#   shell 二重実行で発生し、親カウンタが暴走する。
#
# 期待: 2 回目以降の `complete <id>` は自身の current/total を再書き込みする
#   ものの、親の current は加算しない (no-op + warning log を stderr へ)。
#
# 後方互換性: 1 回目の complete は従来通り親 +1 連動が動く。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  # bats ごとに独立した PROGRESS_DIR を使う (test 間干渉防止)
  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-bats-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"

  # script は AI_ORG_PROGRESS_DIR_OVERRIDE 環境変数を natively 受け付けるので
  # wrapper 不要。Issue #77 の修正で、script は env override で test dir を見る。
  # (旧実装は sed substitution でカスタムスクリプト生成していたが、
  #  script の冒頭が `PROGRESS_DIR="${AI_ORG_PROGRESS_DIR_OVERRIDE:-/tmp/ai-org-progress}"`
  #  に変わったため sed pattern が unmatch で fail していた)
  WRAPPER="$SCRIPT"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# Helper: jq の現在値を読み出す
read_current() {
  jq -r '.current // 0' "$TEST_PROGRESS_DIR/$1.json"
}

read_total() {
  jq -r '.total // 0' "$TEST_PROGRESS_DIR/$1.json"
}

# ──────────────────────────────────────────────────────────────
# 1 回目の complete は従来通り動く (後方互換性)
# ──────────────────────────────────────────────────────────────

@test "1回目の complete: child は 100%、親 current は +1" {
  # 親 (total=3, current=0) を作成
  "$WRAPPER" write parent_a 0 3 "parent A"
  # 子 (total=2, current=2、parent=parent_a) を作成
  # write の引数: <id> <cur> <total> <label> <parent> (parent は 5 番目)
  "$WRAPPER" write child_a1 2 2 "child A1" parent_a

  run "$WRAPPER" complete child_a1
  [ "$status" -eq 0 ]

  # child_a1 は 100%
  [ "$(read_current child_a1)" = "2" ]
  [ "$(read_total child_a1)" = "2" ]

  # parent_a.current は 0 → 1 に
  [ "$(read_current parent_a)" = "1" ]
  [ "$(read_total parent_a)" = "3" ]
}

# ──────────────────────────────────────────────────────────────
# 2 回目以降の complete は親を +1 しない (idempotent)
# ──────────────────────────────────────────────────────────────

@test "2回目の complete: 親の current は +1 されない (idempotent)" {
  "$WRAPPER" write parent_b 0 3 "parent B"
  "$WRAPPER" write child_b1 2 2 "child B1" parent_b

  # 1 回目 — 親 0 → 1
  "$WRAPPER" complete child_b1
  [ "$(read_current parent_b)" = "1" ]

  # 2 回目 — 親は 1 のまま動かない (現実装は 2 になる → RED)
  run "$WRAPPER" complete child_b1
  [ "$status" -eq 0 ]
  [ "$(read_current parent_b)" = "1" ]

  # child_b1 自身は 100% を維持
  [ "$(read_current child_b1)" = "2" ]
  [ "$(read_total child_b1)" = "2" ]
}

@test "3回目の complete でも親 current は +1 されない" {
  "$WRAPPER" write parent_c 0 5 "parent C"
  "$WRAPPER" write child_c1 1 1 "child C1" parent_c

  "$WRAPPER" complete child_c1   # 1 回目: 親 0→1
  "$WRAPPER" complete child_c1   # 2 回目: no-op
  run "$WRAPPER" complete child_c1   # 3 回目: no-op
  [ "$status" -eq 0 ]

  [ "$(read_current parent_c)" = "1" ]
}

# ──────────────────────────────────────────────────────────────
# 2 回目の complete は warning を stderr に出す
# ──────────────────────────────────────────────────────────────

@test "2回目の complete は warning を stderr に出す" {
  "$WRAPPER" write parent_d 0 3 "parent D"
  "$WRAPPER" write child_d1 2 2 "child D1" parent_d

  "$WRAPPER" complete child_d1

  # 2 回目: stderr に "already completed" を含む warning
  run "$WRAPPER" complete child_d1
  [ "$status" -eq 0 ]
  [[ "$output" == *"already completed"* ]] || [[ "$output" == *"already complete"* ]]
}

# ──────────────────────────────────────────────────────────────
# parent なしの pin に対する complete もエラーなく idempotent
# ──────────────────────────────────────────────────────────────

@test "parent なし pin: 何度 complete しても自身の値は安定" {
  "$WRAPPER" write standalone_e 1 4 "standalone E"

  "$WRAPPER" complete standalone_e
  [ "$(read_current standalone_e)" = "4" ]
  [ "$(read_total standalone_e)" = "4" ]

  # 2 回目以降も current=total を維持、エラーなし
  run "$WRAPPER" complete standalone_e
  [ "$status" -eq 0 ]
  [ "$(read_current standalone_e)" = "4" ]

  run "$WRAPPER" complete standalone_e
  [ "$status" -eq 0 ]
  [ "$(read_current standalone_e)" = "4" ]
}

# ──────────────────────────────────────────────────────────────
# 兄弟 child に影響しない (複数子のうち 1 つだけ二重 complete)
# ──────────────────────────────────────────────────────────────

@test "片方の子だけ二重 complete: 親 current は他の子の +1 を正しく受け取る" {
  "$WRAPPER" write parent_f 0 3 "parent F"
  "$WRAPPER" write child_f1 1 1 "child F1" parent_f
  "$WRAPPER" write child_f2 2 2 "child F2" parent_f

  "$WRAPPER" complete child_f1   # 親 0→1
  "$WRAPPER" complete child_f1   # idempotent: 親は 1 のまま
  "$WRAPPER" complete child_f2   # 親 1→2

  [ "$(read_current parent_f)" = "2" ]
}

# ──────────────────────────────────────────────────────────────
# 親が complete 済の後、別の child が complete しても親 completed=true は維持
# (CTO/A/B レビュー合意の追加ケース、PR description に明記された設計判断の test 表明)
# ──────────────────────────────────────────────────────────────

@test "親 complete 済の後、別の子 complete でも親 completed=true は保持" {
  "$WRAPPER" write parent_g 0 2 "parent G"
  "$WRAPPER" write child_g1 1 1 "child G1" parent_g
  "$WRAPPER" write child_g2 1 1 "child G2" parent_g

  "$WRAPPER" complete child_g1   # parent 0→1
  "$WRAPPER" complete child_g2   # parent 1→2 (full)
  "$WRAPPER" complete parent_g   # parent 自身を complete マーク

  # parent_g.completed は true
  [ "$(jq -r '.completed' "$TEST_PROGRESS_DIR/parent_g.json")" = "true" ]

  # 後から再度 child を complete (idempotent path) — parent.completed は影響を受けない
  run "$WRAPPER" complete child_g1
  [ "$status" -eq 0 ]

  [ "$(jq -r '.completed' "$TEST_PROGRESS_DIR/parent_g.json")" = "true" ]
  [ "$(read_current parent_g)" = "2" ]
}

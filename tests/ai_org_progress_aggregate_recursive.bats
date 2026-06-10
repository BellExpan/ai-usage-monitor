#!/usr/bin/env bats
# tests/ai_org_progress_aggregate_recursive.bats
#
# Issue #72 — aggregate_root 再帰化 + set-parent/write 循環参照検出
#
# 修正内容:
#   1. aggregate_root を再帰化: 孫 (grandchild) の進捗も root の集約に反映する
#      旧実装は直接の子のみ sum → 孫は集約から脱落していた
#   2. set-parent / write --parent 指定時に循環参照を検出: A→B→A で exit 2
#      再帰化した瞬間に無限再帰が起きる問題を 5 段祖先辿りで防止
#
# 実行: bats tests/ai_org_progress_aggregate_recursive.bats

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

# Helper: JSON フィールドを読む
read_field() {
  jq -r "$2 // 0" "$TEST_PROGRESS_DIR/$1.json"
}

# ──────────────────────────────────────────────────────────────
# 1. aggregate_root 再帰化: 孫が root の集約に反映される
# ──────────────────────────────────────────────────────────────

@test "aggregate: 孫 (grandchild) の進捗が root の --short 集約に反映される" {
  # root (cur=0, total=10)
  "$WRAPPER" write root1 0 10 "root job 1"
  # child (cur=2, total=4, parent=root1)
  "$WRAPPER" write child1 2 4 "child 1" root1
  # grandchild (cur=3, total=6, parent=child1) ← 旧実装は集約から脱落
  "$WRAPPER" write grand1 3 6 "grand 1" child1

  # --short で root1 を表示。集約値は child1+grand1 = (2+3)/(4+6) = 5/10 のはず
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  # root1 行に "5/10" または "50%" が含まれること
  [[ "$output" == *"5/10"* ]] || [[ "$output" == *"50%"* ]]
}

@test "aggregate: 孫の進捗が show コマンドの root 集約に反映される" {
  "$WRAPPER" write rootS 0 10 "show root"
  "$WRAPPER" write childS 1 4 "show child" rootS
  "$WRAPPER" write grandS 2 6 "show grand" childS

  # show で rootS の aggregate が (1+2)/(4+6) = 3/10 になること
  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"3/10"* ]] || [[ "$output" == *"30%"* ]]
}

@test "aggregate: 子が複数、孫が複数の場合も正しく集約される" {
  # root
  "$WRAPPER" write rootM 0 20 "multi root"
  # child A (cur=1, total=5)
  "$WRAPPER" write childA 1 5 "child A" rootM
  # child B (cur=2, total=5)
  "$WRAPPER" write childB 2 5 "child B" rootM
  # grandchild under A (cur=1, total=3)
  "$WRAPPER" write grandA1 1 3 "grand A1" childA
  # grandchild under B (cur=2, total=4)
  "$WRAPPER" write grandB1 2 4 "grand B1" childB

  # 集約: (childA + childB + grandA1 + grandB1) = (1+2+1+2)/(5+5+3+4) = 6/17
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"6/17"* ]] || [[ "$output" == *"35%"* ]]
}

@test "aggregate: 子のみ (孫なし) の場合は従来通り動く (後方互換)" {
  "$WRAPPER" write rootBC 0 10 "back compat root"
  "$WRAPPER" write childBC1 3 5 "bc child 1" rootBC
  "$WRAPPER" write childBC2 1 5 "bc child 2" rootBC

  # 子のみ: (3+1)/(5+5) = 4/10
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"4/10"* ]] || [[ "$output" == *"40%"* ]]
}

@test "aggregate: sa: prefix の孫は集約から除外される" {
  "$WRAPPER" write rootSA 0 10 "sa exclude root"
  "$WRAPPER" write childSA 3 5 "sa child" rootSA
  # sa: prefix の孫は除外
  "$WRAPPER" write "sa:grandSA" 999 999 "sa grand" childSA

  # 集約: childSA のみ = 3/5。sa:grandSA は除外
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"3/5"* ]] || [[ "$output" == *"60%"* ]]
}

# ──────────────────────────────────────────────────────────────
# 2. 循環参照検出: set-parent で A→B→A は exit 2
# ──────────────────────────────────────────────────────────────

@test "set-parent: 直接循環 (A→B, B→A) を検出して exit 2" {
  "$WRAPPER" write cycleA 0 3 "cycle A"
  "$WRAPPER" write cycleB 0 3 "cycle B" cycleA

  # B は A の子。A を B の子にしようとする → 循環
  run "$WRAPPER" set-parent cycleA cycleB
  [ "$status" -eq 2 ]
  [[ "$output" == *"circular"* ]] || [[ "$output" == *"循環"* ]] || [[ "$output" == *"cycle"* ]]
}

@test "set-parent: 間接循環 (A→B→C→A) を検出して exit 2" {
  "$WRAPPER" write chainA 0 3 "chain A"
  "$WRAPPER" write chainB 0 3 "chain B" chainA
  "$WRAPPER" write chainC 0 3 "chain C" chainB

  # C→A を設定しようとする → A→B→C→A の循環
  run "$WRAPPER" set-parent chainA chainC
  [ "$status" -eq 2 ]
  [[ "$output" == *"circular"* ]] || [[ "$output" == *"循環"* ]] || [[ "$output" == *"cycle"* ]]
}

@test "set-parent: 自己参照 (A→A) を検出して exit 2" {
  "$WRAPPER" write selfA 0 3 "self A"

  # A を自分の親に設定しようとする → 直接自己循環
  run "$WRAPPER" set-parent selfA selfA
  [ "$status" -eq 2 ]
  [[ "$output" == *"circular"* ]] || [[ "$output" == *"循環"* ]] || [[ "$output" == *"cycle"* ]]
}

@test "set-parent: 循環しない親設定は正常に動く (non-cycle)" {
  "$WRAPPER" write parentOK 0 5 "parent OK"
  "$WRAPPER" write childOK 2 5 "child OK"

  # childOK → parentOK は循環なし → exit 0
  run "$WRAPPER" set-parent childOK parentOK
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' "$TEST_PROGRESS_DIR/childOK.json")" = "parentOK" ]
}

# ──────────────────────────────────────────────────────────────
# 3. 循環参照検出: write --parent で循環は exit 2
# ──────────────────────────────────────────────────────────────

@test "write: parent 引数で直接循環 (A→B, B→A を write) は exit 2" {
  "$WRAPPER" write wpA 0 3 "write parent A"
  "$WRAPPER" write wpB 0 3 "write parent B" wpA

  # A の parent を B に設定しようとする → 循環
  run "$WRAPPER" write wpA 1 3 "write parent A updated" wpB
  [ "$status" -eq 2 ]
  [[ "$output" == *"circular"* ]] || [[ "$output" == *"循環"* ]] || [[ "$output" == *"cycle"* ]]
}

@test "write: parent なしの通常書き込みは循環検出の影響を受けない" {
  run "$WRAPPER" write normalW 1 5 "normal write"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/normalW.json" ]
}

@test "write: 循環しない parent 指定は正常に動く" {
  "$WRAPPER" write parentW 0 5 "parent W"
  run "$WRAPPER" write childW 1 5 "child W" parentW
  [ "$status" -eq 0 ]
  [ "$(jq -r '.parent' "$TEST_PROGRESS_DIR/childW.json")" = "parentW" ]
}

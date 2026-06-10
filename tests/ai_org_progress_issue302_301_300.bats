#!/usr/bin/env bats
# Issue 302/301/300

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

read_current() { jq -r .current "$TEST_PROGRESS_DIR/$1.json"; }
read_total()   { jq -r .total   "$TEST_PROGRESS_DIR/$1.json"; }

# ---- Issue 302: aggregate_root_for DRY ----

@test "302: --short aggregate works via aggregate_root_for" {
  "$WRAPPER" write root302 0 10 "root302"
  "$WRAPPER" write child302 3 5  "child302" root302
  "$WRAPPER" write grand302 2 5  "grand302" child302
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"5/10"* ]] || [[ "$output" == *"50%"* ]]
}

@test "302: show aggregate works via aggregate_root_for" {
  "$WRAPPER" write root302s 0 8 "root302s"
  "$WRAPPER" write child302s 2 4 "child302s" root302s
  "$WRAPPER" write grand302s 1 4 "grand302s" child302s
  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"3/8"* ]] || [[ "$output" == *"37%"* ]]
}

# ---- Issue 301: MAX_DEPTH guard ----

@test "301: 3-level nesting is fine (depth < MAX_DEPTH)" {
  "$WRAPPER" write d301_root  0 9 "d301 root"
  "$WRAPPER" write d301_c     3 5 "d301 child"      d301_root
  "$WRAPPER" write d301_gc    1 4 "d301 gc"         d301_c
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
}

@test "301: JSON cycle stops at MAX_DEPTH without hanging" {
  jq -rn --arg p cyc_c --arg l A '{current:1,total:2,label:$l,parent:$p,updated:0,started:0}' > "$TEST_PROGRESS_DIR/cyc_a.json"
  jq -rn --arg p cyc_a --arg l B '{current:0,total:1,label:$l,parent:$p,updated:0,started:0}' > "$TEST_PROGRESS_DIR/cyc_b.json"
  jq -rn --arg p cyc_b --arg l C '{current:0,total:1,label:$l,parent:$p,updated:0,started:0}' > "$TEST_PROGRESS_DIR/cyc_c.json"
  run "$WRAPPER" --short
  [ "$status" -ge 0 ]
  [[ "$output" == *MAX_DEPTH* ]] || [[ "$output" == *WARN* ]] || [ "$status" -eq 0 ]
}

# ---- Issue 300: propagate_up ----

@test "300: grandchild complete propagates to parent and grandparent" {
  "$WRAPPER" write gp300  0 3 "grandparent 300"
  "$WRAPPER" write p300   0 2 "parent 300"      gp300
  "$WRAPPER" write gc300  1 1 "grandchild 300"  p300
  run "$WRAPPER" complete gc300
  [ "$status" -eq 0 ]
  gc_cur=$(jq -r .current "$TEST_PROGRESS_DIR/gc300.json")
  [ "$gc_cur" = "1" ]
  p_cur=$(jq -r .current "$TEST_PROGRESS_DIR/p300.json")
  [ "$p_cur" = "1" ]
  gp_cur=$(jq -r .current "$TEST_PROGRESS_DIR/gp300.json")
  [ "$gp_cur" = "1" ]
}

@test "300: 3-level nesting propagates to great-grandparent" {
  "$WRAPPER" write ggp300  0 5 "great-gp"
  "$WRAPPER" write gp300b  0 4 "gp 300b"  ggp300
  "$WRAPPER" write p300b   0 3 "parent 300b" gp300b
  "$WRAPPER" write gc300b  1 1 "gc 300b"   p300b
  run "$WRAPPER" complete gc300b
  [ "$status" -eq 0 ]
  p_cur=$(jq -r .current "$TEST_PROGRESS_DIR/p300b.json")
  [ "$p_cur" = "1" ]
  gp_cur=$(jq -r .current "$TEST_PROGRESS_DIR/gp300b.json")
  [ "$gp_cur" = "1" ]
  ggp_cur=$(jq -r .current "$TEST_PROGRESS_DIR/ggp300.json")
  [ "$ggp_cur" = "1" ]
}

@test "300: propagate_up caps at grandparent total" {
  "$WRAPPER" write gp300c 2 2 "grandparent full"
  "$WRAPPER" write p300c  0 1 "parent 300c"   gp300c
  "$WRAPPER" write gc300c 1 1 "gc 300c" p300c
  run "$WRAPPER" complete gc300c
  [ "$status" -eq 0 ]
  gp_cur=$(jq -r .current "$TEST_PROGRESS_DIR/gp300c.json")
  [ "$gp_cur" = "2" ]
}

@test "300: idempotent - grandparent not re-incremented" {
  "$WRAPPER" write gp300d 0 3 "grandparent 300d"
  "$WRAPPER" write p300d  0 2 "parent 300d"      gp300d
  "$WRAPPER" write gc300d 1 1 "gc 300d"  p300d
  "$WRAPPER" complete gc300d
  gp_a=$(jq -r .current "$TEST_PROGRESS_DIR/gp300d.json")
  [ "$gp_a" = "1" ]
  run "$WRAPPER" complete gc300d
  [ "$status" -eq 0 ]
  gp_b=$(jq -r .current "$TEST_PROGRESS_DIR/gp300d.json")
  [ "$gp_b" = "1" ]
}

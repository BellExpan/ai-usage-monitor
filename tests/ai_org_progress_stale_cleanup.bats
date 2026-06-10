#!/usr/bin/env bats
# tests/ai_org_progress_stale_cleanup.bats
#
# Issue #489 — stale pin 自動クリア / completed=false の24h非表示
#
# テスト対象:
#   1. cleanup-stale [HOURS] サブコマンド
#   2. --short で completed=false の stale pin が非表示になること
#   3. show で completed=false の stale pin が非表示になること

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-bats-stale-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=86400
  WRAPPER="$SCRIPT"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# 古い時刻の JSON を直接書き込むヘルパー
write_stale_json() {
  local id=$1 age_sec=$2 label=${3:-stale-job}
  local old_ts
  old_ts=$(( $(date +%s) - age_sec ))
  cat > "$TEST_PROGRESS_DIR/${id}.json" <<JSON
{"current":2,"total":5,"label":"${label}","updated":${old_ts},"started":${old_ts},"completed":false}
JSON
}

# ──────────────────────────────────────────────────────────────
# cleanup-stale サブコマンド
# ──────────────────────────────────────────────────────────────

@test "cleanup-stale: 24h 超の completed=false を削除する" {
  write_stale_json old-job 90000  # 25時間前
  [ -f "$TEST_PROGRESS_DIR/old-job.json" ]

  run "$WRAPPER" cleanup-stale 24
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/old-job.json" ]
}

@test "cleanup-stale: 24h 未満は削除しない" {
  write_stale_json fresh-job 3600  # 1時間前
  [ -f "$TEST_PROGRESS_DIR/fresh-job.json" ]

  run "$WRAPPER" cleanup-stale 24
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/fresh-job.json" ]
}

@test "cleanup-stale: デフォルト (引数なし) は 24h 超を削除" {
  write_stale_json default-old 90000
  write_stale_json default-fresh 3600

  run "$WRAPPER" cleanup-stale
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/default-old.json" ]
  [ -f "$TEST_PROGRESS_DIR/default-fresh.json" ]
}

@test "cleanup-stale: カスタム HOURS=1 で 1h 超を削除" {
  write_stale_json old-1h 7200    # 2時間前
  write_stale_json fresh-30m 1800 # 30分前

  run "$WRAPPER" cleanup-stale 1
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/old-1h.json" ]
  [ -f "$TEST_PROGRESS_DIR/fresh-30m.json" ]
}

@test "cleanup-stale: HOURS に非整数を渡すと exit 2" {
  run "$WRAPPER" cleanup-stale abc
  [ "$status" -eq 2 ]
}

@test "cleanup-stale: ジョブが 0 件でも exit 0" {
  run "$WRAPPER" cleanup-stale 24
  [ "$status" -eq 0 ]
}

@test "cleanup-stale: completed=true の 24h 超ジョブも削除する" {
  local old_ts
  old_ts=$(( $(date +%s) - 90000 ))
  cat > "$TEST_PROGRESS_DIR/old-done.json" <<JSON
{"current":5,"total":5,"label":"done","updated":${old_ts},"started":${old_ts},"completed":true}
JSON

  run "$WRAPPER" cleanup-stale 24
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/old-done.json" ]
}

# ──────────────────────────────────────────────────────────────
# --short での stale 非表示 (STALE_HIDE_SEC)
# ──────────────────────────────────────────────────────────────

@test "--short: completed=false の stale pin が非表示になる" {
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=3600  # 1時間に短縮
  write_stale_json stale-pin 7200             # 2時間前 → stale

  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale-pin"* ]]
}

@test "--short: completed=false の fresh pin は表示される" {
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=86400
  write_stale_json fresh-pin 60  # 1分前 → fresh

  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"fresh-pin"* ]]
}

# ──────────────────────────────────────────────────────────────
# show での stale 非表示
# ──────────────────────────────────────────────────────────────

@test "show: completed=false の stale pin が非表示" {
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=3600
  write_stale_json stale-show 7200

  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" != *"stale-show"* ]]
}

@test "show: completed=false の fresh pin は表示される" {
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=86400
  write_stale_json show-fresh 60

  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"show-fresh"* ]]
}

@test "INCLUDE_COMPLETED=1 で stale も表示される" {
  export AI_ORG_PROGRESS_STALE_HIDE_SEC=3600
  export INCLUDE_COMPLETED=1
  write_stale_json stale-force 7200

  run "$WRAPPER" --short --include-completed
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-force"* ]]
}

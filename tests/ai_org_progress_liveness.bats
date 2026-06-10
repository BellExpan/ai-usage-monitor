#!/usr/bin/env bats
# tests/ai_org_progress_liveness.bats
#
# Issue #645 — liveness-aware healthcheck + 自動 reap
#
# 背景:
#   従来 stuck_marker は updated の鮮度 (90s) だけで "⚠️ stuck?" を出し、
#   タスクが実際に生きているかを見ていなかった。その結果:
#     - 死んだ孤児 pin が STALE_HIDE_SEC(24h) まで "stuck?" 表示で残る
#     - 生きている長時間タスクも誤って stuck 判定される
#   本テストは pin に liveness anchor (pid / agent_file) を持たせ、
#   死活判定と自動 reap が機能することを検証する。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/ai-org-progress.sh"
  [ -f "$SCRIPT" ] || skip "scripts/ai-org-progress.sh not found"

  TEST_PROGRESS_DIR="$(mktemp -d -t ai-org-progress-bats-liveness-XXXXXX)"
  export AI_ORG_PROGRESS_DIR_OVERRIDE="$TEST_PROGRESS_DIR"
  export AI_ORG_PROGRESS_ORPHAN_HIDE_SEC=1800
  export AI_ORG_PROGRESS_LIVENESS_FRESH_SEC=120
  WRAPPER="$SCRIPT"
}

teardown() {
  if [ -n "${TEST_PROGRESS_DIR:-}" ] && [ -d "$TEST_PROGRESS_DIR" ]; then
    rm -rf "$TEST_PROGRESS_DIR"
  fi
}

# 任意の age・anchor で JSON を直接生成するヘルパー
# write_json <id> <age_sec> <completed> [extra_json]
write_json() {
  local id=$1 age=$2 completed=${3:-false} extra=${4:-}
  local ts; ts=$(( $(date +%s) - age ))
  local base="{\"current\":2,\"total\":5,\"label\":\"job-${id}\",\"updated\":${ts},\"started\":${ts},\"completed\":${completed}"
  if [ -n "$extra" ]; then base="${base},${extra}"; fi
  echo "${base}}" > "$TEST_PROGRESS_DIR/${id}.json"
}

# ──────────────────────────────────────────────────────────────
# 1. write --pid / --agent-file が JSON に anchor を記録する
# ──────────────────────────────────────────────────────────────

@test "write --pid: pin JSON に pid が記録される" {
  run "$WRAPPER" write anchored-pid 1 3 "test" --pid 12345
  [ "$status" -eq 0 ]
  run jq -r '.pid' "$TEST_PROGRESS_DIR/anchored-pid.json"
  [ "$output" = "12345" ]
}

@test "write --agent-file: pin JSON に agent_file が記録される" {
  run "$WRAPPER" write anchored-agent 1 3 "test" --agent-file /tmp/agent-x.jsonl
  [ "$status" -eq 0 ]
  run jq -r '.agent_file' "$TEST_PROGRESS_DIR/anchored-agent.json"
  [ "$output" = "/tmp/agent-x.jsonl" ]
}

@test "write: flag なしは従来どおり positional で動作 (後方互換)" {
  run "$WRAPPER" write legacy 1 3 "legacy label" some-parent
  [ "$status" -eq 0 ]
  run jq -r '.parent' "$TEST_PROGRESS_DIR/legacy.json"
  [ "$output" = "some-parent" ]
}

@test "write: 再 write 時に既存 pid を保持する (flag 省略時)" {
  "$WRAPPER" write keep-pid 1 3 "test" --pid 999
  "$WRAPPER" write keep-pid 2 3 "test更新"
  run jq -r '.pid' "$TEST_PROGRESS_DIR/keep-pid.json"
  [ "$output" = "999" ]
}

@test "write --pid: 非整数 pid は exit 2" {
  run "$WRAPPER" write bad-pid 1 3 "test" --pid abc
  [ "$status" -eq 2 ]
}

# ──────────────────────────────────────────────────────────────
# 2. reap: 死んだ anchor / anchorless 孤児を削除、生存・completed は残す
# ──────────────────────────────────────────────────────────────

@test "reap: pid が死んでいる non-completed pin を削除する" {
  # 確実に存在しない pid (kill -0 が失敗)
  write_json dead-pid 30 false '"pid":2147480000'
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/dead-pid.json" ]
}

@test "reap: pid が生きている pin は残す (短い更新間隔でも)" {
  # 自分自身の親シェル pid は生存中
  write_json alive-pid 9999 false "\"pid\":$$"
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/alive-pid.json" ]
}

@test "reap: EPERM (別ユーザー所有 pid=1) は alive 扱いで温存 (HIGH-1)" {
  # pid 1 = launchd (root 所有)。非root では kill -0 が EPERM。dead 誤判定しない
  write_json eperm-pid 9999 false '"pid":1'
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/eperm-pid.json" ]
}

@test "reap: 死んだ pid でも agent_file が fresh なら温存 (HIGH-2 フォールスルー)" {
  local af="$TEST_PROGRESS_DIR/agent-h2.jsonl"
  echo '{}' > "$af"   # fresh
  write_json h2 9999 false "\"pid\":2147480000,\"agent_file\":\"${af}\""
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/h2.json" ]
}

@test "reap: agent_file が消えている pin を削除する" {
  write_json dead-agent 30 false '"agent_file":"/nonexistent/agent-zzz.jsonl"'
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/dead-agent.json" ]
}

@test "reap: agent_file が stale でも pin が新しければ温存 (MEDIUM-1: 長時間単一ツール実行の false dead 防止)" {
  # 長い build 中の subagent を模す: jsonl は古い(凍結)が pin update は最近
  local af="$TEST_PROGRESS_DIR/agent-busy.jsonl"
  echo '{}' > "$af"
  local old; old=$(( $(date +%s) - 600 ))   # jsonl mtime 600s 前
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S)" "$af" 2>/dev/null || true
  write_json busy 300 false "\"agent_file\":\"${af}\""   # pin updated 300s 前 (< ORPHAN 1800)
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/busy.json" ]   # unknown 扱い → 孤児タイマー未満なので温存
}

@test "reap: agent_file stale かつ pin も ORPHAN 超なら reap (孤児確定)" {
  local af="$TEST_PROGRESS_DIR/agent-old.jsonl"
  echo '{}' > "$af"
  local old; old=$(( $(date +%s) - 3000 ))
  touch -t "$(date -r "$old" +%Y%m%d%H%M.%S)" "$af" 2>/dev/null || true
  write_json longgone 2400 false "\"agent_file\":\"${af}\""  # pin 2400s > ORPHAN 1800
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/longgone.json" ]
}

@test "reap: agent_file の mtime が新しい pin は残す" {
  local af="$TEST_PROGRESS_DIR/agent-live.jsonl"
  echo '{}' > "$af"   # 今作った = mtime fresh
  write_json live-agent 9999 false "\"agent_file\":\"${af}\""
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/live-agent.json" ]
}

@test "reap: anchorless で ORPHAN_HIDE_SEC 超の孤児を削除する" {
  write_json orphan 2000 false  # 2000s > 1800
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/orphan.json" ]
}

@test "reap: anchorless でも ORPHAN_HIDE_SEC 未満は残す" {
  write_json fresh-orphan 300 false  # 300s < 1800
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/fresh-orphan.json" ]
}

@test "reap: completed=true は reap しない (hide ロジックに委譲)" {
  write_json done-old 9999 true  # 古い完了 pin
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROGRESS_DIR/done-old.json" ]
}

@test "reap: ジョブ 0 件でも exit 0" {
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
}

# ──────────────────────────────────────────────────────────────
# 3. status_marker: completed / liveness を考慮した表示
# ──────────────────────────────────────────────────────────────

@test "show: completed pin は '⚠️ stuck?' を表示しない" {
  # completed=true かつ更新が古い → 従来は stuck? と誤表示。INCLUDE_COMPLETED で可視化
  write_json done-pin 9999 true
  export INCLUDE_COMPLETED=1
  run "$WRAPPER" show --include-completed
  [ "$status" -eq 0 ]
  [[ "$output" == *"done-pin"* ]]
  [[ "$output" != *"stuck"* ]]
}

@test "show: pid 生存 pin は更新が古くても 'running' で stuck 表示しない" {
  write_json long-task 9999 false "\"pid\":$$"
  run "$WRAPPER" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"long-task"* ]]
  [[ "$output" != *"stuck"* ]]
}

@test "--short: pid 生存の長時間タスクは表示維持される (reap/hide されない)" {
  write_json long-alive 9999 false "\"pid\":$$"
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"long-alive"* ]]
}

@test "--short: anchorless 孤児 (ORPHAN_HIDE_SEC 超) は非表示" {
  write_json hidden-orphan 2000 false
  run "$WRAPPER" --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"hidden-orphan"* ]]
}

# ──────────────────────────────────────────────────────────────
# 4. set-anchor: 既存 pin に anchor を後付けマージ
# ──────────────────────────────────────────────────────────────

@test "set-anchor --agent-file: 既存 pin に agent_file を追加する (他フィールド保持)" {
  "$WRAPPER" write existing 2 5 "既存ジョブ" some-parent
  run "$WRAPPER" set-anchor existing --agent-file /tmp/agent-y.jsonl
  [ "$status" -eq 0 ]
  run jq -r '.agent_file' "$TEST_PROGRESS_DIR/existing.json"
  [ "$output" = "/tmp/agent-y.jsonl" ]
  run jq -r '.label' "$TEST_PROGRESS_DIR/existing.json"
  [ "$output" = "既存ジョブ" ]
  run jq -r '.parent' "$TEST_PROGRESS_DIR/existing.json"
  [ "$output" = "some-parent" ]
}

@test "set-anchor --pid: 既存 pin に pid を追加する" {
  "$WRAPPER" write existing2 1 3 "test"
  run "$WRAPPER" set-anchor existing2 --pid 4242
  [ "$status" -eq 0 ]
  run jq -r '.pid' "$TEST_PROGRESS_DIR/existing2.json"
  [ "$output" = "4242" ]
}

@test "set-anchor: 存在しない pin は exit 2" {
  run "$WRAPPER" set-anchor nonexistent --pid 1
  [ "$status" -eq 2 ]
}

@test "set-anchor: anchor 付与後 reap が liveness を反映する (dead agent_file → reap)" {
  "$WRAPPER" write soon-dead 1 3 "test"
  "$WRAPPER" set-anchor soon-dead --agent-file /nonexistent/agent-gone.jsonl
  run "$WRAPPER" reap
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROGRESS_DIR/soon-dead.json" ]
}

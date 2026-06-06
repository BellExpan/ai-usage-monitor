#!/usr/bin/env bats
# Tests for per-job background progress statusline segment (Issues #44, #46)
# Run: bats tests/statusline-bg-status.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/bg-status.sh
  source "$REPO_ROOT/scripts/lib/bg-status.sh"
  unset CLAUDE_BG_STATUS_FILE
  export CLAUDE_BG_STATUS_DIR
  CLAUDE_BG_STATUS_DIR="$(mktemp -d)"
  TEST_PROJECT="$(mktemp -d)"
  cd "$TEST_PROJECT" || return 1
}

teardown() {
  cd / || true
  rm -rf "$CLAUDE_BG_STATUS_DIR" "$TEST_PROJECT"
  unset CLAUDE_BG_STATUS_DIR CLAUDE_BG_STATUS_FILE CLAUDE_BG_STATUS_FRESH_SECS \
        CLAUDE_BG_STATUS_MAX_JOBS CLAUDE_BG_STATUS_MAX_CHARS
}

# ---- set / 基本 ----

@test "set writes a key file under the project dir" {
  bg_status_set "ci" "CI 3/5 passing"
  [ -f "$(bg_status_projdir)/ci.txt" ]
  [ "$(cat "$(bg_status_projdir)/ci.txt")" = "CI 3/5 passing" ]
}

@test "set fails on empty message" {
  run bg_status_set "ci" ""
  [ "$status" -ne 0 ]
}

@test "render shows a single fresh job" {
  bg_status_set "ci" "CI 3/5 passing"
  run bg_status_render
  [ "$status" -eq 0 ]
  [[ "$output" == "⏳ CI 3/5 passing" ]]
}

# ---- #46: 複数 job 集約 ----

@test "render aggregates multiple fresh jobs joined with separator" {
  bg_status_set "ci" "CI 3/5"
  bg_status_set "e2e" "E2E 2/4"
  run bg_status_render
  [[ "$output" == *"CI 3/5"* ]]
  [[ "$output" == *"E2E 2/4"* ]]
  [[ "$output" == *" · "* ]]
}

@test "render caps at MAX_JOBS and shows +N overflow" {
  export CLAUDE_BG_STATUS_MAX_JOBS=2
  bg_status_set "a" "JOBA"
  bg_status_set "b" "JOBB"
  bg_status_set "c" "JOBC"
  bg_status_set "d" "JOBD"
  run bg_status_render
  [[ "$output" == *"+2"* ]]   # 4件中2件表示 → +2
}

@test "render shows only fresh jobs, hides stale ones" {
  bg_status_set "fresh" "FRESH JOB"
  bg_status_set "stale" "STALE JOB"
  export CLAUDE_BG_STATUS_FRESH_SECS=1
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M)" \
    "$(bg_status_projdir)/stale.txt"
  run bg_status_render
  [[ "$output" == *"FRESH JOB"* ]]
  [[ "$output" != *"STALE JOB"* ]]
}

# ---- clear ----

@test "clear <key> removes only that job" {
  bg_status_set "ci" "CI"
  bg_status_set "e2e" "E2E"
  bg_status_clear "ci"
  run bg_status_render
  [[ "$output" != *"CI"* ]]
  [[ "$output" == *"E2E"* ]]
}

@test "clear with no key clears all jobs" {
  bg_status_set "ci" "CI"
  bg_status_set "e2e" "E2E"
  bg_status_clear
  run bg_status_render
  [ -z "$output" ]
}

# Codex #6: clear はファイル削除（空化ではない）で残骸を残さない
@test "clear <key> removes the key file (no residue)" {
  bg_status_set "ci" "CI"
  [ -f "$(bg_status_projdir)/ci.txt" ]
  bg_status_clear "ci"
  [ ! -e "$(bg_status_projdir)/ci.txt" ]
}

# Codex #6: render は dir モードで stale ファイルを reap（蓄積防止）
@test "render reaps stale files in dir mode" {
  bg_status_set "old" "OLD"
  export CLAUDE_BG_STATUS_FRESH_SECS=1
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || date -d '1 hour ago' +%Y%m%d%H%M)" \
    "$(bg_status_projdir)/old.txt"
  run bg_status_render
  [ ! -e "$(bg_status_projdir)/old.txt" ]   # stale は reap される
}

# Codex #5: render の集約順は key 昇順で安定（flicker しない）
@test "render aggregation order is stable (key ascending)" {
  bg_status_set "zeta" "ZZZ"
  bg_status_set "alpha" "AAA"
  run bg_status_render
  [[ "$output" == "⏳ AAA · ZZZ" ]]   # alpha が先（key 昇順）
}

# ---- 表示なしケース ----

@test "render hides when project dir is absent" {
  run bg_status_render
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "render hides empty message file" {
  mkdir -p "$(bg_status_projdir)"
  : > "$(bg_status_projdir)/x.txt"
  run bg_status_render
  [ -z "$output" ]
}

@test "render hides future-dated job (age >= 0 guard)" {
  bg_status_set "ci" "future"
  touch -t "$(date -v+1H +%Y%m%d%H%M 2>/dev/null || date -d '1 hour' +%Y%m%d%H%M)" \
    "$(bg_status_projdir)/ci.txt"
  run bg_status_render
  [ -z "$output" ]
}

# ---- 安全性 ----

@test "render strips backslash escapes and control chars (ANSI injection)" {
  bg_status_set "ci" "$(printf 'CI \\033[31mFAKE \\c gone')"
  run bg_status_render
  [[ "$output" == *"⏳ CI"* ]]
  [[ "$output" != *'\033'* ]]
  [[ "$output" != *'\c'* ]]
}

@test "render truncates very long combined output" {
  export CLAUDE_BG_STATUS_MAX_CHARS=120
  bg_status_set "a" "$(printf 'x%.0s' $(seq 1 200))"
  bg_status_set "b" "$(printf 'y%.0s' $(seq 1 200))"
  run bg_status_render
  [ "${#output}" -lt 160 ]
  [[ "$output" == *"…"* ]]
}

@test "render falls back to default fresh window on non-numeric value" {
  bg_status_set "ci" "fresh job"
  export CLAUDE_BG_STATUS_FRESH_SECS="abc"
  run bg_status_render
  [[ "$output" == *"⏳ fresh job"* ]]
}

@test "dot-prefixed key is not hidden as a dotfile (render + clear work)" {
  bg_status_set ".ci" "dotty"
  run bg_status_render
  [[ "$output" == *"dotty"* ]]        # render に出る（dotfile 漏れしない）
  bg_status_clear
  run bg_status_render
  [ -z "$output" ]                     # 全消し clear で残骸なし
}

@test "MAX_JOBS=0 is clamped to show at least one job" {
  export CLAUDE_BG_STATUS_MAX_JOBS=0
  bg_status_set a "AAA"
  run bg_status_render
  [[ "$output" == *"AAA"* ]]
  [[ "$output" != *"⏳  "* ]]          # 空本体 "⏳  +N" にならない
}

@test "job key with path traversal is sanitized (stays inside project dir)" {
  bg_status_set "../../../etc/passwd" "evil"
  local dir count
  dir="$(bg_status_projdir)"
  # 生成ファイルは projdir 配下に1件だけ（外部へエスケープしない）
  count=$(ls "$dir"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
  # /etc/passwd.txt のような外部書き込みが起きていない
  [ ! -e /etc/passwd.txt ]
  # 解決された keyfile が projdir 配下に収まっている
  [[ "$(bg_status_file "../../../etc/passwd")" == "$dir/"*.txt ]]
}

# ---- レガシー単一ファイル互換 ----

@test "legacy CLAUDE_BG_STATUS_FILE single-file mode works" {
  export CLAUDE_BG_STATUS_FILE
  CLAUDE_BG_STATUS_FILE="$(mktemp -u)"
  bg_status_set "ignored-key" "legacy msg"
  [ "$(cat "$CLAUDE_BG_STATUS_FILE")" = "legacy msg" ]
  run bg_status_render
  [[ "$output" == "⏳ legacy msg" ]]
  bg_status_clear
  run bg_status_render
  [ -z "$output" ]
  rm -f "$CLAUDE_BG_STATUS_FILE"
}

# ---- プロジェクトスコープ ----

@test "project dir differs by cwd" {
  local d1 d2 p1 p2
  d1="$(mktemp -d)"; d2="$(mktemp -d)"
  p1="$(cd "$d1" && bg_status_projdir)"
  p2="$(cd "$d2" && bg_status_projdir)"
  [ "$p1" != "$p2" ]
  [[ "$p1" == "$CLAUDE_BG_STATUS_DIR/"* ]]
  rm -rf "$d1" "$d2"
}

# ---- CLI ----

@test "CLI set <key> <message> writes keyed job" {
  "$REPO_ROOT/scripts/bg-status.sh" set ci "CI 3/5"
  [ "$(cat "$(bg_status_projdir)/ci.txt")" = "CI 3/5" ]
}

@test "CLI set <message> uses default key (backward compatible)" {
  "$REPO_ROOT/scripts/bg-status.sh" set "just a message"
  [ "$(cat "$(bg_status_projdir)/default.txt")" = "just a message" ]
}

@test "CLI clear <key> then clear all" {
  "$REPO_ROOT/scripts/bg-status.sh" set ci "CI"
  "$REPO_ROOT/scripts/bg-status.sh" set e2e "E2E"
  "$REPO_ROOT/scripts/bg-status.sh" clear ci
  run bg_status_render
  [[ "$output" != *"CI"* ]]
  [[ "$output" == *"E2E"* ]]
  "$REPO_ROOT/scripts/bg-status.sh" clear
  run bg_status_render
  [ -z "$output" ]
}

@test "CLI set with no args exits non-zero" {
  run "$REPO_ROOT/scripts/bg-status.sh" set
  [ "$status" -ne 0 ]
}

@test "CLI unknown subcommand exits non-zero" {
  run "$REPO_ROOT/scripts/bg-status.sh" bogus
  [ "$status" -ne 0 ]
}

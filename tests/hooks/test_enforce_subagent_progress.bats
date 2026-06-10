#!/usr/bin/env bats
# test_enforce_subagent_progress.bats — 回帰テスト for .claude/hooks/enforce_subagent_progress.sh
#
# Issue #74: bypass 強化
#   1. matcher が `ai-org-progress (write|clear|complete)` で広すぎ。
#      `clear` だけ書けば通過 (Codex MEDIUM 指摘)
#   2. prompt 内の bash コードブロック以外の文字列リテラル
#      (echo "ai-org-progress write..." 等) でも grep が通過 (Engineer B 指摘)
#
# 修正方針:
#   (a) bash コードブロック (```bash ... ```) を抽出してから判定
#   (b) 必須コマンドを `write` 限定に絞る (`clear/complete` は追加許可だが必須要件にしない)
#   (c) 行頭判定 `^[[:space:]]*ai-org-progress[[:space:]]+write`
#
# Phase 2: [QUICK_TASK] エスケープのロギング (#55)
# Phase 3: ## 進捗 pin セクション構造検出 (#55)
#
# 実行: bats tests/hooks/test_enforce_subagent_progress.bats

# Issue #645: ai-usage-monitor に移管。hook は repo の hooks/ 直下。
HOOK="${BATS_TEST_DIRNAME}/../../hooks/enforce-subagent-progress.sh"

setup() {
  ORIG_HOME="$HOME"
  export HOME="$(mktemp -d)"
}

teardown() {
  export HOME="$ORIG_HOME"
}

# JSON helper: PreToolUse Agent 入力形式
make_input() {
  local prompt="$1"
  local desc="${2:-test agent}"
  jq -n --arg p "$prompt" --arg d "$desc" \
    '{tool_name:"Task", tool_input:{prompt:$p, description:$d}}'
}

# ---------- 正常系: 通過すべきケース ----------

@test "valid: bash code block with ai-org-progress write at line start passes" {
  prompt='## 進捗 pin
```bash
ai-org-progress write task1 0 3 "開始"
ai-org-progress write task1 1 3 "Step 1"
ai-org-progress write task1 3 3 "完了"
ai-org-progress complete task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "valid: bash code block with absolute path passes" {
  prompt='```bash
$HOME/.local/bin/ai-org-progress write t 0 1 "start"
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "valid: QUICK_TASK escape hatch passes" {
  prompt='[QUICK_TASK] 30秒で終わるタスク。一瞬で grep するだけ。'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "valid: empty prompt passes (nothing to enforce)" {
  prompt=''
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

# ---------- 異常系: bypass を塞ぐ (RED → GREEN) ----------

@test "deny bypass 1: 'ai-org-progress clear' alone (Codex MEDIUM)" {
  # clear だけで通過していたバグ。write 必須化で deny されるべき
  prompt='```bash
ai-org-progress clear task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny bypass 1b: 'ai-org-progress complete' alone" {
  # complete だけで通過していたバグ (template 版)
  prompt='```bash
ai-org-progress complete task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny bypass 2: literal string 'ai-org-progress write' inside echo (Engineer B)" {
  # コードブロック外の文字列リテラルですり抜けていた
  prompt='instructions: echo "ai-org-progress write foo" >> readme.md'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny bypass 2b: prose mention without code block" {
  prompt='Please remember to call ai-org-progress write at each step.'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny bypass 2c: inline code (single backticks) does not count" {
  # bash コードブロック (```) でないと通過しない
  prompt='Use `ai-org-progress write` to track progress.'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny: no progress mention at all" {
  prompt='普通のタスク。bug fix してください。'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "deny: ai-org-progress not at line start (e.g. preceded by '# example: ')" {
  # コメント行内に書いてあるだけでは通過しない
  prompt='```bash
# example: ai-org-progress write t 0 1 "x"
echo hello
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

# ---------- Phase 2: [QUICK_TASK] エスケープのロギング ----------

@test "phase2: QUICK_TASK escape is logged to quick_task_escapes.log" {
  local log_file="$HOME/.claude/logs/quick_task_escapes.log"
  local before_size=0
  [[ -f "$log_file" ]] && before_size=$(wc -c < "$log_file")
  prompt="[QUICK_TASK] クイックチェックタスク"
  run bash -c "echo '$(make_input "$prompt" "phase2-size-test")' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$log_file" ]
  local after_size
  after_size=$(wc -c < "$log_file")
  [ "$after_size" -gt "$before_size" ]
}

@test "phase2: QUICK_TASK log entry contains desc" {
  local log_file="$HOME/.claude/logs/quick_task_escapes.log"
  prompt="[QUICK_TASK] ログ内容確認"
  run bash -c "echo '$(make_input "$prompt" "uniq-desc-marker-xyz")' | '$HOOK'"
  [ "$status" -eq 0 ]
  grep -q "uniq-desc-marker-xyz" "$log_file"
}

# ---------- Phase 3: ## 進捗 pin セクション構造検出 ----------

@test "phase3: section 進捗 pin with clear-only code block passes" {
  prompt='## 進捗 pin
```bash
ai-org-progress clear task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "phase3: section 進捗 pin with complete-only code block passes" {
  prompt='## 進捗 pin
```bash
ai-org-progress complete task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "phase3: section 進捗 pin with no code block denies" {
  prompt='## 進捗 pin
進捗はここに書きます。ai-org-progress write t 0 1 "x" とかする予定。'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "phase3: wrong header name does not trigger structural acceptance" {
  prompt='## 進捗管理
```bash
ai-org-progress clear task1
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "phase3: status-only subcommand in pin section denies (not a write-family command)" {
  prompt='## 進捗 pin
```bash
ai-org-progress status
```'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}


# ---------- Issue #284: ## 進捗 pin 検出を行頭 h2 限定に変更 ----------

@test "issue284: h3 header does NOT trigger section acceptance" {
  prompt=$(printf '### 進捗 pin\n```bash\nai-org-progress clear task1\n```')
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "issue284: comment line with ## 進捗 pin does NOT trigger section acceptance" {
  prompt=$(printf '```bash\necho done\n```\n# ## 進捗 pin の例を参照')
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "issue284: mid-line ## 進捗 pin in prose does NOT trigger section acceptance" {
  prompt='参照: ## 進捗 pin セクションを確認のこと'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "issue284: exact h2 進捗 pin at line start with write still passes" {
  prompt=$(printf '## 進捗 pin\n```bash\nai-org-progress write task1 0 1 start\n```')
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "issue284: h2 進捗 pin with trailing text at line start passes" {
  prompt=$(printf '## 進捗 pin required\n```bash\nai-org-progress write task1 0 1 start\n```')
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

# ---------- Issue #283: [QUICK_TASK] 先頭行・行頭限定 ----------

@test "issue283: [QUICK_TASK] on second line does NOT escape (deny)" {
  # 2行目以降の [QUICK_TASK] は escape hatch にならない
  prompt='Some task description here.
[QUICK_TASK] this should not escape
Do some work'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "issue283: [QUICK_TASK] at start of first line passes" {
  # 先頭行の行頭 [QUICK_TASK] は escape hatch として機能する
  prompt='[QUICK_TASK] 30秒で終わる調査タスク。'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "issue283: [QUICK_TASK] in middle of first line does NOT escape (deny)" {
  # 先頭行でも行頭でなければ escape hatch にならない
  prompt='Note: [QUICK_TASK] mentioned here but not at line start'
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
}

# ---------- Issue #285: regression test ----------

@test "issue285: deny message contains all 3 fix choices" {
  # Verify the deny error message includes all 3 remediation options
  local prompt="No progress pin in this prompt."
  run bash -c "echo '$(make_input "$prompt")' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"1."* ]] || { echo "missing option 1 in deny output"; false; }
  [[ "$output" == *"2."* ]] || { echo "missing option 2 in deny output"; false; }
  [[ "$output" == *"3."* ]] || { echo "missing option 3 in deny output"; false; }
}

# ---------- Issue #280: secret masking test ----------

@test "issue280: AWS key in description is masked in log (not leaked raw)" {
  # When QUICK_TASK escape is used, DESC written to log must have secrets masked
  local log_file="$HOME/.claude/logs/quick_task_escapes.log"
  local fake_key="AKIAIOSFODNN7EXAMPLE"
  local prompt="[QUICK_TASK] simple lookup task"
  local INPUT
  INPUT=$(jq -n --arg p "$prompt" --arg d "deploy key ${fake_key} end" \
    '{"tool_name":"Task","tool_input":{"prompt":$p,"description":$d}}')
  run bash -c "printf '%s' '$INPUT' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -f "$log_file" ]
  ! grep -q "$fake_key" "$log_file" \
    || { echo "raw key leaked in log"; false; }
  grep -q "MASKED_AWS_KEY" "$log_file" \
    || { echo "MASKED_AWS_KEY not found in log"; false; }
}

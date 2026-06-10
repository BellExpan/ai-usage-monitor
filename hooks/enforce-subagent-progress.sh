#!/bin/bash
# enforce_subagent_progress.sh — Agent (subagent dispatch) の prompt に進捗 pin が含まれているか強制
#
# オーナー指示 (2026-05-05): 「進捗がわかるプログレスバーや % って作れる？」+
#                            (本日 subagent が ai-org-progress write を無視 → status line 0% 固定問題)
#
# 検出: Agent tool の tool_input.prompt の bash コードブロック (```bash ... ```) 内に
#      行頭 `ai-org-progress write` 呼び出しがあるか
# 不在 → exit 2 で deny、prompt 改修を要求
#
# Issue #74 (2026-05-09): bypass 強化
#   1. matcher が `ai-org-progress (write|clear|complete)` で広すぎ。
#      `clear` だけ書けば通過していた (Codex MEDIUM #57 issuecomment-4379361281)
#   2. prompt 内の bash コードブロック以外の文字列リテラル
#      (echo "ai-org-progress write..." 等) でも grep が通過 (Engineer B #57 r3188458699)
#
# 修正:
#   (a) bash コードブロック (```bash ... ```) 内のみを対象に判定
#   (b) 必須コマンドを `write` 限定 (clear/complete はあっても write が無ければ deny)
#   (c) 行頭判定 `^[[:space:]]*(\$HOME/.local/bin/)?ai-org-progress[[:space:]]+write`
#
# Issue #55 Phase 2 (2026-05-09): [QUICK_TASK] エスケープのロギング
#   - escape hatch 使用時に ~/.claude/logs/quick_task_escapes.log に記録
#
# Issue #55 Phase 3 (2026-05-09): ## 進捗 pin セクション構造検出
#   - prompt に ## 進捗 pin セクションヘッダーがあり、
#     そのセクション内の bash コードブロックに ai-org-progress 呼び出し (write/clear/complete 等) があれば許可
#
# Issue #283 (2026-05-12): [QUICK_TASK] エスケープを先頭行・行頭限定に変更
#   - head -c 200 | grep '[QUICK_TASK]' → head -1 | grep -E '^[QUICK_TASK]'
#   - 2行目以降や行頭以外の [QUICK_TASK] では脱出できなくなった
#
# Issue #285 (2026-05-12): エラーメッセージに修正方法3択を追加
#   - deny 時に 1.bash-write / 2.pin-section / 3.QUICK_TASK の3択を表示
#
# Issue #280 (2026-05-12): PROMPT_PREVIEW シークレットマスキング
#   - ログ用 PROMPT_PREVIEW を sed でマスク (AKIA/ghp_/sk-/Bearer)

set -uo pipefail

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null)
DESC=$(printf '%s' "$INPUT" | jq -r '.tool_input.description // ""' 2>/dev/null)
# Issue #280: mask secrets in DESC_PREVIEW before logging
DESC_PREVIEW=$(printf '%s' "$DESC" | head -c 200 | sed \
  -e 's/AKIA[A-Z0-9]\{16\}/[MASKED_AWS_KEY]/g' \
  -e 's/ghp_[A-Za-z0-9]\{36\}/[MASKED_GH_PAT]/g' \
  -e 's/sk-[A-Za-z0-9]\{48\}/[MASKED_OPENAI_KEY]/g' \
  -e 's/Bearer [A-Za-z0-9._-]\{20,\}/Bearer [MASKED_TOKEN]/g' | tr '\n' ' ')

if [[ -z "$PROMPT" ]]; then
  exit 0
fi

# 短時間タスクの escape hatch (先に評価):
# prompt 冒頭に "[QUICK_TASK]" マーカーがあれば pin 不要 (30秒以内完結タスク用)
if printf '%s' "$PROMPT" | head -1 | grep -qE '^\[QUICK_TASK\]'; then
  # Phase 2: escape 使用をログに記録 (乱用・振り返り用)
  LOG_DIR="$HOME/.claude/logs"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # Issue #280: mask secrets in PROMPT_PREVIEW before logging (defensive for future debug logging)
  PROMPT_PREVIEW=$(printf '%s' "$PROMPT" | head -c 200 | sed \
    -e 's/AKIA[A-Z0-9]\{16\}/[MASKED_AWS_KEY]/g' \
    -e 's/ghp_[A-Za-z0-9]\{36\}/[MASKED_GH_PAT]/g' \
    -e 's/sk-[A-Za-z0-9]\{48\}/[MASKED_OPENAI_KEY]/g' \
    -e 's/Bearer [A-Za-z0-9._-]\{20,\}/Bearer [MASKED_TOKEN]/g' | tr '\n' ' ')
  printf '%s [QUICK_TASK] desc=%s preview=%s\n' \
    "$TIMESTAMP" "$DESC_PREVIEW" "$PROMPT_PREVIEW" \
    >> "$LOG_DIR/quick_task_escapes.log" 2>/dev/null || true
  exit 0
fi

# bash コードブロック (```bash ... ``` または ``` ... ```) を抽出してから判定
# awk で fenced code block 内だけ抜き出す (言語タグ任意)
CODE_BLOCKS=$(printf '%s' "$PROMPT" | awk '
  /^[[:space:]]*```/ {
    if (in_block) { in_block = 0; next }
    else { in_block = 1; next }
  }
  in_block { print }
')

# コードブロック内の行頭 (空白許容) ai-org-progress write 呼び出しを検出
# 絶対パス ($HOME/.local/bin/) も許容
if printf '%s' "$CODE_BLOCKS" | grep -qE '^[[:space:]]*(\$HOME/\.local/bin/)?ai-org-progress[[:space:]]+write[[:space:]]'; then
  exit 0
fi

# Phase 3: ## 進捗 pin セクション構造チェック
# ## 進捗 pin ヘッダーが存在し、そのセクション内に bash コードブロック +
# ai-org-progress 呼び出し (write/clear/complete/reset 限定) があれば許可
if printf '%s' "$PROMPT" | grep -qE '^## 進捗 pin'; then
  PIN_SECTION=$(printf '%s' "$PROMPT" | awk '
    /^## 進捗 pin/ { in_sec=1; next }
    in_sec && /^## / { in_sec=0 }
    in_sec { print }
  ')
  PIN_BLOCKS=$(printf '%s' "$PIN_SECTION" | awk '
    /^[[:space:]]*```/ {
      if (in_block) { in_block=0; next }
      else { in_block=1; next }
    }
    in_block { print }
  ')
  if printf '%s' "$PIN_BLOCKS" | grep -qE '^[[:space:]]*(\$HOME/\.local/bin/)?ai-org-progress[[:space:]]+(write|clear|complete|reset)([[:space:]]|$)'; then
    exit 0
  fi
fi

cat >&2 <<EOF
🚫 [hook enforce_subagent_progress] subagent prompt の bash コードブロック内に ai-org-progress write 呼び出しがない。
prompt に「\`\`\`bash ... ai-org-progress write <id> <cur> <total> "<label>" ... \`\`\`」を必ず含めること (clear/complete のみは不可、文字列リテラル/散文も不可)。
または ## 進捗 pin セクションに bash コードブロック + ai-org-progress 呼び出しを含める。
escape: 冒頭 [QUICK_TASK]。

修正方法（いずれか 1 つ）:
  1. bash コードブロック内に ai-org-progress write <task> <N> <M> "<msg>" を追加
  2. ## 進捗 pin セクション (h2 のみ) を追加し、bash ブロックで ai-org-progress write を呼ぶ
  3. 短時間タスクなら prompt の先頭行を行頭から [QUICK_TASK] <説明> にする (行頭以外は無効)
EOF

exit 2

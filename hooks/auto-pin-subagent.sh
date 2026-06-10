#!/bin/bash
# auto-pin-subagent-hook.sh — subagent dispatch 直後の代行 pin write
#
# 目的:
#   subagent prompt に書いた `ai-org-progress write <id> 0 <total> "<label>"` を hook 側で代行 write。
#   subagent が pin write を無視/サボる構造的失敗を防ぐ (memory: feedback_subagent_watch_required.md)。
#
# 想定配置:
#   1. このリポ正典: scripts/auto-pin-subagent-hook.sh (本ファイル)
#   2. 個人環境配置: ~/.claude/hooks/auto_pin_subagent.sh (本ファイルから cp で同期)
#
# 設定 (settings.json):
#   PostToolUse / matcher=Agent (Task tool 実行直後)
#     "PostToolUse": [
#       {
#         "matcher": "Agent",
#         "hooks": [{"type": "command", "command": "bash ~/.claude/hooks/auto_pin_subagent.sh"}]
#       }
#     ]
#
# 入出力:
#   stdin: PostToolUse の JSON ({input.prompt, tool_response.agentId, ...})
#   action: 該当 pin が無ければ /Users/bellspan/.local/bin/ai-org-progress write を代行実行
#   exit 0: hook 成功 (subagent 続行に影響なし)

set -uo pipefail

INPUT=$(cat)

# subagent prompt + agent_id を抽出
PROMPT=$(printf '%s' "$INPUT" | jq -r '.input.prompt // empty' 2>/dev/null)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.tool_response.agentId // empty' 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# prompt 内の `ai-org-progress write <id> 0 <total> "<label>"` を抽出 (1 件目のみ採用 = root pin)
PIN_LINE=$(printf '%s' "$PROMPT" | grep -oE 'ai-org-progress write [A-Za-z0-9._:-]+ 0 [0-9]+ "[^"]*"' | head -1)
[ -z "$PIN_LINE" ] && exit 0

# pin id 抽出 (例: "ai-org-progress write subagent-watch-followup-20260505 0 6 ...")
PIN_ID=$(printf '%s' "$PIN_LINE" | awk '{print $3}')
[ -z "$PIN_ID" ] && exit 0

AI_ORG_PROGRESS_BIN="/Users/bellspan/.local/bin/ai-org-progress"
[ ! -x "$AI_ORG_PROGRESS_BIN" ] && exit 0

# Issue #645: subagent の jsonl パスを agentId から解決し、liveness anchor にする。
# これにより pin は「jsonl mtime が古い = subagent 死亡」を死活判定でき、
# complete/clear 呼び忘れの孤児が ~LIVENESS_FRESH_SEC で自動 reap される。
AGENT_FILE=""
# MEDIUM-3: AGENT_ID は jq 由来だが防御的に形式検証 (英数 + . _ -)。
# パス解決は `ls` 出力パース (スペース/改行で壊れる) ではなく glob 直接展開を使う。
if [ -n "$AGENT_ID" ] && printf '%s' "$AGENT_ID" | grep -qE '^[A-Za-z0-9._-]+$'; then
  for _cand in "$HOME"/.claude/projects/*/*/subagents/agent-"$AGENT_ID".jsonl; do
    [ -f "$_cand" ] && AGENT_FILE="$_cand" && break
  done
fi

# 既に pin が存在 (= subagent 自身が write 済 or 他経路) → anchor だけ後付けする
if [ -f "/tmp/ai-org-progress/${PIN_ID}.json" ]; then
  if [ -n "$AGENT_FILE" ]; then
    "$AI_ORG_PROGRESS_BIN" set-anchor "$PIN_ID" --agent-file "$AGENT_FILE" 2>/dev/null || true
  fi
  exit 0
fi

# 代行 write (label は prompt のまま、引用符込みで eval) + anchor 付与
# 安全な eval: PIN_LINE は ai-org-progress write <id> <cur> <total> "<label>" 形式を grep -oE で抽出済み
# → 余計なメタ文字混入なし、command injection リスク低
if [ -n "$AGENT_FILE" ]; then
  eval "$AI_ORG_PROGRESS_BIN ${PIN_LINE#ai-org-progress } --agent-file \"$AGENT_FILE\"" 2>/dev/null || true
else
  eval "$AI_ORG_PROGRESS_BIN ${PIN_LINE#ai-org-progress }" 2>/dev/null || true
fi

exit 0

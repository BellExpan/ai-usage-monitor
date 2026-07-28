#!/bin/bash
# turn-state.sh — このターンが「実行中 / 要操作 / 終了」のどれかを記録する（Issue #42）
#
# なぜ必要か:
#   複数 terminal で Claude Code を並行運用すると、statusline を見ても
#   「このタブは終わったのか / bg タスクの完了待ちなのか」が判別できなかった。
#   bg 件数だけでは足りず、ターン状態が要る。この hook がその単一情報源を書く。
#
# 引数: $1 = busy | wait | idle
#   busy … ターン実行中          （UserPromptSubmit / PreToolUse）
#   wait … 許可待ち＝要操作      （Notification）
#   idle … ターン終了            （Stop）
#
# 出力: $CLAUDE_TURN_STATE_DIR（既定 ~/.claude/state）/turn-<session_id>.state
#       1 行 "<state> <epoch> <ITERM_SESSION_ID>"
#       描画は statusline 側が行う（bg 件数は時間で変わるため、イベント駆動の hook で
#       タイトルを焼くと 🔵 のまま固まる）。
#
# 設計: 常に exit 0（fail-open）。副作用は 1 行のファイル書き込みのみ。
set -u

STATE="${1:-idle}"
case "$STATE" in
  busy|wait|idle) ;;
  *) exit 0 ;;
esac

STATE_DIR="${CLAUDE_TURN_STATE_DIR:-$HOME/.claude/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

STDIN_DATA=""
[ -t 0 ] || STDIN_DATA="$(cat 2>/dev/null)"
SESSION_ID="$(printf '%s' "$STDIN_DATA" \
  | LC_ALL=C sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
# session_id はパス構成要素になるため、UUID 相当の文字だけ許す（path traversal 防止）
SESSION_ID="$(printf '%s' "$SESSION_ID" | LC_ALL=C tr -cd 'A-Za-z0-9-')"
[ -n "$SESSION_ID" ] || exit 0

TARGET="$STATE_DIR/turn-${SESSION_ID}.state"

# PreToolUse は毎ツール呼び出しで走るため、状態が変わらない時は書かない
if [ -f "$TARGET" ]; then
  PREV="$(LC_ALL=C awk 'NR==1{print $1}' "$TARGET" 2>/dev/null)"
  [ "$PREV" = "$STATE" ] && exit 0
fi

printf '%s %s %s\n' "$STATE" "$(date +%s)" "${ITERM_SESSION_ID:-}" > "$TARGET" 2>/dev/null || true
exit 0

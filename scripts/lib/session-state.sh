#!/bin/bash
# session-state.sh — Claude Code セッション単位の bg タスク集計 + ターン状態（Issue #42）
#
# なぜ必要か:
#   複数 terminal で Claude Code を並行運用すると、statusline の `⚡N bg` を見ても
#   「このterminalのタスクか / 終わったのか / bg で動いているのか」が判別できなかった。
#   原因は (a) bg 集計が全セッション再帰だったこと、(b) foreground の Bash tool 実行も
#   同じ `tasks/*.output` を作るため混入すること、(c) ターン状態が表示に無いこと。
#   このライブラリは (a)(c) を単一情報源として解決する。
#
# ターン状態の書き手: ~/.claude/hooks/claude-turn-state.sh（hook）
#   フォーマット: "<busy|wait|idle> <epoch> <ITERM_SESSION_ID>"
#
# 設計方針: 全関数 fail-open（対象が無ければ 0 / 空 / unknown を返して exit 0）。
#          環境変数は「呼び出し時」に解決する（テストから差し替え可能にするため）。

# テスト差し替え用フック
_ss_tasks_root() { printf '%s' "${CLAUDE_TASKS_ROOT:-/private/tmp/claude-$(id -u)}"; }
_ss_state_dir()  { printf '%s' "${CLAUDE_TURN_STATE_DIR:-$HOME/.claude/state}"; }
_ss_fresh_mins() {
  local m="${CLAUDE_BG_FRESH_MINS:-5}"
  case "$m" in ''|*[!0-9]*) m=5 ;; esac
  printf '%s' "$m"
}

# session_tasks_dir <session_id>
#   → そのセッションの tasks ディレクトリ絶対パス（無ければ空文字）
session_tasks_dir() {
  local sid="${1:-}" root d
  [ -n "$sid" ] || return 0
  root="$(_ss_tasks_root)"
  [ -d "$root" ] || return 0
  # レイアウト: <root>/<project-slug>/<session_id>/tasks/*.output
  d="$(find "$root" -maxdepth 2 -type d -name "$sid" 2>/dev/null | head -1)"
  [ -n "$d" ] || return 0
  [ -d "$d/tasks" ] || return 0
  printf '%s' "$d/tasks"
}

# session_bg_count <session_id>
#   → 自セッションの「直近 N 分に更新された」.output 件数
#   注意: foreground の Bash tool 実行中はその .output も 1 件数えられる。
#         ターン終了（idle）時点では foreground 分は削除済みなので、判断に使うのは idle 時の値。
session_bg_count() {
  local sid="${1:-}" dir n
  dir="$(session_tasks_dir "$sid")"
  [ -n "$dir" ] || { printf '0'; return 0; }
  n="$(find "$dir" -maxdepth 1 -name '*.output' -mmin "-$(_ss_fresh_mins)" 2>/dev/null | grep -c .)" || true
  printf '%s' "${n:-0}"
}

# session_other_bg_count <session_id>
#   → 他セッション（＝他 terminal）の bg 件数。消さずに別枠表示するため。
session_other_bg_count() {
  local sid="${1:-}" root total own diff
  root="$(_ss_tasks_root)"
  [ -d "$root" ] || { printf '0'; return 0; }
  total="$(find "$root" -name '*.output' -mmin "-$(_ss_fresh_mins)" 2>/dev/null | grep -c .)" || true
  own="$(session_bg_count "$sid")"
  diff=$(( ${total:-0} - ${own:-0} ))
  [ "$diff" -lt 0 ] && diff=0
  printf '%s' "$diff"
}

# turn_state_read <session_id> → busy | wait | idle | unknown
turn_state_read() {
  local sid="${1:-}" f s
  [ -n "$sid" ] || { printf 'unknown'; return 0; }
  f="$(_ss_state_dir)/turn-${sid}.state"
  [ -f "$f" ] || { printf 'unknown'; return 0; }
  s="$(LC_ALL=C awk 'NR==1{print $1}' "$f" 2>/dev/null)"
  case "$s" in
    busy|wait|idle) printf '%s' "$s" ;;
    *)              printf 'unknown' ;;
  esac
}

# turn_state_iterm_id <session_id> → iTerm2 セッション UUID（無ければ空）
turn_state_iterm_id() {
  local sid="${1:-}" f v
  [ -n "$sid" ] || return 0
  f="$(_ss_state_dir)/turn-${sid}.state"
  [ -f "$f" ] || return 0
  v="$(LC_ALL=C awk 'NR==1{print $3}' "$f" 2>/dev/null)"
  v="${v##*:}"   # w2t0p0:UUID → UUID
  printf '%s' "$(printf '%s' "$v" | LC_ALL=C tr -cd 'A-Za-z0-9-')"
}

# turn_banner <state> <own_bg_count> → statusline 行頭に出す状態バナー（色なし）
turn_banner() {
  local state="${1:-unknown}" bg="${2:-0}"
  case "$bg" in ''|*[!0-9]*) bg=0 ;; esac
  case "$state" in
    idle)
      if [ "$bg" -gt 0 ]; then
        printf '🔵 bg %s 実行中 — 完了で自動再開' "$bg"
      else
        printf '✅ 完了 — 入力待ち'
      fi
      ;;
    busy) printf '⏳ 実行中' ;;
    wait) printf '🔴 要操作 — 許可待ち' ;;
    *)    return 0 ;;
  esac
}

# session_title <state> <own_bg_count> <label> → iTerm2 タブタイトル
#   タブバーを見るだけで（terminal をフォーカスせずに）判別できることが本質。
session_title() {
  local state="${1:-unknown}" bg="${2:-0}" label="${3:-claude}"
  case "$bg" in ''|*[!0-9]*) bg=0 ;; esac
  # AppleScript 文字列に埋め込むため、引用符・バックスラッシュ・制御文字を除去
  label="$(printf '%s' "$label" | LC_ALL=C tr -d '\000-\037"\\')"
  label="${label:0:24}"
  [ -n "$label" ] || label="claude"
  case "$state" in
    busy) printf '⏳ %s' "$label" ;;
    wait) printf '🔴 %s 要操作' "$label" ;;
    idle)
      if [ "$bg" -gt 0 ]; then printf '🔵 %s ⚡%s' "$label" "$bg"
      else printf '✅ %s' "$label"; fi
      ;;
    *) printf '%s' "$label" ;;
  esac
}

# iterm_set_title <title> <iterm_session_id>
#   /dev/tty は Claude Code の子プロセスから届かない（制御端末を持たない）ため、
#   AppleScript で iTerm2 のセッションを id 直指定して更新する。
iterm_set_title() {
  local title="${1:-}" isid="${2:-}"
  [ -n "$isid" ] || return 0
  [ -n "$title" ] || return 0
  [ -x /usr/bin/osascript ] || return 0
  /usr/bin/osascript -e "tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is \"$isid\" then
            set name of s to \"$title\"
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell" >/dev/null 2>&1 || true
  return 0
}

# iterm_set_title_if_changed <title> <iterm_session_id>
#   statusline は数秒ごとに走るため、変化時のみ osascript を呼ぶ（~230ms を毎回払わない）。
iterm_set_title_if_changed() {
  local title="${1:-}" isid="${2:-}" dir cache prev
  [ -n "$isid" ] || return 0
  [ -n "$title" ] || return 0
  dir="$(_ss_state_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  cache="$dir/title-${isid}"
  prev="$(cat "$cache" 2>/dev/null || true)"
  [ "$prev" = "$title" ] && return 0
  printf '%s' "$title" > "$cache" 2>/dev/null || true
  iterm_set_title "$title" "$isid"
}

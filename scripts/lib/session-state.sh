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
# ターン状態の書き手: hooks/turn-state.sh（setup.sh が ~/.claude/hooks/claude_turn_state.sh へ install）
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

# _ss_sanitize_id <raw>
#   session_id / iTerm session id は「パス構成要素」と「AppleScript 文字列」の両方に埋まる。
#   入口を 1 箇所に集約し、UUID 相当の文字だけ通す（path traversal / AppleScript 注入の遮断）。
#   Codex レビュー指摘: statusline 側の stdin session_id と ITERM_SESSION_ID fallback が
#   サニタイズ漏れしていたため、各関数の入口で必ずこれを通す。
#   ITERM_SESSION_ID は `w2t0p0:<UUID>` 形式なので、`:` より前の pane 座標は先に落とす。
#   （session_id 側は `:` を含まないため無害。生の ITERM_SESSION_ID をそのまま渡しても
#     正しく <UUID> として扱われる＝入口の契約を sanitizer 1 箇所で担保する）
_ss_sanitize_id() {
  local raw="${1:-}"
  printf '%s' "${raw##*:}" | LC_ALL=C tr -cd 'A-Za-z0-9-' | cut -c1-64
}

# session_tasks_dir <session_id>
#   → そのセッションの tasks ディレクトリ絶対パス（無ければ空文字）
session_tasks_dir() {
  local sid root d
  sid="$(_ss_sanitize_id "${1:-}")"
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
  local sid root total own diff
  sid="$(_ss_sanitize_id "${1:-}")"
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
  local sid f s
  sid="$(_ss_sanitize_id "${1:-}")"
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
  local sid f v
  sid="$(_ss_sanitize_id "${1:-}")"
  [ -n "$sid" ] || return 0
  f="$(_ss_state_dir)/turn-${sid}.state"
  [ -f "$f" ] || return 0
  v="$(LC_ALL=C awk 'NR==1{print $3}' "$f" 2>/dev/null)"
  _ss_sanitize_id "$v"   # w2t0p0:UUID → UUID の正規化も sanitizer が担う
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

# state_glyph <state> <own_bg_count> → タブ名に前置する状態グリフ
#   ✅ 完了 / 🔵N bg待ち / ⏳ 実行中 / 🔴 要操作（unknown は空 = 何もしない）
state_glyph() {
  local state="${1:-unknown}" bg="${2:-0}"
  case "$bg" in ''|*[!0-9]*) bg=0 ;; esac
  case "$state" in
    idle) if [ "$bg" -gt 0 ]; then printf '🔵%s' "$bg"; else printf '✅'; fi ;;
    busy) printf '⏳' ;;
    wait) printf '🔴' ;;
    *)    return 0 ;;
  esac
}

# strip_state_prefix <name> → 既に付いている状態グリフを除去（多重付与の防止）
strip_state_prefix() {
  printf '%s' "${1:-}" | sed -E 's/^(✅|🔵[0-9]*|⏳|🔴)[[:space:]]*//'
}

# strip_job_suffix <name> → iTerm が表示時に付ける末尾 " (job名)" を除去
#   name を読んで書き戻す際、これを消さないと "(caffeinate) (caffeinate)" と多重化する。
#   既知の限界: iTerm2 AppleScript は job 名を単独取得できない（`job name` は存在しない）ため、
#   「空白なしの括弧トークンが末尾にある」という形で判定するしかない。
#   その結果、会話タイトルが "(v2)" のような短い括弧で終わる場合も剥がれる。
#   影響はタブ表示上その token が消えるだけ（会話・データには無影響）で、
#   剥がさない実装は (caffeinate) が無限に積み上がるためこちらが害が小さい。
strip_job_suffix() {
  printf '%s' "${1:-}" | sed -E 's/[[:space:]]+\([A-Za-z0-9_.:-]+\)$//'
}

# iterm_get_name <iterm_session_id> → 現在のタブ名（取得できなければ空）
iterm_get_name() {
  local isid
  isid="$(_ss_sanitize_id "${1:-}")"
  [ -n "$isid" ] || return 0
  [ -x /usr/bin/osascript ] || return 0
  /usr/bin/osascript -e "tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is \"$isid\" then return name of s
        end repeat
      end repeat
    end repeat
    return \"\"
  end tell" 2>/dev/null
}

# iterm_apply_state_prefix <glyph> <iterm_session_id>
#   Claude Code 自身がタブ名（会話の要約）を随時上書きするため、
#   「置き換え」ではなく「前置」し、毎回**実際のタブ名**を読んでから判断する。
#   自分が最後に書いた値をキャッシュ比較する方式だと、外部上書き後に
#   「変化なし」と誤判定して二度と復元しない（Issue #49 の真因）。
iterm_apply_state_prefix() {
  local glyph="${1:-}" isid cur base want
  isid="$(_ss_sanitize_id "${2:-}")"
  [ -n "$glyph" ] || return 0
  [ -n "$isid" ] || return 0
  cur="$(iterm_get_name "$isid")"
  [ -n "$cur" ] || return 0
  base="$(strip_job_suffix "$cur")"
  base="$(strip_state_prefix "$base")"
  [ -n "$base" ] || return 0
  want="${glyph} ${base}"
  # 既に望む形なら set を呼ばない（読み取りは毎回必要だが、書き込みは差分時のみ）
  [ "$(strip_job_suffix "$cur")" = "$want" ] && return 0
  # AppleScript 文字列に埋めるため引用符・バックスラッシュ・制御文字を除去
  want="$(printf '%s' "$want" | LC_ALL=C tr -d '\000-\037"\\')"
  [ -n "$want" ] || return 0
  /usr/bin/osascript -e "tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is \"$isid\" then
            set name of s to \"$want\"
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell" >/dev/null 2>&1 || true
  return 0
}

# ── ウィンドウタイトル（OSC 2）─────────────────────────────────────────
# なぜタブ名ではなくウィンドウタイトルなのか（Issue #51）:
#   1窓1タブ運用では iTerm2 がタブバーを隠すため、タブ名は**表示されない**。
#   実際に見えるのはウィンドウタイトル（最上部）だが、`set name of window` は
#   AppleScript から書けない（-10006）。`tty of session` を取得して OSC 2 を
#   直接書き込めば設定できる（実測）。
#
# Claude Code との住み分け:
#   実行中 = Claude Code が点字スピナーを毎フレーム書く（＝「動いている」は既に見える）
#   停止中 = 静止した `✳ <会話タイトル>` になる → ここに我々が「なぜ止まっているか」を前置する
#   よって busy の間は**何も書かない**（奪い合わない）。idle/wait のみ書く。

# iterm_tty <iterm_session_id> → そのセッションの tty デバイスパス（無ければ空）
iterm_tty() {
  local isid
  isid="$(_ss_sanitize_id "${1:-}")"
  [ -n "$isid" ] || return 0
  [ -x /usr/bin/osascript ] || return 0
  /usr/bin/osascript -e "tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is \"$isid\" then return tty of s
        end repeat
      end repeat
    end repeat
    return \"\"
  end tell" 2>/dev/null
}

# iterm_window_name <iterm_session_id> → そのセッションが属する窓のタイトル
iterm_window_name() {
  local isid
  isid="$(_ss_sanitize_id "${1:-}")"
  [ -n "$isid" ] || return 0
  [ -x /usr/bin/osascript ] || return 0
  /usr/bin/osascript -e "tell application \"iTerm2\"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if id of s is \"$isid\" then return name of w
        end repeat
      end repeat
    end repeat
    return \"\"
  end tell" 2>/dev/null
}

# strip_cc_marker <name> → Claude Code が停止中に付ける先頭マーカー `✳` を除去
#   前置後の見た目を `✅ ✳ 会話名` と二重にしないため。
#
#   点字スピナー（U+2800-28FF）は **実行中にしか出ず、実行中は我々が書かない**ので対象外。
#   sed のマルチバイト文字クラス `[⠀-⣿]` は GNU sed / C ロケールで動かず Linux CI が落ちた。
#   ここは shell のパターン削除（バイト厳密・ロケール非依存）で実装する。
strip_cc_marker() {
  local n="${1:-}"
  case "$n" in
    "✳ "*) n="${n#"✳ "}" ;;
    "✳"*)  n="${n#"✳"}"  ;;
  esac
  # 先頭に残った空白を落とす
  while :; do
    case "$n" in
      " "*|"	"*) n="${n#?}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$n"
}

# window_title_apply <state> <own_bg_count> <iterm_session_id>
#   停止中（idle/wait）のときだけ、ウィンドウタイトルへ状態を前置する。
window_title_apply() {
  local state="${1:-unknown}" bg="${2:-0}" isid glyph tty cur base want
  case "$state" in
    idle|wait) ;;
    *) return 0 ;;   # busy/unknown は Claude Code のスピナーに任せる
  esac
  isid="$(_ss_sanitize_id "${3:-}")"
  [ -n "$isid" ] || return 0
  glyph="$(state_glyph "$state" "$bg")"
  [ -n "$glyph" ] || return 0
  cur="$(iterm_window_name "$isid")"
  [ -n "$cur" ] || return 0
  base="$(strip_state_prefix "$cur")"
  base="$(strip_cc_marker "$base")"
  [ -n "$base" ] || return 0
  want="${glyph} ${base}"
  [ "$cur" = "$want" ] && return 0          # 既に望む形なら書かない
  tty="$(iterm_tty "$isid")"
  [ -n "$tty" ] || return 0
  # tty 直書きは影響の大きい操作なので、パスを厳格に検証する（Codex 指摘）。
  #   ① /dev/tty* 配下であること（将来 iterm_tty の実装が変わっても任意パスへ書かない）
  #   ② キャラクタデバイスであること（通常ファイル・シンボリックリンク先を弾く）
  #   ③ 自分の所有であること（他ユーザの端末へ書き込まない）
  case "$tty" in
    /dev/tty*) ;;
    *) return 0 ;;
  esac
  [ -c "$tty" ] || return 0
  [ -O "$tty" ] || return 0
  [ -w "$tty" ] || return 0
  # OSC 2 に制御文字を混ぜない（ESC/BEL は終端子と衝突する。DEL 0x7f も除去）
  want="$(printf '%s' "$want" | LC_ALL=C tr -d '\000-\037\177')"
  [ -n "$want" ] || return 0
  printf '\033]2;%s\007' "$want" > "$tty" 2>/dev/null || true
  return 0
}

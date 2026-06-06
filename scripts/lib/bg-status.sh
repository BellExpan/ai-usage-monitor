#!/bin/bash
# lib/bg-status.sh — per-job background progress for the statusline (Issues #44, #46)
#
# 各バックグラウンドジョブを **key 別** に1ファイルで記録し、statusline が新鮮な全 job を
# 集約して "⏳ CI 3/5 · E2E 2/4" のように表示する。key ごとに別ファイルなので、複数ジョブが
# 同時に書いても競合（read-modify-write race）が起きない。
#
# 状態は **プロジェクト単位にスコープ**される（cwd の git ルート）。bg-status.sh CLI も
# statusline.sh も同じ cwd で実行されるため同じディレクトリに解決される。
#
# 環境変数:
#   CLAUDE_BG_STATUS_FILE        単一ファイル override（レガシー single-slot 互換・key 無視）
#   CLAUDE_BG_STATUS_DIR         スコープ用ベースディレクトリ（既定 $HOME/.claude/bg_status）
#   CLAUDE_BG_STATUS_FRESH_SECS  新鮮とみなす秒数（既定600・非数値は既定）。超過 job は非表示
#   CLAUDE_BG_STATUS_MAX_JOBS    同時表示する最大 job 数（既定3・超過は "+N"）
#   CLAUDE_BG_STATUS_MAX_CHARS   表示最大文字数（既定200・超過は切り詰め）

# 単一ファイル override が有効か
_bg_status_single_file() { [ -n "${CLAUDE_BG_STATUS_FILE:-}" ]; }

# プロジェクトスコープのディレクトリ（key ごとに1ファイルを置く）
bg_status_projdir() {
  local base root key
  base="${CLAUDE_BG_STATUS_DIR:-$HOME/.claude/bg_status}"
  root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
  key="$(basename "$root" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')-$(printf '%s' "$root" | cksum | cut -d' ' -f1)"
  printf '%s/%s' "$base" "$key"
}

# job key を安全なファイル名成分にサニタイズ（パストラバーサル防止）
_bg_status_keyfile() {
  local key
  key=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  [ -n "$key" ] && [ "$key" != "." ] && [ "$key" != ".." ] || key="default"
  # 先頭ドットは dotfile になり glob/列挙から漏れる（render に出ない・clear で残る）ため _ を前置
  case "$key" in .*) key="_${key}" ;; esac
  printf '%s/%s.txt' "$(bg_status_projdir)" "$key"
}

# 指定 key の状態ファイルパスを返す（FILE override 時は単一ファイル）
bg_status_file() {
  if _bg_status_single_file; then
    printf '%s' "$CLAUDE_BG_STATUS_FILE"
    return 0
  fi
  _bg_status_keyfile "${1:-default}"
}

# 進捗を書き込む。usage: bg_status_set <key> <message>
# （atomic: 同一ディレクトリ内 mktemp → mv。key 別ファイルなので writer 間の競合なし）
bg_status_set() {
  local key="$1" msg="$2" file dir tmp
  [ -n "$msg" ] || { echo "bg_status_set: empty message" >&2; return 1; }
  file=$(bg_status_file "$key")
  dir=$(dirname "$file")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.bg_status.XXXXXX") || return 1
  printf '%s\n' "$msg" > "$tmp"
  mv -f "$tmp" "$file"
}

# 進捗をクリア。usage: bg_status_clear [key]
# key 指定時はその job のみ、無指定時はプロジェクトの全 job をクリア。
# dir モードは **ファイル削除**で残骸を残さない（key が増える運用での蓄積防止）。
# 単一ファイル override は利用者指定パスのため削除せず空化に留める。
bg_status_clear() {
  local key="${1:-}" file dir f
  if [ -n "$key" ]; then
    file=$(bg_status_file "$key")
    if _bg_status_single_file; then : > "$file" 2>/dev/null || true
    else rm -f "$file" 2>/dev/null || true; fi
    return 0
  fi
  if _bg_status_single_file; then
    : > "$CLAUDE_BG_STATUS_FILE" 2>/dev/null || true
    return 0
  fi
  dir=$(bg_status_projdir)
  [ -d "$dir" ] || return 0
  # find 列挙（dotfile も拾う・glob 漏れ防止）して削除
  while IFS= read -r f; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done < <(find "$dir" -maxdepth 1 -type f -name '*.txt' 2>/dev/null)
  return 0
}

# 新鮮な全 job を **key 昇順**（安定表示・flicker 防止）で集約し "⏳ <msg1> · <msg2> [+N]" を出力。
# job が無ければ何も出さない。dir モードでは stale ファイルを reap して蓄積を防ぐ。
bg_status_render() {
  local fresh max maxjobs now files=() f msg mtime age shown=0 total=0 joined=""
  fresh="${CLAUDE_BG_STATUS_FRESH_SECS:-600}"; case "$fresh" in *[!0-9]*|'') fresh=600 ;; esac
  max="${CLAUDE_BG_STATUS_MAX_CHARS:-200}";    case "$max"   in *[!0-9]*|'') max=200 ;;   esac
  maxjobs="${CLAUDE_BG_STATUS_MAX_JOBS:-3}";   case "$maxjobs" in *[!0-9]*|'') maxjobs=3 ;; esac
  [ "$maxjobs" -lt 1 ] && maxjobs=1   # 0 だと "⏳  +N" の空本体になるため最低1
  now=$(date +%s)

  if _bg_status_single_file; then
    files=("$CLAUDE_BG_STATUS_FILE")
  else
    local dir; dir=$(bg_status_projdir)
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done \
      < <(find "$dir" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort)
  fi
  [ ${#files[@]} -gt 0 ] || return 0

  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    mtime=$(stat -f%m "$f" 2>/dev/null || stat -c%Y "$f" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [ "$age" -lt 0 ] || [ "$age" -gt "$fresh" ]; then
      # stale は dir モードで reap（蓄積防止）。future（age<0=時計ずれ）は reap しない。
      if ! _bg_status_single_file && [ "$age" -gt "$fresh" ]; then rm -f "$f" 2>/dev/null || true; fi
      continue
    fi
    # 巨大ファイル防止: 先頭4KBの1行目のみ。%b 経路の ANSI/制御文字注入を除去（octal 134 = \）。
    msg=$(head -c 4096 "$f" 2>/dev/null | head -1)
    [ -n "$msg" ] || continue
    msg=$(printf '%s' "$msg" | LC_ALL=C tr -d '\000-\037\134')
    [ -n "$msg" ] || continue
    total=$((total + 1))
    if [ "$shown" -lt "$maxjobs" ]; then
      if [ -z "$joined" ]; then joined="$msg"; else joined="$joined · $msg"; fi
      shown=$((shown + 1))
    fi
  done
  [ "$total" -gt 0 ] || return 0

  [ "$total" -gt "$shown" ] && joined="$joined +$((total - shown))"
  [ "${#joined}" -gt "$max" ] && joined="${joined:0:$max}…"
  printf '%s' "⏳ ${joined}"
}

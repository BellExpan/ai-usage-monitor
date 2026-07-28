#!/bin/bash
# AI Usage Monitor — Claude Code statusline
# Line 1: repo ᛘ branch  Model (ctx)  ctx:X%
# Line 2: 🟢Claude:5hX%/1wX%/Snt1wX%  🟢Codex:5hX%/1wX%  [Mode]
# Line 3: ⚡N bg  ⏳ bg-job-progress  PR #NNN  ffmpeg
# Line 4+: bg タスクを 1 行ずつ（🔧 進捗ジョブ=ai-org-progress / ⚙ bash bg=出力スニペット）
#          N = 総行数（進捗ジョブ + bash bg + ci）で一致

# BASH_SOURCE[0] + readlink でスクリプト実体の絶対パスを解決
# （dirname "$0" は symlink 経由呼び出し時に symlink の置かれた dir を返すため不可）
_SCRIPT="${BASH_SOURCE[0]}"
[ -L "$_SCRIPT" ] && _SCRIPT="$(readlink -f "$_SCRIPT" 2>/dev/null || readlink "$_SCRIPT")"
_SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT")" && pwd)"
unset _SCRIPT
# shellcheck source=lib/cache-path.sh
source "$_SCRIPT_DIR/lib/cache-path.sh"
# shellcheck source=lib/bg-status.sh
source "$_SCRIPT_DIR/lib/bg-status.sh"
# shellcheck source=lib/reset-label.sh
source "$_SCRIPT_DIR/lib/reset-label.sh"
# shellcheck source=lib/session-state.sh
source "$_SCRIPT_DIR/lib/session-state.sh"
unset _SCRIPT_DIR

# ── stdin JSON（Claude Code が渡す）──────────────────────────
CLA_5H_REMAINING_PCT=""
CLA_WEEK_REMAINING_PCT=""
model_short=""
ctx_used=""
ctx_size=0
cwd=""
session_id=""

if [ ! -t 0 ]; then
  STDIN_DATA=$(cat)
  if [ -n "$STDIN_DATA" ]; then
    # | 区切りで出力することで bash read の空フィールド潰れを防ぐ
    parsed=$(echo "$STDIN_DATA" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    rl = d.get('rate_limits', {})
    fh = rl.get('five_hour', {})
    wk = rl.get('weekly', rl.get('week', {}))
    m  = d.get('model', {}).get('display_name', '')
    cw = d.get('context_window', {})
    cwd = d.get('workspace', {}).get('current_dir', d.get('cwd', ''))
    print('|'.join([
        str(fh.get('used_percentage', '')),
        str(wk.get('used_percentage', '')),
        m,
        str(cw.get('used_percentage', '')),
        str(cw.get('context_window_size', 0)),
        cwd,
        str(d.get('session_id', '')),
    ]))
except Exception:
    print('||||||')
" 2>/dev/null)
    IFS='|' read -r CLA_5H_USED CLA_WEEK_USED model_raw ctx_used ctx_size cwd session_id <<< "$parsed"
    [ -n "$CLA_5H_USED" ] && \
      CLA_5H_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", 100-$CLA_5H_USED}")
    [ -n "$CLA_WEEK_USED" ] && \
      CLA_WEEK_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", 100-$CLA_WEEK_USED}")
    model_short="${model_raw#Claude }"
  fi
fi

# ── キャッシュ読み込み ────────────────────────────────────────
if [ -f "$CACHE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CACHE_FILE"
fi

CDX_5H_REMAINING_PCT=${CDX_5H_REMAINING_PCT:-100}
CDX_WEEK_REMAINING_PCT=${CDX_WEEK_REMAINING_PCT:-100}
CDX_5H_AVAILABLE=${CDX_5H_AVAILABLE:-1}
CDX_WEEK_AVAILABLE=${CDX_WEEK_AVAILABLE:-1}
# Codex リセット epoch も default（cache 不在時に下の -gt/-le 比較が integer expected で死ぬのを防ぐ）
CDX_WEEK_RESETS_AT=${CDX_WEEK_RESETS_AT:-0}
CDX_RATE_LIMITS_FRESH=${CDX_RATE_LIMITS_FRESH:-0}
USAGE_SRC_HEALTH=${USAGE_SRC_HEALTH:-ok}
CDX_5H_RESETS_AT=${CDX_5H_RESETS_AT:-0}
# Claude 週次も Codex と対称に default。Claude の 1w は stdin に来ず必ず cache 依存だが
# macOS の temp dir は定期クリアされ「cache 不在」は常態。default が無いと 1w だけ静かに
# 消える（owner 報告: Claude の 1w が表示されない）。下で CLA_WEEK へマップされる。
CLA_7D_REMAINING_PCT=${CLA_7D_REMAINING_PCT:-100}
ROUTING_MODE=${ROUTING_MODE:-normal}

# ── 描画時 real-time ロールオーバー投影（Issue #18）──
# cache 更新は最大5分間隔（外部SSD/TCC で遅延しうる）。描画毎に過去化した Codex resets_at を
# 検出し、使用量を fresh（残100%）に投影＝「↺soon + 残stale」固定を即座に解消する。
# resets_at の roll は下の reset_label_from_epoch が window 付きで担う（二重に持たない）。
# window 欠落(旧cache)でも label の fallback(週10080/5h300)と整合させ、過去 resets_at なら投影。
_SL_NOW=$(date +%s)
case "${CDX_WEEK_RESETS_AT:-0}" in ''|*[!0-9]*) : ;; *)
  if [ "${CDX_WEEK_AVAILABLE:-1}" = "1" ] && [ "$CDX_WEEK_RESETS_AT" -gt 0 ] && [ "$CDX_WEEK_RESETS_AT" -le "$_SL_NOW" ]; then
    CDX_WEEK_REMAINING_PCT=100
  fi ;;
esac
case "${CDX_5H_RESETS_AT:-0}" in ''|*[!0-9]*) : ;; *)
  if [ "${CDX_5H_AVAILABLE:-1}" = "1" ] && [ "$CDX_5H_RESETS_AT" -gt 0 ] && [ "$CDX_5H_RESETS_AT" -le "$_SL_NOW" ]; then
    CDX_5H_REMAINING_PCT=100
  fi ;;
esac

# Claude % の優先順位: OAuth API キャッシュ → stdin JSON → フォールバック
CACHE_CLA_PCT=${CLA_5H_REMAINING_PCT:-}
CACHE_CLA_OAUTH_FRESH=${CLA_OAUTH_FRESH:-0}

if [ "$CACHE_CLA_OAUTH_FRESH" = "1" ] && [ -n "$CACHE_CLA_PCT" ]; then
  CLA_5H_REMAINING_PCT="$CACHE_CLA_PCT"
elif [ -z "$CLA_5H_REMAINING_PCT" ]; then
  CLA_5H_REMAINING_MINS=${CLA_5H_REMAINING_MINS:-300}
  CLA_5H_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", $CLA_5H_REMAINING_MINS/300*100}")
fi

if [ -z "$CLA_WEEK_REMAINING_PCT" ] && [ -n "${CLA_7D_REMAINING_PCT:-}" ]; then
  CLA_WEEK_REMAINING_PCT="$CLA_7D_REMAINING_PCT"
fi

SNT_REMAINING_PCT=${CLA_7D_SONNET_REMAINING_PCT:-}
CLA_5H_LABEL="${CLA_5H_REMAINING_PCT}%"
CLA_WEEK_LABEL="${CLA_WEEK_REMAINING_PCT}%"
SNT_LABEL="${SNT_REMAINING_PCT}%"
if [ "${CLA_OAUTH_FRESH:-0}" != "1" ]; then
  CLA_5H_LABEL="?"
  CLA_WEEK_LABEL="?"
  SNT_LABEL="?"
fi
CDX_5H_LABEL="${CDX_5H_REMAINING_PCT%.*}%"
CDX_WEEK_LABEL="${CDX_WEEK_REMAINING_PCT%.*}%"
if [ "${CDX_RATE_LIMITS_FRESH:-0}" != "1" ]; then
  CDX_5H_LABEL="?"
  CDX_WEEK_LABEL="?"
fi

# ── 色設定 ──────────────────────────────────────────────────
cyan='\033[36m'
green='\033[32m'
yellow='\033[33m'
magenta='\033[35m'
dim='\033[2m'
reset='\033[0m'
red='\033[31m'

# Claude アイコン
[ "${CLA_5H_REMAINING_PCT:-100}" -ge 30 ] && CLA_IC="🟢" || CLA_IC="🟡"
[ "${CLA_5H_REMAINING_PCT:-100}" -lt 10 ] && CLA_IC="🔴"

# Codex アイコン
if [ "${CDX_5H_AVAILABLE:-1}" = "1" ]; then
  CDX_PCT=${CDX_5H_REMAINING_PCT%.*}
else
  CDX_PCT=${CDX_WEEK_REMAINING_PCT%.*}
fi
[ "${CDX_PCT:-100}" -ge 50 ] && CDX_IC="🟢" || CDX_IC="🟡"
[ "${CDX_PCT:-100}" -lt 20 ] && CDX_IC="🔴"

# モードラベル（バランスギャップ表示付き）
_gap=${BALANCE_GAP:-0}
[ "$_gap" -gt 0 ] && _gap_str="+${_gap}%" || _gap_str="${_gap}%"
case "$ROUTING_MODE" in
  claude_critical) MODE=" 🚨[Claude-Critical]" ;;
  save_claude)     MODE=" ⚠️[Save-Claude]" ;;
  codex_burn)      MODE=" 🔥[Burn-Codex]" ;;
  claude_burn)     MODE=" 🔥[Burn-Claude]" ;;
  codex_first)     MODE=" [Codex-First ${_gap_str}]" ;;
  protect_codex)   MODE=" [Codex-Save]" ;;
  claude_first)    MODE=" [Claude-First ${_gap_str}]" ;;
  normal)          MODE=" [Balanced ${_gap_str}]" ;;
  *)               MODE=" [Balanced]" ;;
esac

# ── ブランチ・ディレクトリ ────────────────────────────────────
dir=""
branch=""
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  dir=$(basename "$cwd")
  branch=$(git -C "$cwd" -c core.fsync=false symbolic-ref --short HEAD 2>/dev/null \
    || git -C "$cwd" rev-parse --short HEAD 2>/dev/null \
    || echo "")
fi

# ── ctx サイズラベル ─────────────────────────────────────────
ctx_label=""
if [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
  if [ "$ctx_size" -ge 1000000 ]; then
    ctx_label=" ($(awk "BEGIN{printf \"%gM\", $ctx_size/1000000}") ctx)"
  elif [ "$ctx_size" -ge 1000 ]; then
    ctx_label=" ($(awk "BEGIN{printf \"%gk\", $ctx_size/1000}") ctx)"
  fi
fi

# ── Line 1 ───────────────────────────────────────────────────
parts=""

# repo ᛘ branch
if [ -n "$dir" ]; then
  parts="${cyan}${dir}${reset}"
  if [ -n "$branch" ]; then
    parts="${parts}  ${dim}ᛘ${reset} ${green}${branch}${reset}"
  fi
fi

# Model + ctx size
if [ -n "$model_short" ]; then
  parts="${parts}  ${magenta}${model_short}${ctx_label}${reset}"
fi

# Context used %
if [ -n "$ctx_used" ] && [[ "$ctx_used" =~ ^[0-9.]+$ ]]; then
  ctx_int=$(printf '%.0f' "$ctx_used")
  if [ "$ctx_int" -ge 100 ]; then
    parts="${parts}  ${dim}ctx:${ctx_int}%${reset}"
  elif [ "$ctx_int" -ge 80 ]; then
    parts="${parts}  ${red}ctx:${ctx_int}%${reset}"
  elif [ "$ctx_int" -ge 50 ]; then
    parts="${parts}  ${yellow}ctx:${ctx_int}%${reset}"
  else
    parts="${parts}  ${dim}ctx:${ctx_int}%${reset}"
  fi
fi

# Claude リセット残り時間ラベル（7d枠・epoch からリアルタイム計算・残<1h も表示）
CLA_RESET_LABEL=""
_reset_now=$(date +%s)
# window=10080(7d) を渡し、cache 更新間(最大5分)に過去化した resets_at も real-time で
# 次リセットへ巻き進める（↺soon 固定の解消・#18）。
_cla_lbl=$(reset_label_from_epoch "${CLA_7D_RESETS_AT:-0}" "$_reset_now" 10080)
[ -n "$_cla_lbl" ] && CLA_RESET_LABEL=" ${dim}${_cla_lbl}${reset}"

# Claude %（OAuth 優先）— 絵文字後スペース + ラベルをシアンで色付け
if [ -n "$CLA_WEEK_REMAINING_PCT" ] && [ -n "$SNT_REMAINING_PCT" ]; then
  CLA_DISPLAY="${CLA_IC} ${cyan}Claude${reset}:5h${CLA_5H_LABEL}/1w${CLA_WEEK_LABEL}/Snt1w${SNT_LABEL}${CLA_RESET_LABEL}"
elif [ -n "$CLA_WEEK_REMAINING_PCT" ]; then
  CLA_DISPLAY="${CLA_IC} ${cyan}Claude${reset}:5h${CLA_5H_LABEL}/1w${CLA_WEEK_LABEL}${CLA_RESET_LABEL}"
else
  CLA_DISPLAY="${CLA_IC} ${cyan}Claude${reset}:5h${CLA_5H_LABEL}${CLA_RESET_LABEL}"
fi

# Codex リセット残り時間ラベル（週枠・epoch からリアルタイム計算、Claude と対称）
# cache の整数 CDX_HOURS_UNTIL_RESET は残<1h を 0 に丸めラベルが消える構造バグが
# あったため、epoch（CDX_WEEK_RESETS_AT）から都度計算する（Issue #15）。
CDX_RESET_LABEL=""
# window_minutes（cache の CDX_WEEK_WINDOW_MIN、fallback 週=10080）を渡し real-time ロール（#18）
_cdx_lbl=$(reset_label_from_epoch "${CDX_WEEK_RESETS_AT:-0}" "$_reset_now" "${CDX_WEEK_WINDOW_MIN:-10080}")
[ -n "$_cdx_lbl" ] && CDX_RESET_LABEL=" ${dim}${_cdx_lbl}${reset}"
if [ "${CDX_5H_AVAILABLE:-1}" = "1" ]; then
  CDX_DISPLAY="${CDX_IC} ${yellow}Codex${reset}:5h${CDX_5H_LABEL}/1w${CDX_WEEK_LABEL}${CDX_RESET_LABEL}"
else
  CDX_DISPLAY="${CDX_IC} ${yellow}Codex${reset}:1w${CDX_WEEK_LABEL}${CDX_RESET_LABEL}"
fi

[ -n "$parts" ] && printf "%b\n" "$parts"

# ── Line 2: Claude/Codex usage ──────────────────────────────
# 最終更新時刻（キャッシュ TIMESTAMP → HH:MM）
last_update=""
if [ -n "${TIMESTAMP:-}" ] && [ "$TIMESTAMP" -gt 0 ] 2>/dev/null; then
  last_update="  ${dim}↻$(date -r "$TIMESTAMP" +%H:%M)${reset}"
fi
usage_line="${CLA_DISPLAY} ${CDX_DISPLAY}${MODE}${last_update}"
if [ "${USAGE_SRC_HEALTH:-ok}" != "ok" ]; then
  usage_line="${usage_line} ⚠src"
fi
printf "%b\n" "$usage_line"

# ── Line 3: bg tasks / PR / ffmpeg / ai-org-progress ────────
line3=""

# Background tasks — owner 2026-06-07: bg ごとに 1 行（縦に伸びてOK）。
# ⚡N bg の N = 表示行数（進捗ジョブ + 進捗なし bash bg + ci）で一致させる。
now_epoch=$(date +%s)
_bg_age() { local a=$1; [ "$a" -lt 0 ] && a=0; if [ "$a" -lt 60 ]; then printf '%ss' "$a"; else printf '%sm' "$((a / 60))"; fi; }

# (a) 進捗報告ジョブ（subagent）= ai-org-progress のリッチ行（job ごと改行）
prog_rows=""
prog_count=0
if [ -x "$HOME/.local/bin/ai-org-progress" ]; then
  prog_rows=$("$HOME/.local/bin/ai-org-progress" --short 2>/dev/null)
  [ -n "$prog_rows" ] && prog_count=$(printf '%s\n' "$prog_rows" | grep -c .)
fi

# (b) 進捗を持たない bash background（run_in_background）= 短い id の .output
#     agent の .output（_AGENT_ID_MINLEN 文字以上の長い id）は (a) の 🔧 行で表示済みのため除外。
#     表示は mtime 新しい順で安定（refresh ごとの並び替え flicker 防止）。縦の伸びは許容。
bash_rows=""
bash_count=0
_ESC=$(printf '\033')
_AGENT_ID_MINLEN=14   # agent .output は ~17文字 hex、bash bg は ~9文字。14 で分離
# Issue #42: 自セッションの tasks だけを見る（他 terminal の bg を混ぜない）。
#   session_id が取れない旧環境では従来どおり全体を見る（fail-open）。
_out_dir="$(session_tasks_dir "$session_id")"
_out_scoped=1
if [ -z "$_out_dir" ]; then
  _out_dir="/private/tmp/claude-$(id -u)"
  _out_scoped=0
fi
# bash 3.2 互換のため配列を使わず分岐（set -u 下の空配列展開を避ける）
_find_outputs() {
  if [ "$_out_scoped" = "1" ]; then
    find "$_out_dir" -maxdepth 1 -name "*.output" -mmin -5 -exec stat -f '%m %N' {} \; 2>/dev/null
  else
    find "$_out_dir" -name "*.output" -mmin -5 -exec stat -f '%m %N' {} \; 2>/dev/null
  fi
}
if [ -d "$_out_dir" ]; then
  while IFS= read -r _of; do
    [ -n "$_of" ] || continue
    _bid=$(basename "$_of" .output | LC_ALL=C tr -d '\000-\037\134')
    [ "${#_bid}" -ge "$_AGENT_ID_MINLEN" ] && continue
    _mt=$(stat -f%m "$_of" 2>/dev/null || echo "$now_epoch")
    # 作業内容スニペット: 出力の最新の非空行（ANSI 色除去 → 制御文字/バックスラッシュ除去・48字）
    _snip=$(tail -n 5 "$_of" 2>/dev/null | sed -E "s/${_ESC}\[[0-9;]*m//g" \
            | grep -v '^[[:space:]]*$' | tail -1 | LC_ALL=C tr -d '\000-\037\134')
    _snip="${_snip:0:48}"
    if [ -n "$_snip" ]; then
      bash_rows="${bash_rows}"$'\n'"   ${dim}⚙ ${_bid} $(_bg_age $((now_epoch - _mt)))${reset} ${_snip}"
    else
      bash_rows="${bash_rows}"$'\n'"   ${dim}⚙ ${_bid} $(_bg_age $((now_epoch - _mt))) (no output yet)${reset}"
    fi
    bash_count=$((bash_count + 1))
  done < <(_find_outputs | sort -rn | cut -d' ' -f2-)
fi

# (c) /tmp/ci_ プロセス
ci_rows=""
ci_count=0
while IFS= read -r _pid; do
  [ -n "$_pid" ] || continue
  ci_rows="${ci_rows}"$'\n'"   ${dim}⚙ ci:${_pid}${reset}"
  ci_count=$((ci_count + 1))
done < <(pgrep -f "/tmp/ci_" 2>/dev/null)

bg_total=$((prog_count + bash_count + ci_count))

# Issue #42: ターン状態バナー。「終わったのか / bg で動いているのか」を先頭で言い切る。
#   判定に使うのは bash_count（＝自セッションの bg タスク）。prog/ci は元からマシン全体スコープ。
_turn_state="$(turn_state_read "$session_id")"
_banner="$(turn_banner "$_turn_state" "$bash_count")"
line3=""
case "$_turn_state" in
  idle) if [ "$bash_count" -gt 0 ]; then line3="${cyan}${_banner}${reset}  "
        else line3="${green}${_banner}${reset}  "; fi ;;
  busy) line3="${yellow}${_banner}${reset}  " ;;
  wait) line3="${red}${_banner}${reset}  " ;;
esac

if [ "$bg_total" -gt 0 ]; then
  line3="${line3}${yellow}⚡${bg_total} bg${reset}"
else
  line3="${line3}${dim}⚡0 bg${reset}"
fi

# 他 terminal の bg は消さずに別枠で見せる（存在は分かるが自分のと混同しない）
_other_bg="$(session_other_bg_count "$session_id")"
if [ "${_other_bg:-0}" -gt 0 ]; then
  line3="${line3} ${dim}+${_other_bg} 他term${reset}"
fi

# Background job progress message (#44) — 状態ファイルが新鮮なら表示
# bg-status は cwd の git ルートでスコープされるため、statusline プロセスの PWD ではなく
# stdin JSON の $cwd（= ワークスペース）で解決する（別 repo の進捗が混線しないように）。
_bg_msg=$( if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" 2>/dev/null || true; fi; bg_status_render )
[ -n "$_bg_msg" ] && line3="${line3}  ${cyan}${_bg_msg}${reset}"

# ffmpeg 進捗
ffmpeg_pid=$(pgrep -x ffmpeg 2>/dev/null | head -1)
if [ -n "$ffmpeg_pid" ]; then
  ff_elapsed=$(ps -p "$ffmpeg_pid" -o etime= 2>/dev/null | tr -d ' ')
  ff_outfile=$(lsof -p "$ffmpeg_pid" 2>/dev/null | grep -E '\.(mp4|mov|wav)$' | tail -1 | awk '{print $NF}')
  ff_size=""
  if [ -n "$ff_outfile" ] && [ -f "$ff_outfile" ]; then
    ff_bytes=$(stat -f%z "$ff_outfile" 2>/dev/null || echo "0")
    if [ "$ff_bytes" -ge 1073741824 ] 2>/dev/null; then
      ff_size=$(awk "BEGIN{printf \"%.1fG\", $ff_bytes/1073741824}")
    elif [ "$ff_bytes" -ge 1048576 ] 2>/dev/null; then
      ff_size=$(awk "BEGIN{printf \"%.0fM\", $ff_bytes/1048576}")
    fi
  fi
  ff_expect=""
  [ -f /tmp/ffmpeg_expected_size ] && ff_expect=$(cat /tmp/ffmpeg_expected_size 2>/dev/null)
  if [ -n "$ff_size" ] && [ -n "$ff_expect" ]; then
    line3="${line3}  ${magenta}🎬 ffmpeg ${ff_elapsed} ${ff_size}/${ff_expect}${reset}"
  elif [ -n "$ff_size" ]; then
    line3="${line3}  ${magenta}🎬 ffmpeg ${ff_elapsed} ${ff_size}${reset}"
  else
    line3="${line3}  ${magenta}🎬 ffmpeg ${ff_elapsed}${reset}"
  fi
fi

# PR
if [ -n "$branch" ] && command -v gh &>/dev/null; then
  pr_num=$(timeout 1 gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null)
  if [ -n "$pr_num" ]; then
    line3="${line3}  ${dim}PR #${pr_num}${reset}"
  fi
fi

# bg タスクの行を末尾に追加（1タスク1行）:
#   進捗ジョブ（リッチ）→ 進捗なし bash bg → ci プロセス
[ -n "$prog_rows" ] && line3="${line3}"$'\n'"${prog_rows}"
line3="${line3}${bash_rows}${ci_rows}"

[ -n "$line3" ] && printf "%b\n" "$line3"

# Issue #42: iTerm2 のタブタイトルを同じ状態に同期する。
#   タブバーを見るだけで（terminal をフォーカスせずに）どのタブが終わっているか判別できる。
#   変化時のみ osascript を呼ぶので、通常の refresh には追加コストが乗らない。
_iterm_id="$(turn_state_iterm_id "$session_id")"
[ -z "$_iterm_id" ] && _iterm_id="${ITERM_SESSION_ID##*:}"
if [ -n "$_iterm_id" ] && [ "$_turn_state" != "unknown" ]; then
  iterm_set_title_if_changed \
    "$(session_title "$_turn_state" "$bash_count" "${cwd##*/}")" "$_iterm_id"
fi

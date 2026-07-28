#!/bin/bash
# Claude Code SessionStart hook — AI使用量モード宣言

# shellcheck source=../scripts/lib/cache-path.sh
source "$(dirname "$0")/../scripts/lib/cache-path.sh"
# shellcheck source=../scripts/lib/launchd-deploy.sh
source "$(dirname "$0")/../scripts/lib/launchd-deploy.sh"  # aum_self_heal_if_needed（Issue #24）
init_cache_dir
_REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_UPDATE_SH="$_REPO_DIR/scripts/cache-update.sh"

# キャッシュ鮮度チェック＋自己修復（launchd 2サイクル超 = 600秒以上古ければ更新）
_now=$(date +%s)
_cache_ts=$(grep "^TIMESTAMP=" "$CACHE_FILE" 2>/dev/null | cut -d= -f2)
# 非数値・空は 0 に正規化（破損キャッシュでも算術エラーを防ぐ）
[[ "$_cache_ts" =~ ^[0-9]+$ ]] || _cache_ts=0
_cache_age=$(( _now - _cache_ts ))
if [ "$_cache_age" -gt 600 ]; then
  echo "[AI使用量司令塔] ⚠️ キャッシュが ${_cache_age}秒 古いためバックグラウンド更新を開始"
  # (1) launchd plist が drift/penalty box なら自己修復（Issue #24・stale 時限定・cooldown・fail-soft）
  #     「テンプレは正しいのに live に未反映」というドリフトを自動で landed 状態に戻す。
  aum_self_heal_if_needed "$_REPO_DIR"
  # (2) 即時バックグラウンド更新。cache-update.sh 自身が単一実行ロックを取るため
  #     launchd の定期実行と競合しない（session-start 側での lock 管理は不要になった）。
  [ -x "$CACHE_UPDATE_SH" ] && bash "$CACHE_UPDATE_SH" >/dev/null 2>&1 &
fi

[ -f "$CACHE_FILE" ] || exit 0

# shellcheck disable=SC1090
source "$CACHE_FILE"

CLA_5H_REMAINING_PCT=${CLA_5H_REMAINING_PCT:-$(awk "BEGIN{printf \"%d\", ${CLA_5H_REMAINING_MINS:-300}/300*100}")}
CLA_7D_REMAINING_PCT=${CLA_7D_REMAINING_PCT:-0}
CLA_7D_SONNET_REMAINING_PCT=${CLA_7D_SONNET_REMAINING_PCT:-0}
CDX_5H_REMAINING_PCT=${CDX_5H_REMAINING_PCT:-100}
CDX_WEEK_REMAINING_PCT=${CDX_WEEK_REMAINING_PCT:-100}
CDX_RATE_LIMITS_FRESH=${CDX_RATE_LIMITS_FRESH:-0}
CLA_OAUTH_FRESH=${CLA_OAUTH_FRESH:-0}
ROUTING_MODE=${ROUTING_MODE:-normal}
USAGE_SRC_HEALTH=${USAGE_SRC_HEALTH:-ok}

FRESH_NOTE=""
[ "$CDX_RATE_LIMITS_FRESH" != "1" ] && FRESH_NOTE=" ※Codexデータ古い可能性あり"

# Sonnet 週次警告
SNT_WARN=""
[ "${CLA_7D_SONNET_REMAINING_PCT:-100}" -lt 30 ] && SNT_WARN=" ⚠️Sonnet週次残${CLA_7D_SONNET_REMAINING_PCT}%"

# === Claude/Codex 週次バランス自動チェック ===
# Claude使用率 = 100 - 残%, Codex使用率 = 100 - 残%
# 乖離 = Claude使用率 - Codex使用率 > 15% → CDX_UNDERUSE_WARN=1（normal モードのみ）
# 乖離 > 25% → ROUTING_MODE=codex_first に自動昇格（normal モードのみ）
CLA_7D_USED=$(( 100 - ${CLA_7D_REMAINING_PCT:-100} ))
_CDX_INT=${CDX_WEEK_REMAINING_PCT%.*}  # 小数点除去（空値は次行の:-100 でフォールバック）
CDX_WEEK_USED=$(( 100 - ${_CDX_INT:-100} ))
# _SESS_USED_GAP: 使用率ベースの乖離（cache の BALANCE_GAP=残量差とは別物・名前衝突防止）
_SESS_USED_GAP=$(( CLA_7D_USED - CDX_WEEK_USED ))
# 負の乖離（Codex使いすぎ）は normal モードでは不要な警告になるため無視
if [ "$_SESS_USED_GAP" -ge 25 ] && [ "$ROUTING_MODE" = "normal" ]; then
  ROUTING_MODE="codex_first"
elif [ "$_SESS_USED_GAP" -ge 15 ] && [ "$ROUTING_MODE" = "normal" ]; then
  CDX_UNDERUSE_WARN=1
fi

CLA_5H_LABEL="${CLA_5H_REMAINING_PCT}%"
CLA_7D_LABEL="${CLA_7D_REMAINING_PCT}%"
CLA_SNT_LABEL="${CLA_7D_SONNET_REMAINING_PCT}%"
if [ "$CLA_OAUTH_FRESH" != "1" ]; then
  CLA_5H_LABEL="?"
  CLA_7D_LABEL="?"
  CLA_SNT_LABEL="?"
fi
CDX_5H_LABEL="${CDX_5H_REMAINING_PCT%.*}%"
CDX_WEEK_LABEL="${CDX_WEEK_REMAINING_PCT%.*}%"
if [ "$CDX_RATE_LIMITS_FRESH" != "1" ]; then
  CDX_5H_LABEL="?"
  CDX_WEEK_LABEL="?"
fi

CLA_LINE="Claude 5h:残${CLA_5H_LABEL} 週:残${CLA_7D_LABEL} Sonnet週:残${CLA_SNT_LABEL}${SNT_WARN}"
CDX_LINE="Codex 5h:残${CDX_5H_LABEL} 週:残${CDX_WEEK_LABEL}"

if [ "$USAGE_SRC_HEALTH" != "ok" ]; then
  echo "[AI使用量司令塔] ⚠️ データ源 degraded: ${USAGE_SRC_HEALTH#degraded:}"
fi

case "$ROUTING_MODE" in
  claude_critical)
    cat <<EOF
[AI使用量司令塔] 🚨 [Claude-Critical]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Claude残り僅か。全タスクをCodexへ。Claude: 必須ツール操作のみ
EOF
    ;;
  save_claude)
    cat <<EOF
[AI使用量司令塔] ⚠️ [Save-Claude]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Claude温存中。read/review/analysis は全てCodexへ
EOF
    ;;
  codex_burn)
    cat <<EOF
[AI使用量司令塔] 🔥 [Burn-Codex]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Codexリセット前に余剰あり。積極的にCodexへ振る
EOF
    ;;
  claude_burn)
    cat <<EOF
[AI使用量司令塔] 🔥 [Burn-Claude]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Claudeリセット前に余剰あり。Claude積極使用
EOF
    ;;
  codex_first)
    cat <<EOF
[AI使用量司令塔] 🟡 [Codex-First]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Research / doc summary / code review → Codex (codex-advisor) preferred
→ Claude: judgment / tool ops / implementation
EOF
    ;;
  protect_codex)
    cat <<EOF
[AI使用量司令塔] ⚠️ [Codex-Save]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Codex low. Claude-centric until weekly reset
EOF
    ;;
  claude_first)
    cat <<EOF
[AI使用量司令塔] 🔵 [Claude-First]${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
→ Claude残量がCodexより多い。余っているClaudeを使いCodexを温存
→ 調査/要約/レビューも当面Claudeで消化（Codexは週次リセットまで温存）
EOF
    ;;
  *)  # normal / balanced
    CDX_WEEK_REM_INT=${CDX_WEEK_REMAINING_PCT%.*}
    CDX_UNDERUSE_WARN=${CDX_UNDERUSE_WARN:-0}
    CDX_UNDERUSE_MSG=""
    [ "$CDX_UNDERUSE_WARN" = "1" ] && CDX_UNDERUSE_MSG=" ⚠️今週Codex未活用(${CDX_WEEK_REM_INT}%余り)"
    cat <<EOF
[AI使用量司令塔] 🟢 [Balanced]${CDX_UNDERUSE_MSG}${FRESH_NOTE}
${CLA_LINE}
${CDX_LINE}
Codex-first (always): PR review / hook design / code read >100L / doc draft / triage / summary / analysis / research
Claude-only (irreplaceable): tool ops / decisions / impl / git / PR create
EOF
    ;;
esac

# === Runner 状態 (#40: scripts/runner-status.sh に責務分離済み) ===
_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "${_SCRIPT_ROOT}/scripts/runner-status.sh" 2>/dev/null || echo "Runner: 🟡 unknown"

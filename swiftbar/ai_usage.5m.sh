#!/bin/bash
# AI Usage Monitor — SwiftBar plugin (refresh: 5min)

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/cache-path.sh
source "$REPO_DIR/scripts/lib/cache-path.sh"
UPDATE_SCRIPT="$REPO_DIR/scripts/cache-update.sh"

color_icon() {
  local pct=${1:-100}  # remaining %
  if   [ "${pct%.*}" -lt 20 ]; then echo "🔴"
  elif [ "${pct%.*}" -lt 50 ]; then echo "🟡"
  else echo "🟢"; fi
}
color_hex() {
  local pct=${1:-100}
  if   [ "${pct%.*}" -lt 20 ]; then echo "#FF3B30"
  elif [ "${pct%.*}" -lt 50 ]; then echo "#FF9500"
  else echo "#34C759"; fi
}

if [ ! -f "$CACHE_FILE" ]; then
  echo "⚡ --"
  echo "---"
  echo "キャッシュがありません | color=#FF3B30"
  echo "今すぐ更新 | bash=$UPDATE_SCRIPT terminal=false refresh=true"
  exit 0
fi

# shellcheck disable=SC1090
source "$CACHE_FILE"

CLA_5H_REMAINING_MINS=${CLA_5H_REMAINING_MINS:-300}
CLA_5H_REMAINING_PCT=${CLA_5H_REMAINING_PCT:-0}
CLA_5H_USED_PCT=${CLA_5H_USED_PCT:-0}
CLA_7D_REMAINING_PCT=${CLA_7D_REMAINING_PCT:-0}
CLA_7D_USED_PCT=${CLA_7D_USED_PCT:-0}
CLA_7D_SONNET_REMAINING_PCT=${CLA_7D_SONNET_REMAINING_PCT:-0}
CLA_7D_SONNET_USED_PCT=${CLA_7D_SONNET_USED_PCT:-0}
CLA_7D_TOKENS=${CLA_7D_TOKENS:-0}
CLA_7D_COST=${CLA_7D_COST:-0}
CLA_OAUTH_FRESH=${CLA_OAUTH_FRESH:-0}
CDX_5H_REMAINING_PCT=${CDX_5H_REMAINING_PCT:-100}
CDX_WEEK_REMAINING_PCT=${CDX_WEEK_REMAINING_PCT:-100}
CDX_5H_USED_PCT=${CDX_5H_USED_PCT:-0}
CDX_WEEK_USED_PCT=${CDX_WEEK_USED_PCT:-0}
CDX_5H_RESETS_AT=${CDX_5H_RESETS_AT:-0}
CDX_WEEK_RESETS_AT=${CDX_WEEK_RESETS_AT:-0}
CDX_RATE_LIMITS_FRESH=${CDX_RATE_LIMITS_FRESH:-0}
ROUTING_MODE=${ROUTING_MODE:-normal}
TIMESTAMP=${TIMESTAMP:-0}

# リセット時刻を人間が読める形に変換
fmt_reset() {
  local ts=$1
  [ "$ts" -eq 0 ] && echo "?" && return
  date -r "$ts" +'%H:%M' 2>/dev/null || echo "?"
}

CDX_5H_RESET_TIME=$(fmt_reset "$CDX_5H_RESETS_AT")
CDX_WEEK_RESET_DATE=$(date -r "$CDX_WEEK_RESETS_AT" +'%m/%d' 2>/dev/null || echo "?")

CLA_ICON=$(color_icon "$CLA_5H_REMAINING_MINS")  # 分→%変換なしで大まかに
[ "$CLA_5H_REMAINING_MINS" -lt 30 ]  && CLA_ICON="🔴"
[ "$CLA_5H_REMAINING_MINS" -ge 30 ] && [ "$CLA_5H_REMAINING_MINS" -lt 90 ] && CLA_ICON="🟡"
[ "$CLA_5H_REMAINING_MINS" -ge 90 ] && CLA_ICON="🟢"
CLA_COLOR="#34C759"
[ "$CLA_5H_REMAINING_MINS" -lt 90 ]  && CLA_COLOR="#FF9500"
[ "$CLA_5H_REMAINING_MINS" -lt 30 ]  && CLA_COLOR="#FF3B30"

CDX_5H_ICON=$(color_icon "$CDX_5H_REMAINING_PCT")
CDX_5H_COLOR=$(color_hex "$CDX_5H_REMAINING_PCT")
CDX_WK_ICON=$(color_icon "$CDX_WEEK_REMAINING_PCT")
CDX_WK_COLOR=$(color_hex "$CDX_WEEK_REMAINING_PCT")

STALE_WARN=""; AGE=$(( $(date +%s) - TIMESTAMP ))
[ "$AGE" -gt 1800 ] && STALE_WARN=" ⚠"

# ── メニューバー ──────────────────────────────────────────
# 例: 🟢 Claude 残54分 | 🟢 Codex 5h:99% 週:99%
echo "${CLA_ICON} Claude ${CLA_5H_REMAINING_PCT}%/週${CLA_7D_REMAINING_PCT}%/Sonnet${CLA_7D_SONNET_REMAINING_PCT}%  |  ${CDX_5H_ICON} Codex ${CDX_5H_REMAINING_PCT%.*}%/週${CDX_WEEK_REMAINING_PCT%.*}%${STALE_WARN}"
echo "---"

# ── Claude ───────────────────────────────────────────────
OAUTH_MARK=""; [ "$CLA_OAUTH_FRESH" != "1" ] && OAUTH_MARK=" (概算)"
echo "Claude (Max 20x)${OAUTH_MARK} | font=Menlo size=13 color=$CLA_COLOR"
echo "  セッション(5h)  残${CLA_5H_REMAINING_PCT}% (${CLA_5H_USED_PCT}%使用) | font=Menlo size=12 color=$CLA_COLOR"
echo "  週次 全モデル   残${CLA_7D_REMAINING_PCT}% (${CLA_7D_USED_PCT}%使用) | font=Menlo size=12"
echo "  週次 Sonnetのみ 残${CLA_7D_SONNET_REMAINING_PCT}% (${CLA_7D_SONNET_USED_PCT}%使用) | font=Menlo size=12"
echo "  7d    $(awk "BEGIN{printf \"%.1fG\",$CLA_7D_TOKENS/1000000000}") tokens / \$$(printf '%.2f' "$CLA_7D_COST") | font=Menlo size=12"
echo "---"

# ── Codex ────────────────────────────────────────────────
FRESH_MARK=""; [ "$CDX_RATE_LIMITS_FRESH" != "1" ] && FRESH_MARK=" (データ古い可能性)"
echo "Codex (Plus)${FRESH_MARK} | font=Menlo size=13"
echo "  5h窓  ${CDX_5H_ICON} 残り ${CDX_5H_REMAINING_PCT}% (${CDX_5H_USED_PCT}%使用) リセット:${CDX_5H_RESET_TIME} | font=Menlo size=12 color=$CDX_5H_COLOR"
echo "  週次  ${CDX_WK_ICON} 残り ${CDX_WEEK_REMAINING_PCT}% (${CDX_WEEK_USED_PCT}%使用) リセット:${CDX_WEEK_RESET_DATE} | font=Menlo size=12 color=$CDX_WK_COLOR"
echo "---"

# ── ルーティングモード ────────────────────────────────────
case "$ROUTING_MODE" in
  claude_critical) echo "🚨 [Claude-Critical] | color=#FF3B30 font=Menlo size=12"
                   echo "  全タスクをCodexへ。Claude:必須ツール操作のみ | font=Menlo size=11 color=#888888" ;;
  save_claude)     echo "⚠️  [Save-Claude] Claude温存中 | color=#FF9500 font=Menlo size=12"
                   echo "  read/review/analysis → Codex | font=Menlo size=11 color=#888888" ;;
  codex_burn)      echo "🔥 [Burn-Codex] Codexリセット前余剰 | color=#FF9500 font=Menlo size=12"
                   echo "  積極的にCodexへ振る | font=Menlo size=11 color=#888888" ;;
  claude_burn)     echo "🔥 [Burn-Claude] Claudeリセット前余剰 | color=#FF9500 font=Menlo size=12"
                   echo "  Claude積極使用 | font=Menlo size=11 color=#888888" ;;
  codex_first)     echo "🟡 [Codex-First] | color=#FF9500 font=Menlo size=12"
                   echo "  Research & review → Codex | font=Menlo size=11 color=#888888" ;;
  protect_codex)   echo "⚠️  [Codex-Save] Codex low | color=#FF9500 font=Menlo size=12"
                   echo "  Claude-centric until weekly reset | font=Menlo size=11 color=#888888" ;;
  claude_first)    echo "🔵 [Claude-First] | color=#007AFF font=Menlo size=12"
                   echo "  Codex > Claude: バランス調整中 | font=Menlo size=11 color=#888888" ;;
  *)               echo "🟢 [Balanced] | color=#34C759 font=Menlo size=12" ;;
esac
echo "---"

UPDATED_AT=$(date -r "$TIMESTAMP" +'%H:%M' 2>/dev/null || echo "?")
echo "最終更新: ${UPDATED_AT} | color=#888888 size=11"
echo "今すぐ更新 | bash=$UPDATE_SCRIPT terminal=false refresh=true"

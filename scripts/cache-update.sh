#!/bin/bash
# AI Usage Cache Update — runs every 5min via launchd
# Writes cache to $DARWIN_USER_TEMP_DIR/ai-usage-monitor/ for SwiftBar and hooks (macOS only)

set -euo pipefail

# shellcheck source=lib/cache-path.sh
source "$(dirname "$0")/lib/cache-path.sh"
# shellcheck source=lib/reset-label.sh
source "$(dirname "$0")/lib/reset-label.sh"  # roll_resets_at_forward（ロールオーバー投影・#18）
init_cache_dir

# ── 単一実行ロック（Issue #24）──────────────────────────────
# lock 所有権を cache-update.sh 側に集約する。これにより launchd の定期実行と
# SessionStart hook の即時更新が競合せず（二重更新防止）、正常/異常終了どちらでも
# trap で必ず解放される（session-start hook 側の lock leak も同時解消）。
# stale lock（死んだ PID or 10分 TTL 超）は掃除してから取得する。
_now_lock=$(date +%s)
if [ -d "$LOCK_DIR" ]; then
  _lk_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  _lk_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
  if [[ "$_lk_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$_lk_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR"                          # 死んだ PID
  elif [ "$(( _now_lock - _lk_mtime ))" -gt 600 ]; then
    rm -rf "$LOCK_DIR"                          # TTL 超過（実行最大時間超え）
  fi
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0                                        # 別の更新が実行中 → skip（べき等）
fi
echo $$ > "$LOCK_DIR/pid"
# 正常/異常/シグナル終了いずれでも lock と TMP_FILE を解放（SIGKILL のみ次回 stale cleanup）
trap 'rm -rf "$LOCK_DIR"; [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"' EXIT

TMP_FILE=$(mktemp -t ai_usage_cache.XXXXXX)

export PATH="$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -1)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

TODAY=$(LC_ALL=C date +%Y-%m-%d)
TODAY_NUM=$(LC_ALL=C date +%Y%m%d)
SEVEN_AGO_NUM=$(LC_ALL=C date -v-6d +%Y%m%d)
TODAY_CODEX_FMT=$(LC_ALL=C date +'%b %d, %Y')
DOW=$(date +%u)
BILLING_WEEK_START=$(LC_ALL=C date -v-$(( DOW - 1 ))d +%Y-%m-%d)
# CDX_DAYS_UNTIL_RESET / CDX_HOURS_UNTIL_RESET は epoch ベースで後段に計算（DOW計算は廃止）

# ── Claude 使用量 — Anthropic OAuth API（GUI と同一データ源）──
CLA_OAUTH_JSON=""
CLA_5H_USED_PCT=0
CLA_5H_REMAINING_PCT=100
CLA_7D_USED_PCT=0
CLA_7D_REMAINING_PCT=100
CLA_7D_SONNET_USED_PCT=0
CLA_7D_SONNET_REMAINING_PCT=100
CLA_5H_RESETS_AT_ISO=""
CLA_7D_RESETS_AT_ISO=""
CLA_OAUTH_FRESH=0

# Keychain から OAuth access token を取得（security コマンド経由）
CLA_ACCESS_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read().strip())
    print(d.get('claudeAiOauth', {}).get('accessToken', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

if [ -n "$CLA_ACCESS_TOKEN" ]; then
  CLA_OAUTH_JSON=$(curl -sf --max-time 10 \
    "https://api.anthropic.com/api/oauth/usage" \
    -H "Authorization: Bearer $CLA_ACCESS_TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "User-Agent: claude-code/$(claude --version 2>/dev/null | head -1 | awk '{print $NF}' || echo '2.1.0')" \
    -H "Accept: application/json" 2>/dev/null || echo "")
fi

if [ -n "$CLA_OAUTH_JSON" ] && echo "$CLA_OAUTH_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
  read CLA_5H_USED_PCT CLA_5H_RESETS_AT_EPOCH \
       CLA_7D_USED_PCT CLA_7D_RESETS_AT_EPOCH \
       CLA_7D_SONNET_USED_PCT < <(echo "$CLA_OAUTH_JSON" | python3 -c "
import json, sys
from datetime import datetime, timezone
d = json.load(sys.stdin)
def pct(key):
    v = d.get(key, {})
    return float(v.get('utilization', 0) if v else 0)
def epoch(key):
    v = d.get(key, {})
    s = v.get('resets_at') if v else None
    if not s: return 0
    try:
        from datetime import datetime, timezone
        dt = datetime.fromisoformat(s.replace('Z','+00:00'))
        return int(dt.timestamp())
    except: return 0
print(pct('five_hour'), epoch('five_hour'),
      pct('seven_day'), epoch('seven_day'),
      pct('seven_day_sonnet'))
" 2>/dev/null)
  CLA_5H_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", 100-${CLA_5H_USED_PCT:-0}}")
  CLA_7D_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", 100-${CLA_7D_USED_PCT:-0}}")
  CLA_7D_SONNET_REMAINING_PCT=$(awk "BEGIN{printf \"%d\", 100-${CLA_7D_SONNET_USED_PCT:-0}}")
  CLA_OAUTH_FRESH=1
fi

# ── Claude ロールオーバー投影（Issue #18・Codex と対称）────────
# Claude window は固定（7d=10080min / 5h=300min）。OAuth API に window_minutes は無いため定数。
# resets_at が過去 = リセット済み → 次リセットへ巻き進め、使用量を fresh に投影。
_NOW_CLA_ROLL=$(date +%s)
if [ "${CLA_7D_RESETS_AT_EPOCH:-0}" -gt 0 ] && [ "${CLA_7D_RESETS_AT_EPOCH}" -le "$_NOW_CLA_ROLL" ]; then
  CLA_7D_RESETS_AT_EPOCH=$(roll_resets_at_forward "$CLA_7D_RESETS_AT_EPOCH" "$_NOW_CLA_ROLL" 10080)
  CLA_7D_USED_PCT=0
  CLA_7D_REMAINING_PCT=100
fi
if [ "${CLA_5H_RESETS_AT_EPOCH:-0}" -gt 0 ] && [ "${CLA_5H_RESETS_AT_EPOCH}" -le "$_NOW_CLA_ROLL" ]; then
  CLA_5H_RESETS_AT_EPOCH=$(roll_resets_at_forward "$CLA_5H_RESETS_AT_EPOCH" "$_NOW_CLA_ROLL" 300)
  CLA_5H_USED_PCT=0
  CLA_5H_REMAINING_PCT=100
fi

# Claude 7d リセットまでの残り時間（epochベース）
CLA_7D_HOURS_UNTIL_RESET=0
_cla_now=$(date +%s)
if [ "${CLA_7D_RESETS_AT_EPOCH:-0}" -gt "$_cla_now" ]; then
  _cla_secs=$(( CLA_7D_RESETS_AT_EPOCH - _cla_now ))
  CLA_7D_HOURS_UNTIL_RESET=$(( _cla_secs / 3600 ))
fi

# ccusage でトークン数とコストも取得（OAuth API にはない詳細）
CLA_BLOCKS=$(npx -y ccusage@latest blocks --json --offline 2>/dev/null < /dev/null \
  || echo '{"blocks":[]}')
CLA_5H_TOKENS=$(echo "$CLA_BLOCKS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
active=[b for b in d.get('blocks',[]) if b.get('isActive')]
print(active[-1].get('totalTokens',0) if active else 0)
" 2>/dev/null || echo 0)
CLA_5H_RESET_AT=$(echo "$CLA_BLOCKS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
active=[b for b in d.get('blocks',[]) if b.get('isActive')]
print(active[-1].get('endTime','') if active else '')
" 2>/dev/null || echo "")

# 後方互換用: CLA_5H_REMAINING_MINS は OAuth % から逆算（近似）
CLA_5H_REMAINING_MINS=$(awk "BEGIN{printf \"%d\", $CLA_5H_REMAINING_PCT*300/100}")

# ── Claude 7d ─────────────────────────────────────────────
CLA_JSON=$(npx -y ccusage@latest daily --json --since "$SEVEN_AGO_NUM" --until "$TODAY_NUM" --offline 2>/dev/null < /dev/null \
  || echo '{"daily":[]}')
CLA_7D_TOKENS=$(echo "$CLA_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(x.get('totalTokens',0) for x in d.get('daily',[])))")
CLA_7D_COST=$(echo "$CLA_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(sum(x.get('totalCost',0)   for x in d.get('daily',[])))")
CLA_24H_TOKENS=$(echo "$CLA_JSON" | python3 -c "
import json,sys; d=json.load(sys.stdin)
rows=[x for x in d.get('daily',[]) if x.get('date','')=='$TODAY']
print(rows[0].get('totalTokens',0) if rows else 0)")
CLA_24H_COST=$(echo "$CLA_JSON" | python3 -c "
import json,sys; d=json.load(sys.stdin)
rows=[x for x in d.get('daily',[]) if x.get('date','')=='$TODAY']
print(rows[0].get('totalCost',0) if rows else 0)")

# ── Codex 残量% — セッションJSONLの rate_limits から取得 ──
# パーサは scripts/lib/parse_codex_rate_limits.py に分離（テスト可能化・Issue #7）。
# primary/secondary=null（premium 切替・週枯渇マーカー）を skip して
# 直近の有効な rate_limits を採用する。
# python3クラッシュ時のread失敗（set -euo pipefail 即死）を防ぐためデフォルト初期化
CDX_5H_USED_PCT=0 CDX_5H_REMAINING_PCT=100 CDX_5H_RESETS_AT=0
CDX_WEEK_USED_PCT=0 CDX_WEEK_REMAINING_PCT=100 CDX_WEEK_RESETS_AT=0
CDX_RATE_LIMITS_FRESH=0 CDX_5H_WINDOW_MIN=0 CDX_WEEK_WINDOW_MIN=0
_cdx_out=$(python3 "$(dirname "$0")/lib/parse_codex_rate_limits.py" "$HOME/.codex/sessions" 2>/dev/null) || true
[ -n "$_cdx_out" ] && read CDX_5H_USED_PCT CDX_5H_REMAINING_PCT CDX_5H_RESETS_AT \
     CDX_WEEK_USED_PCT CDX_WEEK_REMAINING_PCT CDX_WEEK_RESETS_AT \
     CDX_RATE_LIMITS_FRESH CDX_5H_WINDOW_MIN CDX_WEEK_WINDOW_MIN <<< "$_cdx_out"

# ── ロールオーバー投影（Issue #18）────────────────────────────
# resets_at が過去 = ウィンドウは既に周期リセット済み。Codex を使わないと fresh データが
# 来ず、stale な「枯渇 + ↺soon」が永久固定される。window_minutes が既知なら次リセットへ
# 巻き進め、使用量を fresh（残100%）に投影して表示・ルーティングを正常化する。
# window はデータ値があればそれ、欠落(0)なら定義上固定の定数（週=10080 / 5h=300）に
# フォールバック。これにより data 欠落イベントでも投影が効き soon 固定を確実に解消する。
_NOW_ROLL=$(date +%s)
_CDX_WK_WIN=${CDX_WEEK_WINDOW_MIN:-0}; [ "$_CDX_WK_WIN" -gt 0 ] 2>/dev/null || _CDX_WK_WIN=10080
_CDX_5H_WIN=${CDX_5H_WINDOW_MIN:-0};   [ "$_CDX_5H_WIN" -gt 0 ] 2>/dev/null || _CDX_5H_WIN=300
if [ "${CDX_WEEK_RESETS_AT:-0}" -gt 0 ] && [ "${CDX_WEEK_RESETS_AT}" -le "$_NOW_ROLL" ]; then
  CDX_WEEK_RESETS_AT=$(roll_resets_at_forward "$CDX_WEEK_RESETS_AT" "$_NOW_ROLL" "$_CDX_WK_WIN")
  CDX_WEEK_USED_PCT=0
  CDX_WEEK_REMAINING_PCT=100
fi
if [ "${CDX_5H_RESETS_AT:-0}" -gt 0 ] && [ "${CDX_5H_RESETS_AT}" -le "$_NOW_ROLL" ]; then
  CDX_5H_RESETS_AT=$(roll_resets_at_forward "$CDX_5H_RESETS_AT" "$_NOW_ROLL" "$_CDX_5H_WIN")
  CDX_5H_USED_PCT=0
  CDX_5H_REMAINING_PCT=100
fi

# ── Codex トークン数（ccusage 補助データ）────────────────
CDX_JSON=$(npx -y @ccusage/codex@latest daily --json --since "$BILLING_WEEK_START" --until "$TODAY" --offline 2>/dev/null < /dev/null \
  || echo '{"daily":[],"totals":{"totalTokens":0,"costUSD":0}}')
CDX_WEEK_TOKENS=$(echo "$CDX_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totals',{}).get('totalTokens',0))")
CDX_WEEK_COST=$(echo "$CDX_JSON"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totals',{}).get('costUSD',0))")
CDX_24H_TOKENS=$(echo "$CDX_JSON" | python3 -c "
import json,sys; d=json.load(sys.stdin)
rows=[x for x in d.get('daily',[]) if x.get('date','')=='$TODAY_CODEX_FMT']
print(rows[0].get('totalTokens',0) if rows else 0)")
CDX_24H_COST=$(echo "$CDX_JSON" | python3 -c "
import json,sys; d=json.load(sys.stdin)
rows=[x for x in d.get('daily',[]) if x.get('date','')=='$TODAY_CODEX_FMT']
print(rows[0].get('costUSD',0) if rows else 0)")

# ── Codex リセットまでの残り時間（epoch ベース・リアルタイム）──
_NOW=$(date +%s)
CDX_HOURS_UNTIL_RESET=0
CDX_DAYS_UNTIL_RESET=7  # fallback: DOW計算
if [ "${CDX_WEEK_RESETS_AT:-0}" -gt "$_NOW" ]; then
  _CDX_SECS=$(( CDX_WEEK_RESETS_AT - _NOW ))
  CDX_HOURS_UNTIL_RESET=$(( _CDX_SECS / 3600 ))
  CDX_DAYS_UNTIL_RESET=$(( _CDX_SECS / 86400 ))
  [ "$CDX_DAYS_UNTIL_RESET" -eq 0 ] && CDX_DAYS_UNTIL_RESET=1  # 24h未満でも1d扱い（閾値用）
fi

# ── ルーティングモード判定（バランスギャップベース）──
# BALANCE_GAP = Claude7d残 - Codex週残（+ = Claude余裕あり、- = Codex余裕あり）
CDX_5H_REM_INT=${CDX_5H_REMAINING_PCT%.*}
CDX_WEEK_REM_INT=${CDX_WEEK_REMAINING_PCT%.*}
CLA_7D_REM_INT=${CLA_7D_REMAINING_PCT%.*}
# CDX_RATE_LIMITS_FRESH=0 の場合は Codex データが stale/取得失敗 → 満タン誤認を防ぐため GAP=0 扱い
if [ "${CDX_RATE_LIMITS_FRESH:-0}" = "1" ]; then
  BALANCE_GAP=$(( ${CLA_7D_REM_INT:-100} - ${CDX_WEEK_REM_INT:-100} ))
else
  BALANCE_GAP=0  # stale data → バランス中として扱い誤ルーティング防止
fi

# Codex使用可否: 5h残 >= 20% かつ リセット考慮の動的週次閾値以上
CDX_AVAILABLE=1
[ "${CDX_5H_REM_INT:-100}" -lt 20 ] && CDX_AVAILABLE=0
if   [ "${CDX_HOURS_UNTIL_RESET:-168}" -le 24 ]; then _CDX_WEEK_THR=3
elif [ "${CDX_HOURS_UNTIL_RESET:-168}" -le 48 ]; then _CDX_WEEK_THR=5
else                                                   _CDX_WEEK_THR=10
fi
[ "${CDX_WEEK_REM_INT:-100}" -lt "$_CDX_WEEK_THR" ] && CDX_AVAILABLE=0

# バランスギャップでモード決定（±10%以内を目標）
# ── ルーティングモード判定 ──────────────────────────────────
# 優先順位: Claude保護 > Codex保護 > Burn > バランス
#
# 【Claude保護閾値】リセットまでの時間でスケール
#   threshold = base × (hours_until_reset / 168)
#   例) save基準15%・残り14h → 15×14/168=1.3%→min2% → 15%あっても問題なし
#       save基準15%・残り160h → 14.3% → 15%は危険
# 切り上げ(ceil)で計算: floor だとコメント通りの保護閾値より1低くなる (#41)
_CLA_CRIT_THR=$(awk "BEGIN{v=5*${CLA_7D_HOURS_UNTIL_RESET:-168}/168; c=int(v); if(v>c)c++; if(c<1)c=1; printf \"%d\", c}")
_CLA_SAVE_THR=$(awk "BEGIN{v=15*${CLA_7D_HOURS_UNTIL_RESET:-168}/168; c=int(v); if(v>c)c++; if(c<2)c=2; printf \"%d\", c}")

# 【Burn機会検出】リセットまでに使いきれない余剰がある = 積極消費すべき
#   実消費ペース: 約20%/day（オーナー報告: 1日15-25%）
#   projected_at_reset = remaining% - (hours_until_reset × 20 / 24)
#   projected > 25% → リセット後も25%以上余る → burn機会あり
DAILY_BURN_PCT=${DAILY_BURN_PCT:-20}  # 環境変数で上書き可能（デフォルト: 20%/day）
# Burn判定: fresh data かつ reset epoch 既知の場合のみ算出（stale/未取得時は burn=0）
_CDX_PROJECTED=0; _CDX_BURN=0
if [ "${CDX_RATE_LIMITS_FRESH:-0}" = "1" ] && [ "${CDX_HOURS_UNTIL_RESET:-0}" -gt 0 ]; then
  _CDX_PROJECTED=$(awk "BEGIN{v=${CDX_WEEK_REM_INT:-0}-${CDX_HOURS_UNTIL_RESET}*${DAILY_BURN_PCT}/24; if(v<0)v=0; printf \"%d\", v}")
  [ "$_CDX_PROJECTED" -ge 25 ] && _CDX_BURN=1
fi

_CLA_PROJECTED=0; _CLA_BURN=0
if [ "${CLA_OAUTH_FRESH:-0}" = "1" ] && [ "${CLA_7D_HOURS_UNTIL_RESET:-0}" -gt 0 ]; then
  _CLA_PROJECTED=$(awk "BEGIN{v=${CLA_7D_REM_INT:-0}-${CLA_7D_HOURS_UNTIL_RESET}*${DAILY_BURN_PCT}/24; if(v<0)v=0; printf \"%d\", v}")
  [ "$_CLA_PROJECTED" -ge 25 ] && _CLA_BURN=1
fi

if   [ "${CLA_7D_REM_INT:-100}" -lt "$_CLA_CRIT_THR" ]; then
  ROUTING_MODE="claude_critical"  # 緊急: 全力でCodexへ逃がす
elif [ "${CLA_7D_REM_INT:-100}" -lt "$_CLA_SAVE_THR" ]; then
  ROUTING_MODE="save_claude"      # Codex最大活用でClaudeを温存
elif [ "$CDX_AVAILABLE" -eq 0 ]; then
  ROUTING_MODE="protect_codex"    # Codex枯渇 → Claude維持
elif [ "$_CDX_BURN" -eq 1 ] && [ "$_CLA_BURN" -eq 0 ]; then
  ROUTING_MODE="codex_burn"       # Codexリセット前に余剰あり → ガンガンCodexへ
elif [ "$_CLA_BURN" -eq 1 ] && [ "$_CDX_BURN" -eq 0 ]; then
  ROUTING_MODE="claude_burn"      # Claudeリセット前に余剰あり → Claude積極使用
elif [ "$BALANCE_GAP" -gt 10 ]; then
  ROUTING_MODE="codex_first"      # Claude > Codex (+10%超) → Codex優先
elif [ "$BALANCE_GAP" -lt -10 ]; then
  ROUTING_MODE="claude_first"     # Codex > Claude (-10%超) → Claude優先
else
  ROUTING_MODE="normal"           # ±10%以内 or 両方burn → バランス中
fi

# ── Codex未活用警告フラグ（Issue #5: 判定cache側集約、Issue #6: epoch判定）──
# CDX_WEEK_RESETS_AT（将来epoch）を使い「リセットから1日以上経過かつ週残90%以上」で判定。
# DOW曜日固定から脱却し、リセット時刻が変わっても追従する。
CDX_UNDERUSE_WARN=0
# 数値ガード: 外部JSONL由来の値が非数値の場合は警告スキップ（誤発火防止）
case "${CDX_WEEK_REM_INT:-}" in ''|*[!0-9]*) CDX_WEEK_REM_INT="" ;; esac
if [ -n "${CDX_WEEK_REM_INT:-}" ] && [ "$CDX_WEEK_REM_INT" -ge 90 ] && [ "${CDX_RATE_LIMITS_FRESH:-0}" = "1" ]; then
  _NOW=$(date +%s)
  _RESETS_AT="${CDX_WEEK_RESETS_AT:-0}"
  # リセットまで6日未満 = 週開始から1日以上経過（誤発火防止の1日猶予）
  # 7日=604800s, 6日=518400s
  if [ "$_RESETS_AT" -gt 0 ]; then
    _DIFF=$(( _RESETS_AT - _NOW ))
    # 下限 > 0: リセット時刻が過去になった（旧 resets_at 残存）場合の誤発火防止
    [ "$_DIFF" -gt 0 ] && [ "$_DIFF" -lt 518400 ] && CDX_UNDERUSE_WARN=1
  fi
fi

# ── キャッシュ書き込み（atomic）──────────────────────────
{
  echo "TIMESTAMP=$(date +%s)"
  echo "GENERATED_AT=$(date +'%Y-%m-%dT%H:%M:%S%z')"
  echo "CLA_OAUTH_FRESH=$CLA_OAUTH_FRESH"
  echo "CLA_7D_HOURS_UNTIL_RESET=$CLA_7D_HOURS_UNTIL_RESET"
  echo "CLA_5H_USED_PCT=$CLA_5H_USED_PCT"
  echo "CLA_5H_REMAINING_PCT=$CLA_5H_REMAINING_PCT"
  echo "CLA_5H_REMAINING_MINS=$CLA_5H_REMAINING_MINS"
  echo "CLA_7D_USED_PCT=$CLA_7D_USED_PCT"
  echo "CLA_7D_REMAINING_PCT=$CLA_7D_REMAINING_PCT"
  echo "CLA_7D_SONNET_USED_PCT=$CLA_7D_SONNET_USED_PCT"
  echo "CLA_7D_SONNET_REMAINING_PCT=$CLA_7D_SONNET_REMAINING_PCT"
  echo "CLA_5H_RESETS_AT=$CLA_5H_RESETS_AT_EPOCH"
  echo "CLA_7D_RESETS_AT=$CLA_7D_RESETS_AT_EPOCH"
  echo "CLA_5H_TOKENS=$CLA_5H_TOKENS"
  echo "CLA_5H_RESET_AT=$CLA_5H_RESET_AT"
  echo "CLA_24H_TOKENS=$CLA_24H_TOKENS"
  echo "CLA_24H_COST=$CLA_24H_COST"
  echo "CLA_7D_TOKENS=$CLA_7D_TOKENS"
  echo "CLA_7D_COST=$CLA_7D_COST"
  echo "CDX_24H_TOKENS=$CDX_24H_TOKENS"
  echo "CDX_24H_COST=$CDX_24H_COST"
  echo "CDX_WEEK_TOKENS=$CDX_WEEK_TOKENS"
  echo "CDX_WEEK_COST=$CDX_WEEK_COST"
  echo "CDX_BILLING_WEEK_START=$BILLING_WEEK_START"
  echo "CDX_HOURS_UNTIL_RESET=$CDX_HOURS_UNTIL_RESET"
  echo "CDX_DAYS_UNTIL_RESET=$CDX_DAYS_UNTIL_RESET"
  echo "CDX_5H_USED_PCT=$CDX_5H_USED_PCT"
  echo "CDX_5H_REMAINING_PCT=$CDX_5H_REMAINING_PCT"
  echo "CDX_5H_RESETS_AT=$CDX_5H_RESETS_AT"
  echo "CDX_WEEK_USED_PCT=$CDX_WEEK_USED_PCT"
  echo "CDX_WEEK_REMAINING_PCT=$CDX_WEEK_REMAINING_PCT"
  echo "CDX_WEEK_RESETS_AT=$CDX_WEEK_RESETS_AT"
  echo "CDX_5H_WINDOW_MIN=$CDX_5H_WINDOW_MIN"
  echo "CDX_WEEK_WINDOW_MIN=$CDX_WEEK_WINDOW_MIN"
  echo "CDX_RATE_LIMITS_FRESH=$CDX_RATE_LIMITS_FRESH"
  echo "ROUTING_MODE=$ROUTING_MODE"
  echo "BALANCE_GAP=$BALANCE_GAP"
  echo "CDX_PROJECTED_AT_RESET=$_CDX_PROJECTED"
  echo "CLA_PROJECTED_AT_RESET=$_CLA_PROJECTED"
  echo "CDX_UNDERUSE_WARN=$CDX_UNDERUSE_WARN"
} > "$TMP_FILE"

mv -f "$TMP_FILE" "$CACHE_FILE"
chmod 600 "$CACHE_FILE"

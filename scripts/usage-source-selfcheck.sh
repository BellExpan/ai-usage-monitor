#!/bin/bash
# Validate external usage data contracts.  Fail-open: emit unknown and exit 0.

set -u

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/cache-path.sh
source "$_SCRIPT_DIR/lib/cache-path.sh"

CACHE_PATH="$CACHE_FILE"
CODEX_SESSIONS="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
CLAUDE_SESSIONS="${CLAUDE_SESSIONS_DIR:-$HOME/.claude}"
TODAY=$(LC_ALL=C date +%Y-%m-%d)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache) CACHE_PATH="${2:-}"; shift 2 ;;
    --sessions) CODEX_SESSIONS="${2:-}"; shift 2 ;;
    --claude-sessions) CLAUDE_SESSIONS="${2:-}"; shift 2 ;;
    --emit-cache-line) shift ;;
    *) shift ;;
  esac
done

_emit() {
  echo "USAGE_SRC_HEALTH=$1"
  exit 0
}

_kv() {
  local key="$1" file="$2"
  awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }' "$file" 2>/dev/null
}

_int() {
  case "${1:-}" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

# Rate-limit schema checks are only actionable when recent Codex telemetry
# exists.  The freshness threshold is 24h, matching TOKENS_24H/EVENTS_24H from
# codex_native_tokens.py and FRESH from parse_codex_rate_limits.py.
RATE_LIMIT_DRIFT_FRESH_EVENTS_24H=24

_add_reason() {
  local reason="$1"
  case ",$REASONS," in *",$reason,"*) return ;; esac
  if [ -n "$REASONS" ]; then
    REASONS="$REASONS,$reason"
  else
    REASONS="$reason"
  fi
}

_tool_version() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    "$tool" --version 2>/dev/null | head -1
  else
    echo ""
  fi
}

_check_versions() {
  init_cache_dir >/dev/null 2>&1 || return 0
  local version_file="$AI_USAGE_DIR/upstream-versions"
  local tmp="$AI_USAGE_DIR/upstream-versions.tmp.$$"
  local changed=0 key old new

  : > "$tmp" 2>/dev/null || return 0
  for key in ccusage codex; do
    new=$(_tool_version "$key")
    [ -n "$new" ] || continue
    printf '%s=%s\n' "$key" "$new" >> "$tmp"
    if [ -f "$version_file" ]; then
      old=$(awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }' "$version_file" 2>/dev/null)
      [ -n "$old" ] && [ "$old" != "$new" ] && changed=1
    fi
  done

  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$version_file" 2>/dev/null || true
    chmod 600 "$version_file" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  [ "$changed" = "1" ] && _add_reason "upstream_version_changed"
}

_claude_activity_today() {
  python3 - "$CLAUDE_SESSIONS" "$TODAY" <<'PY' 2>/dev/null
import datetime as dt
import glob
import json
import os
import sys

root, today = sys.argv[1], sys.argv[2]
try:
    start = dt.datetime.strptime(today, "%Y-%m-%d").timestamp()
except Exception:
    print(0)
    raise SystemExit

for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(path) < start:
            continue
    except OSError:
        continue
    try:
        fp = open(path, encoding="utf-8")
    except OSError:
        continue
    with fp:
        for line in fp:
            try:
                row = json.loads(line)
            except Exception:
                continue
            ts = str(row.get("timestamp") or "")
            if ts.startswith(today):
                print(1)
                raise SystemExit
print(0)
PY
}

_main() {
  [ "${AI_USAGE_SELFCHECK_FORCE_EXCEPTION:-0}" = "1" ] && return 99

  REASONS=""
  [ -f "$CACHE_PATH" ] || return 2

  local native_out rate_out
  native_out=$(python3 "$_SCRIPT_DIR/lib/codex_native_tokens.py" "$CODEX_SESSIONS" --today "$TODAY" 2>/dev/null) || return 3
  rate_out=$(python3 "$_SCRIPT_DIR/lib/parse_codex_rate_limits.py" "$CODEX_SESSIONS" 2>/dev/null) || return 4

  local native_today native_events_today native_events_24h cache_cdx_today
  native_today=$(_int "$(printf '%s\n' "$native_out" | awk -F= '$1=="TOKENS_TODAY"{print $2; exit}')")
  native_events_today=$(_int "$(printf '%s\n' "$native_out" | awk -F= '$1=="EVENTS_TODAY"{print $2; exit}')")
  native_events_24h=$(_int "$(printf '%s\n' "$native_out" | awk -F= '$1=="EVENTS_24H"{print $2; exit}')")
  cache_cdx_today=$(_int "$(_kv CDX_24H_TOKENS "$CACHE_PATH")")

  # cache のトークン値が stale（取得失敗で前回値を保持した状態）なら、
  # それは「昨日の today bucket」でありうる。today 基準の native と比較すると
  # 必ず乖離し token_source_mismatch が誤発火する（PR #38 レビュー指摘）。
  # stale は「計測が壊れている」ではなく「今回取れなかった」なので、
  # トークン系の判定自体を skip する（rate limit 系の判定は継続）。
  local cdx_tokens_stale
  cdx_tokens_stale=$(_int "$(_kv CDX_TOKENS_STALE "$CACHE_PATH")")

  if [ "$cdx_tokens_stale" = "1" ]; then
    :  # stale の間はトークン突き合わせを行わない
  elif [ "$native_events_today" -gt 0 ] && [ "$cache_cdx_today" -eq 0 ]; then
    _add_reason "codex_tokens_zero_despite_activity"
  fi

  if [ "$cdx_tokens_stale" = "1" ]; then
    :  # 同上
  elif { [ "$native_today" -eq 0 ] && [ "$cache_cdx_today" -gt 0 ]; } || \
     { [ "$native_today" -gt 0 ] && [ "$cache_cdx_today" -eq 0 ]; }; then
    _add_reason "token_source_mismatch"
  elif [ "$native_today" -gt 0 ] && [ "$cache_cdx_today" -gt 0 ]; then
    local big small
    if [ "$native_today" -ge "$cache_cdx_today" ]; then
      big="$native_today"; small="$cache_cdx_today"
    else
      big="$cache_cdx_today"; small="$native_today"
    fi
    [ "$big" -ge $(( small * 2 )) ] && _add_reason "token_source_mismatch"
  fi

  local wk_avail wk_resets rate_fresh now cla_fresh cla_tokens cla_activity
  wk_avail=$(_int "$(printf '%s\n' "$rate_out" | awk -F= '$1=="WK_AVAILABLE"{print $2; exit}')")
  wk_resets=$(_int "$(printf '%s\n' "$rate_out" | awk -F= '$1=="WK_RESETS_AT"{print $2; exit}')")
  rate_fresh=$(_int "$(printf '%s\n' "$rate_out" | awk -F= '$1=="FRESH"{print $2; exit}')")
  now=$(date +%s)
  if [ "$native_events_24h" -gt 0 ] || [ "$rate_fresh" = "1" ]; then
    [ "$wk_avail" = "0" ] && _add_reason "rate_limit_schema_drift"
    if [ "$wk_avail" = "1" ] && { [ "$wk_resets" -eq 0 ] || [ "$wk_resets" -le "$now" ]; }; then
      _add_reason "rate_limit_resets_at_invalid"
    fi
  fi

  cla_fresh=$(_int "$(_kv CLA_OAUTH_FRESH "$CACHE_PATH")")
  [ "$cla_fresh" = "0" ] && _add_reason "claude_oauth_unavailable"

  cla_tokens=$(_int "$(_kv CLA_24H_TOKENS "$CACHE_PATH")")
  cla_activity=$(_int "$(_claude_activity_today)")
  # Claude 側も対称に扱う: stale（前回値保持）なら「今日 0」ではないので判定しない
  local cla_tokens_stale
  cla_tokens_stale=$(_int "$(_kv CLA_TOKENS_STALE "$CACHE_PATH")")
  [ "$cla_tokens_stale" != "1" ] && [ "$cla_activity" -gt 0 ] && [ "$cla_tokens" -eq 0 ] \
    && _add_reason "claude_tokens_zero_despite_activity"

  _check_versions

  if [ -n "$REASONS" ]; then
    _emit "degraded:$REASONS"
  fi
  _emit "ok"
}

if ! _main; then
  _emit "unknown"
fi

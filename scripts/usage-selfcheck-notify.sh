#!/bin/bash
# Daily usage-source selfcheck notification wrapper.  Fail-open by design.

set -u

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/cache-path.sh
source "$REPO_DIR/scripts/lib/cache-path.sh"
init_cache_dir >/dev/null 2>&1 || exit 0

SELF_CHECK="$REPO_DIR/scripts/usage-source-selfcheck.sh"
SLACK_NOTIFY="/Volumes/EX_SSD/bellExpan/GitHub/org/ai-org/.claude/scripts/notify-slack.sh"
STATE_FILE="$AI_USAGE_DIR/selfcheck-notified"

out=$(bash "$SELF_CHECK" 2>/dev/null || echo "USAGE_SRC_HEALTH=unknown")
health=${out#USAGE_SRC_HEALTH=}
case "$health" in
  degraded:*) reasons=${health#degraded:} ;;
  *) exit 0 ;;
esac

now=$(date +%s)
IFS=',' read -r -a reason_arr <<< "$reasons"
for reason in "${reason_arr[@]}"; do
  [ -n "$reason" ] || continue
  last=$(awk -F= -v k="$reason" '$1 == k { print $2; exit }' "$STATE_FILE" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt 86400 ] && continue

  msg="[usage-monitor] データ源 degraded: $reason"
  if [ -x "$SLACK_NOTIFY" ]; then
    "$SLACK_NOTIFY" "$msg" >/dev/null 2>&1 || true
  fi

  if command -v gh >/dev/null 2>&1; then
    cd "$REPO_DIR" 2>/dev/null || true
    title="[usage-monitor] データ源 degraded: $reason"
    existing=$(gh issue list --state open --search "$title in:title" --json title --jq '.[].title' 2>/dev/null | awk -v t="$title" '$0 == t { found=1 } END { print found ? 1 : 0 }')
    if [ "$existing" != "1" ]; then
      gh issue create --title "$title" --body "usage-source-selfcheck detected \`$reason\` on $(date +'%Y-%m-%d %H:%M:%S %z')." >/dev/null 2>&1 || true
    fi
  fi

  tmp="$STATE_FILE.tmp.$$"
  awk -F= -v k="$reason" '$1 != k { print }' "$STATE_FILE" 2>/dev/null > "$tmp" || true
  printf '%s=%s\n' "$reason" "$now" >> "$tmp"
  mv -f "$tmp" "$STATE_FILE" 2>/dev/null || true
  chmod 600 "$STATE_FILE" 2>/dev/null || true
done

exit 0

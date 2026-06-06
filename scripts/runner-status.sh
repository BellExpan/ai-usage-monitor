#!/bin/bash
# runner-status.sh — GitHub Actions self-hosted runner の状態を1行で出力する
# session-start.sh から呼び出されるが、単独でも動作する
#
# 出力例:
#   Runner: 🟢 online busy=false
#   Runner: 🔴 offline  → launchctl start ...
#   Runner: ⚠️ queued>30min: 2件
#
# 環境変数:
#   RUNNER_NAME       監視対象 runner 名 (デフォルト: bellspan-mac-pro-m4)
#   RUNNER_ORG        所属 org            (デフォルト: BellExpan)
#   STUCK_WATCH_REPO  queued 監視対象 repo (デフォルト: BellExpan/nyan-gram)

RUNNER_NAME=${RUNNER_NAME:-bellspan-mac-pro-m4}
RUNNER_ORG=${RUNNER_ORG:-BellExpan}
STUCK_REPO=${STUCK_WATCH_REPO:-BellExpan/nyan-gram}

# Runner ステータス取得（jq injection防止: env.RUNNER_NAME で参照）
_runner_json=$(RUNNER_NAME="$RUNNER_NAME" timeout 5 gh api "orgs/${RUNNER_ORG}/actions/runners" \
  --jq '.runners[] | select(.name==env.RUNNER_NAME) | {status:.status,busy:.busy}' \
  2>/dev/null || echo '{}')
_runner_status=$(echo "$_runner_json" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('status','not-registered'))" 2>/dev/null || echo "unknown")
_runner_busy=$(echo "$_runner_json" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('busy','?'))" 2>/dev/null || echo "?")

case "$_runner_status" in
  online)         _runner_icon="🟢" ;;
  offline)        _runner_icon="🔴" ;;
  not-registered) _runner_icon="🔴" ;;
  *)              _runner_icon="🟡" ;;
esac

# 30分超 queued ジョブ検出
_stuck_warn=""
_queued_old=$(timeout 5 gh api "repos/${STUCK_REPO}/actions/runs" \
  --jq '[.workflow_runs[] | select(.status=="queued") |
    select((now - (.created_at | fromdateiso8601)) > 1800)] | length' \
  2>/dev/null || echo 0)
[ "${_queued_old:-0}" -gt 0 ] && _stuck_warn=" ⚠️ queued>30min: ${_queued_old}件"

echo "Runner: ${_runner_icon} ${_runner_status} busy=${_runner_busy}${_stuck_warn}"

if [ "$_runner_status" = "offline" ]; then
  echo "  → launchctl start gui/$(id -u)/actions.runner.${RUNNER_ORG}.${RUNNER_NAME}"
elif [ "$_runner_status" = "not-registered" ]; then
  echo "  → Runner未登録: GitHub Actions Self-hosted Runner のセットアップが必要"
fi

#!/bin/bash
# bg-status.sh — CLI to set/clear per-job background progress in the statusline (Issues #44, #46)
#
# Usage:
#   scripts/bg-status.sh set <message>            # default key（後方互換）
#   scripts/bg-status.sh set <key> <message>      # job 別（例: set ci "3/5 passing"）
#   scripts/bg-status.sh clear                     # 全 job をクリア
#   scripts/bg-status.sh clear <key>               # その job のみクリア
#
# バックグラウンドジョブが進捗をステータスラインに流すための薄い CLI ラッパ。
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bg-status.sh
source "$_DIR/lib/bg-status.sh"

case "${1:-}" in
  set)
    shift
    if [ "$#" -ge 2 ]; then
      key="$1"; shift
      bg_status_set "$key" "$*"
    elif [ "$#" -eq 1 ]; then
      bg_status_set "default" "$1"
    else
      echo "usage: bg-status.sh set [<key>] <message>" >&2
      exit 1
    fi
    ;;
  clear)
    shift
    bg_status_clear "${1:-}"
    ;;
  *)
    echo "usage: bg-status.sh {set [<key>] <message>|clear [<key>]}" >&2
    exit 1
    ;;
esac

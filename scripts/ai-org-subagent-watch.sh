#!/bin/bash
# ai-org-subagent-watch — 動作中の subagent を ai-org-progress 経由で可視化
#
# 仕組み:
#   - /Users/bellspan/.claude/projects/.../subagents/agent-<id>.jsonl のサイズ・mtime を監視
#   - mtime が < 60s 以内なら "🟢 active"、それ以上なら "⚠️ stuck?"
#   - 進捗 % は subagent 自身が ai-org-progress write を呼ばない限り不明 (size 増分で代替推定)
#
# 用途:
#   ai-org-subagent-watch                  全 active subagent を ai-org-progress に同期 (1 回)
#   ai-org-subagent-watch loop             10 秒間隔で同期し続ける (Ctrl+C で停止)
#   ai-org-subagent-watch register <id> <label>  特定 subagent を登録

set -uo pipefail

# Issue #645: SUBAGENT_DIR の解決バグ修正。
# 旧実装はハードコードパス (存在しない固定 UUID) + `find ... | head -1` で
# 無関係プロジェクトの subagents dir を誤選択し、現プロジェクトの liveness 照合が
# 完全に非機能だった。
# → 最も最近 agent-*.jsonl が更新された subagents dir (= active session) を選ぶ。
#   AI_ORG_SUBAGENT_DIR_OVERRIDE で明示指定可 (テスト/特殊用途)。
SUBAGENT_DIR="${AI_ORG_SUBAGENT_DIR_OVERRIDE:-}"
if [ -z "$SUBAGENT_DIR" ] || [ ! -d "$SUBAGENT_DIR" ]; then
  # 全プロジェクトの最新 agent-*.jsonl を mtime 降順で探し、その親 (subagents dir) を採る
  _latest_agent=$(find "$HOME/.claude/projects" -maxdepth 4 -type f -name 'agent-*.jsonl' \
    -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [ -n "$_latest_agent" ]; then
    SUBAGENT_DIR=$(dirname "$_latest_agent")
  else
    # fallback: 従来どおり最初に見つかった subagents dir
    SUBAGENT_DIR=$(find "$HOME/.claude/projects" -maxdepth 3 -type d -name subagents 2>/dev/null | head -1)
  fi
fi
PROGRESS_DIR=/tmp/ai-org-progress
mkdir -p "$PROGRESS_DIR"

# subagent jsonl の最初のエントリから「役割名」or 先頭文章を抽出
extract_subagent_role() {
  local f=$1
  local content
  content=$(head -1 "$f" 2>/dev/null | jq -r '.message.content // ""' 2>/dev/null | head -c 500)
  if [ -z "$content" ]; then echo ""; return; fi
  local role
  role=$(printf '%s' "$content" | grep -oE '"[^"]{4,80}"' | head -1 | tr -d '"')
  if [ -n "$role" ]; then
    echo "$role"
  else
    printf '%s' "$content" | head -c 60 | tr '\n' ' '
  fi
}

# subagent jsonl の **最新の tool_use** を抽出 (今何してるか、macOS 互換: tail -r)
extract_subagent_current_action() {
  local f=$1
  local action
  # jsonl の末尾から tool_use を探す (tail -r で行を逆順、macOS で tac の代替)
  action=$(tail -r "$f" 2>/dev/null | grep -m 5 -E '"type":"tool_use"' | head -1 \
    | jq -r 'try (.message.content[]? | select(.type=="tool_use") | "\(.name): \((.input.command // .input.file_path // .input.description // "?") | tostring | .[0:60])") // ""' 2>/dev/null \
    | head -1 | tr '\n' ' ')
  if [ -n "$action" ] && [ "$action" != "null" ] && [ "$action" != " " ]; then
    echo "${action:0:80}"
  else
    echo ""
  fi
}

extract_subagent_label() {
  local f=$1
  local current_action
  current_action=$(extract_subagent_current_action "$f")
  if [ -n "$current_action" ]; then
    # 現在 action のみ (役割名は initial pin で確認可、リアルタイムは「今何してるか」優先)
    echo "$current_action"
  else
    # action なし (subagent 開始直後 or jq 失敗) は役割名にフォールバック
    extract_subagent_role "$f"
  fi
}

# 完了 subagent の最終 assistant message から「結果」を抽出 (オーナー指示 2026-05-05)
extract_subagent_completion_result() {
  local f=$1
  # 最終エントリ周辺の assistant message を取得 (tail -r で逆順、最初の非 user を採る)
  local result
  result=$(tail -r "$f" 2>/dev/null | grep -m 5 '"role":"assistant"' | head -1 \
    | jq -r 'try (.message.content[]? | select(.type=="text") | .text) // ""' 2>/dev/null \
    | head -c 200 | tr '\n' ' ')
  echo "${result:0:80}"
}

# 起動中 root pin (parent なし、3 分以内 active のもの) を取得
#
# Issue #73 対応:
#   1. 除外接頭辞拡張: `sa:` のみ → `sa:` / `cdx-pr*` / `xcb` の subagent・子プロセス系を全除外
#   2. 非決定性解消: 「最初に見つかった active root」ではなく「最新 updated を持つ root」を返す
#      (tie-break は id 辞書順で安定化)
#   `local progress_dir=${1:-/tmp/ai-org-progress}` でテスト時に差し替え可能
find_active_root_pin() {
  local progress_dir=${1:-/tmp/ai-org-progress}
  local now
  now=$(date +%s)
  local best_id=""
  local best_updated=0
  local id parent updated age
  for j in "$progress_dir"/*.json ; do
    [ -f "$j" ] || continue
    id=$(basename "$j" .json)
    parent=$(jq -r '.parent // empty' "$j" 2>/dev/null)
    updated=$(jq -r '.updated // 0' "$j" 2>/dev/null)
    age=$(( now - updated ))
    # parent あり → root 候補から除外
    [ -n "$parent" ] && continue
    # 180 秒以内 active のみ
    [ "$age" -ge 180 ] && continue
    # subagent / 子プロセス系 prefix は root から除外
    case "$id" in
      sa:*|cdx-pr*|xcb) continue ;;
    esac
    # 最新 updated を優先。tie の場合は id 辞書順で最小 (= 安定)
    if [ -z "$best_id" ]; then
      best_updated="$updated"
      best_id="$id"
    elif [ "$updated" -gt "$best_updated" ]; then
      best_updated="$updated"
      best_id="$id"
    elif [ "$updated" -eq "$best_updated" ] && [ "$(printf '%s\n%s\n' "$id" "$best_id" | LC_ALL=C sort | head -1)" = "$id" ] && [ "$id" != "$best_id" ]; then
      best_id="$id"
    fi
  done
  if [ -n "$best_id" ]; then
    echo "$best_id"
  fi
  return 0
}

# 動作中の background プロセス (codex exec / xcodebuild) を auto-pin (オーナー指摘 2026-05-05)
sync_bg_processes() {
  local active_root=$1
  # codex exec (PR review 並列実行) を検出
  ps -ef | grep "codex exec --skip-git-repo-check" | grep -v grep | while read line ; do
    # output-last-message path or prompt path から PR 番号を抽出
    # 想定パターン: /tmp/codex_out_582.txt / /var/folders/.../codex_pr582_out.../...
    local pr_num
    pr_num=$(echo "$line" | grep -oE 'codex_(pr|out_)[0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -z "$pr_num" ] && continue
    local pin_id="cdx-pr${pr_num}"
    # 既存 pin の parent 保持
    local pin_file="/tmp/ai-org-progress/${pin_id}.json"
    local existing_parent=""
    [ -f "$pin_file" ] && existing_parent=$(jq -r '.parent // empty' "$pin_file" 2>/dev/null)
    local parent_arg=""
    if [ -n "$existing_parent" ]; then parent_arg="$existing_parent"
    elif [ -n "$active_root" ]; then parent_arg="$active_root"
    fi
    ai-org-progress write "$pin_id" 1 1 "Codex review 実行中 (PR #${pr_num}, medium)" $parent_arg 2>/dev/null
  done

  # xcodebuild test を検出
  ps -ef | grep "xcodebuild" | grep -v grep | grep -v "Xcode.app" | while read line ; do
    local scheme
    scheme=$(echo "$line" | grep -oE '\-scheme [A-Za-z0-9_-]+' | awk '{print $2}' | head -1)
    [ -z "$scheme" ] && scheme="(unknown)"
    local pin_id="xcb"
    local pin_file="/tmp/ai-org-progress/${pin_id}.json"
    local existing_parent=""
    [ -f "$pin_file" ] && existing_parent=$(jq -r '.parent // empty' "$pin_file" 2>/dev/null)
    local parent_arg=""
    if [ -n "$existing_parent" ]; then parent_arg="$existing_parent"
    elif [ -n "$active_root" ]; then parent_arg="$active_root"
    fi
    ai-org-progress write "$pin_id" 1 1 "xcodebuild test ($scheme)" $parent_arg 2>/dev/null
  done

  # 終了済 codex/xcb pin の auto clear
  for pin_file in /tmp/ai-org-progress/cdx-pr*.json /tmp/ai-org-progress/xcb.json ; do
    [ -f "$pin_file" ] || continue
    local pin_id
    pin_id=$(basename "$pin_file" .json)
    case "$pin_id" in
      cdx-pr*)
        local pr_num="${pin_id#cdx-pr}"
        # codex_pr<N>_ or codex_out_<N>. のいずれかが残ってれば動作中
        if ! ps -ef | grep -E "codex_(pr|out_)${pr_num}([_.])" | grep -v grep > /dev/null ; then
          ai-org-progress clear "$pin_id" 2>/dev/null
        fi
        ;;
      xcb)
        if ! ps -ef | grep "xcodebuild" | grep -v "Xcode.app" | grep -v grep > /dev/null ; then
          ai-org-progress clear "$pin_id" 2>/dev/null
        fi
        ;;
    esac
  done
}

sync_once() {
  if [ ! -d "$SUBAGENT_DIR" ]; then echo "subagent dir not found"; return; fi
  # Issue #645: launchd 10s 周期で死んだ / 孤児化した pin を自動 reap し
  # "⚠️ stuck?" の残骸が溜まり続けるのを防ぐ。
  ai-org-progress reap >/dev/null 2>&1 || true
  active_root=$(find_active_root_pin)
  # 子プロセス (codex / xcodebuild) auto-pin
  sync_bg_processes "$active_root"
  for f in "$SUBAGENT_DIR"/agent-*.jsonl ; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .jsonl | sed 's/^agent-//')
    short_id="sa:${id:0:10}"
    mtime=$(stat -f %m "$f" 2>/dev/null)
    age=$(( $(date +%s) - mtime ))
    pin_file="/tmp/ai-org-progress/${short_id}.json"

    # 状態 3 段階:
    # 1. active (60s 以内更新): 「今何してるか」label
    # 2. completed (60-600s): 結果 sticky 表示 (✅ <result>)
    # 3. expired (600s 以上): auto clear

    if [ "$age" -ge 600 ] && [ -f "$pin_file" ]; then
      ai-org-progress clear "$short_id" 2>/dev/null
      continue
    fi

    lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    existing_parent=""
    [ -f "$pin_file" ] && existing_parent=$(jq -r '.parent // empty' "$pin_file" 2>/dev/null)

    if [ "$age" -lt 60 ]; then
      # active 中: 「今何してるか」
      desc=$(extract_subagent_label "$f")
      [ -z "$desc" ] && desc="(active)"
    elif [ "$age" -lt 600 ] && [ -f "$pin_file" ]; then
      # completed: 結果サマリで上書き (60-600s sticky)
      result=$(extract_subagent_completion_result "$f")
      if [ -n "$result" ]; then
        desc="✅ $result"
      else
        # 結果取れなければ「役割: 完了 (Xs 経過)」
        role=$(extract_subagent_role "$f")
        desc="✅ ${role:0:30} (${age}s 経過)"
      fi
    else
      continue  # 新規発見だが既に古い → skip
    fi

    if [ -n "$existing_parent" ]; then
      ai-org-progress write "$short_id" "$lines" "$lines" "$desc" "$existing_parent" 2>/dev/null
    elif [ -n "$active_root" ]; then
      ai-org-progress write "$short_id" "$lines" "$lines" "$desc" "$active_root" 2>/dev/null
    else
      ai-org-progress write "$short_id" "$lines" "$lines" "$desc" 2>/dev/null
    fi
  done
}

cmd=${1:-once}
case "$cmd" in
  once|"")
    sync_once
    ai-org-progress show
    ;;
  loop)
    echo "Watching subagents (Ctrl+C to stop)..."
    while true; do
      sync_once
      sleep 10
    done
    ;;
  register)
    id=$2; label=${3:-}
    short_id="sa:${id:0:10}"
    f="$SUBAGENT_DIR/agent-${id}.jsonl"
    if [ -f "$f" ]; then
      lines=$(wc -l < "$f" | tr -d ' ')
      ai-org-progress write "$short_id" "$lines" "$lines" "$label"
      echo "registered $short_id"
    else
      echo "subagent file not found: $f" >&2
      exit 1
    fi
    ;;
  --help|-h)
    sed -n '2,15p' "$0"
    ;;
  *)
    echo "Unknown: $cmd" >&2; exit 2
    ;;
esac

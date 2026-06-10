#!/bin/bash
# ai-org-progress — background ジョブと subagent の進捗を可視化する
#
# オーナー指示 (2026-05-05): 「進捗がわかるプログレスバーや % って作れる？
# 動いているのかスタックしているのかわからない」
#
# オーナー指示 (2026-05-06): 「完了して 10 分経過したタスクは表示から外して。
# 毎回言うの疲れる」
# → show / --short で 100% complete (current >= total) かつ updated から
#   COMPLETED_HIDE_SEC (default 600s) 超のものを自動非表示。
#   `show --include-completed` または env INCLUDE_COMPLETED=1 で表示可 (debug)。
#
# 用途:
#   ai-org-progress                           全 jobs を表示 (table)
#   ai-org-progress --short                   status line 用サマリ（job ごと改行・root+直下child を各1行）
#   ai-org-progress show --include-completed  完了 10 分超も含めて表示 (debug)
#   ai-org-progress write <id> <cur> <total> <label>  進捗書き込み
#   ai-org-progress complete <id>             完了マーク + 親 +1 連動 (idempotent)
#   ai-org-progress clear <id>                進捗ファイル削除 (job 完了時)
#   ai-org-progress set-parent <id> <parent>  既存 job に親後付け
#
# 進捗ファイル: /tmp/ai-org-progress/<id>.json
# 形式: {"current":3, "total":12, "label":"PR #543", "updated":<unix秒>, "started":<unix秒>, "parent"?:<id>}

set -uo pipefail

# PROGRESS_DIR: 進捗ファイルを置く dir。
# テスト容易性のため AI_ORG_PROGRESS_DIR_OVERRIDE で上書き可。
# (Issue #78 — bats から隔離 dir で実行できるようにするため)
PROGRESS_DIR="${AI_ORG_PROGRESS_DIR_OVERRIDE:-/tmp/ai-org-progress}"
mkdir -p "$PROGRESS_DIR"
# 700 で他ユーザーを排除 (Codex PR #42 HIGH-1 指摘対応)
chmod 700 "$PROGRESS_DIR" 2>/dev/null

# 完了 pin の自動非表示閾値 (秒)。オーナー指示 2026-05-06 で 10 分。
# 環境変数 AI_ORG_PROGRESS_COMPLETED_HIDE_SEC で上書き可 (非負整数のみ)。
# Codex PR #137 HIGH-1 指摘: 数値以外なら default 600 に fallback (stderr warn)
COMPLETED_HIDE_SEC=${AI_ORG_PROGRESS_COMPLETED_HIDE_SEC:-600}
if [[ ! "$COMPLETED_HIDE_SEC" =~ ^[0-9]+$ ]]; then
  echo "Warning: AI_ORG_PROGRESS_COMPLETED_HIDE_SEC='$COMPLETED_HIDE_SEC' is not a non-negative integer, using default 600" >&2
  COMPLETED_HIDE_SEC=600
fi

# Issue #77: --short 用の sticky 閾値 (秒)。default 60s。
# completed pin (current==total) は complete 直後 60 秒は --short に sticky 表示し、
# 60 秒経過後は --short から自動非表示。show では COMPLETED_HIDE_SEC まで残る。
# オーナー指示 (UX HIGH 2): 「完了 pin が status line に粘着して邪魔」を構造的に解消
SHORT_STICKY_SEC=${AI_ORG_PROGRESS_SHORT_STICKY_SEC:-60}
if [[ ! "$SHORT_STICKY_SEC" =~ ^[0-9]+$ ]]; then
  echo "Warning: AI_ORG_PROGRESS_SHORT_STICKY_SEC='$SHORT_STICKY_SEC' is not a non-negative integer, using default 60" >&2
  SHORT_STICKY_SEC=60
fi

# Issue #489: completed=false でも STALE_HIDE_SEC 超の更新なしは非表示。
# 環境変数 AI_ORG_PROGRESS_STALE_HIDE_SEC で上書き可 (非負整数のみ)。
STALE_HIDE_SEC=${AI_ORG_PROGRESS_STALE_HIDE_SEC:-86400}
if [[ ! "$STALE_HIDE_SEC" =~ ^[0-9]+$ ]]; then
  echo "Warning: AI_ORG_PROGRESS_STALE_HIDE_SEC='$STALE_HIDE_SEC' is not a non-negative integer, using default 86400" >&2
  STALE_HIDE_SEC=86400
fi

# Issue #645: liveness-aware healthcheck。
# 従来 stuck_marker は updated の鮮度だけで stuck 判定し、タスクの実死活を見ていなかった。
# → pin に anchor (pid / agent_file) を持たせ、死活を判定する。
#
# ORPHAN_HIDE_SEC: anchor を持たない completed=false pin がこの秒数を超えて未更新なら
#   「complete/clear を呼び忘れた孤児」とみなして非表示 + reap 対象にする (default 1800s=30分)。
#   旧 STALE_HIDE_SEC(24h) は長すぎて死んだ pin が半日 "stuck?" 表示で残る原因だった。
ORPHAN_HIDE_SEC=${AI_ORG_PROGRESS_ORPHAN_HIDE_SEC:-1800}
if [[ ! "$ORPHAN_HIDE_SEC" =~ ^[0-9]+$ ]]; then
  echo "Warning: AI_ORG_PROGRESS_ORPHAN_HIDE_SEC='$ORPHAN_HIDE_SEC' is not a non-negative integer, using default 1800" >&2
  ORPHAN_HIDE_SEC=1800
fi

# LIVENESS_FRESH_SEC: agent_file (subagent jsonl) の mtime がこの秒数以内なら subagent 生存とみなす。
LIVENESS_FRESH_SEC=${AI_ORG_PROGRESS_LIVENESS_FRESH_SEC:-120}
if [[ ! "$LIVENESS_FRESH_SEC" =~ ^[0-9]+$ ]]; then
  echo "Warning: AI_ORG_PROGRESS_LIVENESS_FRESH_SEC='$LIVENESS_FRESH_SEC' is not a non-negative integer, using default 120" >&2
  LIVENESS_FRESH_SEC=120
fi

# Issue #77 — atomic write helper: jq の戻り値と tmp file のサイズを検証してから mv。
# jq 失敗 (壊れた JSON 等) で 0 byte tmp が atomic mv され既存ファイルを破壊する事故
# (Codex PR #57 MEDIUM 指摘) を防ぐ。
# usage: safe_atomic_write <tmpfile> <target_file> <jq_exit_status>
# 戻り値: 0 = success (mv 完了), 1 = abort (tmpfile 削除、target は温存)
safe_atomic_write() {
  local tmpfile=$1 target=$2 jq_status=$3
  if [[ "$jq_status" -ne 0 ]] || [[ ! -s "$tmpfile" ]]; then
    echo "Warning: jq failed (status=$jq_status) or produced empty output, preserving existing $target" >&2
    rm -f "$tmpfile"
    return 1
  fi
  mv "$tmpfile" "$target"
  return 0
}

# id 検証: 英数字 + . _ : - のみ許可 (path traversal / symlink 攻撃防止)
# Codex 指摘対応: ../etc/passwd 等の id を拒否
validate_id() {
  local id=$1
  if [[ -z "$id" ]]; then
    echo "Error: id is empty" >&2
    exit 2
  fi
  if [[ ! "$id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "Error: invalid id '$id' — only [A-Za-z0-9._:-] allowed" >&2
    exit 2
  fi
  # / が含まれていないことを念のため再確認
  if [[ "$id" == *"/"* ]]; then
    echo "Error: id must not contain '/'" >&2
    exit 2
  fi
}

# ------ ヘルパ ------

draw_bar() {
  local cur=$1 total=$2 width=${3:-12}
  if [[ "$total" -le 0 ]]; then echo "${cur}/?"; return; fi
  local pct filled empty
  pct=$(( cur * 100 / total ))
  filled=$(( cur * width / total ))
  empty=$(( width - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done
  printf "%s %d%%" "$bar" "$pct"
}

now_ts() { date +%s; }

age_str() {
  local ts=$1
  local n age
  n=$(now_ts)
  age=$(( n - ts ))
  if [[ $age -lt 60 ]]; then echo "${age}s"
  elif [[ $age -lt 3600 ]]; then echo "$((age/60))m$((age%60))s"
  else echo "$((age/3600))h$(( (age%3600)/60 ))m"
  fi
}

stuck_marker() {
  local updated=$1 stuck_threshold=${2:-90}  # 90秒以上更新なし = stuck
  local age
  age=$(( $(now_ts) - updated ))
  if [[ $age -gt $stuck_threshold ]]; then echo "⚠️ stuck?"; else echo "🟢 active"; fi
}

# Issue #645: pin の anchor (pid / agent_file) からタスクの死活を判定する。
# echo: "alive" | "dead" | "unknown"
#   - pid あり        : kill -0 で生死を確定判定 (definitive)
#   - agent_file あり : ファイル存在 + mtime が LIVENESS_FRESH_SEC 以内なら alive、
#                       消滅 or mtime 古ければ dead
#   - どちらもなし    : unknown (呼び出し側が updated 鮮度で従来判定)
pin_liveness() {
  local f=$1
  [[ -f "$f" ]] || { echo unknown; return; }
  local pid agent_file
  pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
  agent_file=$(jq -r '.agent_file // empty' "$f" 2>/dev/null)
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
    if kill -0 "$pid" 2>/dev/null; then echo alive; else echo dead; fi
    return
  fi
  if [[ -n "$agent_file" ]]; then
    if [[ -f "$agent_file" ]]; then
      local mt age
      mt=$(stat -f %m "$agent_file" 2>/dev/null || stat -c %Y "$agent_file" 2>/dev/null)
      if [[ -z "$mt" || ! "$mt" =~ ^[0-9]+$ ]]; then echo unknown; return; fi
      age=$(( $(now_ts) - mt ))
      if [[ $age -lt $LIVENESS_FRESH_SEC ]]; then echo alive; else echo dead; fi
    else
      echo dead
    fi
    return
  fi
  echo unknown
}

# Issue #645: 表示用ステータスマーカー。completed / liveness / 更新鮮度を総合判定。
# 従来 stuck_marker(updated) を置き換え、(1) completed pin を stuck と誤表示しない
# (2) anchor が生きている長時間タスクを stuck 判定しない、を保証する。
status_marker() {
  local f=$1
  [[ -f "$f" ]] || { echo "🟢 active"; return; }
  local updated completed cur total
  updated=$(jq -r '(.updated | tonumber?) // 0' "$f" 2>/dev/null); updated=${updated%.*}
  completed=$(jq -r '.completed // false' "$f" 2>/dev/null)
  cur=$(jq -r '(.current | tonumber?) // 0' "$f" 2>/dev/null); cur=${cur%.*}
  total=$(jq -r '(.total | tonumber?) // 0' "$f" 2>/dev/null); total=${total%.*}
  [[ -z "$updated" ]] && updated=0
  # 完了 (明示 completed=true、または 100%) は stuck 表示しない
  if [[ "$completed" == "true" ]] || { [[ "$total" -gt 0 ]] && [[ "$cur" -ge "$total" ]]; }; then
    echo "✅ done"; return
  fi
  local live; live=$(pin_liveness "$f")
  case "$live" in
    alive) echo "🟢 running"; return ;;
    dead)  echo "❌ ended";   return ;;
  esac
  # unknown (anchorless): 更新鮮度で従来判定
  local age=$(( $(now_ts) - updated ))
  if [[ $age -gt 90 ]]; then echo "⚠️ stuck?"; else echo "🟢 active"; fi
}

# 完了 pin の表示スキップ判定 (mode 別 threshold)
# 戻り値: 0 = hide (skip), 1 = show
# 引数: $1 = json file path, $2 = mode ("show" | "short")
#   - show:  COMPLETED_HIDE_SEC (default 600s) 超で hide (オーナー指示 2026-05-06)
#   - short: SHORT_STICKY_SEC (default 60s) 超で hide (Issue #77 — completed pin 粘着解消)
# 環境変数 INCLUDE_COMPLETED=1 で常に show (debug 用)
# Codex PR #137 MEDIUM-1 指摘: jq tonumber? // 0 で型安全 (壊れた JSON / 文字列耐性)
should_hide_completed() {
  local f=$1
  local mode=${2:-show}
  if [[ "${INCLUDE_COMPLETED:-0}" == "1" ]]; then return 1; fi
  [[ ! -f "$f" ]] && return 1
  local cur total updated
  cur=$(jq -r '(.current | tonumber?) // 0' "$f" 2>/dev/null)
  total=$(jq -r '(.total | tonumber?) // 0' "$f" 2>/dev/null)
  updated=$(jq -r '(.updated | tonumber?) // 0' "$f" 2>/dev/null)
  # jq 失敗時 (壊れた JSON 等) は空文字 → 0 fallback
  [[ -z "$cur" ]] && cur=0
  [[ -z "$total" ]] && total=0
  [[ -z "$updated" ]] && updated=0
  # 整数化 (小数を切り捨て)
  cur=${cur%.*}; total=${total%.*}; updated=${updated%.*}
  # total <= 0 (未確定 progress) は hide 対象外
  [[ "$total" -le 0 ]] && return 1
  # 100% complete (current >= total) 判定
  [[ "$cur" -lt "$total" ]] && return 1
  local age threshold
  age=$(( $(now_ts) - updated ))
  threshold=$COMPLETED_HIDE_SEC
  if [[ "$mode" == "short" ]]; then
    threshold=$SHORT_STICKY_SEC
  fi
  # 厳密境界: -ge で threshold ちょうども hide
  if [[ $age -ge $threshold ]]; then
    return 0  # hide
  fi
  return 1  # show (completed)
}

# Issue #489: completed=false でも STALE_HIDE_SEC 超の更新なしは非表示。
# 戻り値: 0 = hide (stale), 1 = show
# INCLUDE_COMPLETED=1 で強制 show (debug 用)
should_hide_stale() {
  local f=$1
  if [[ "${INCLUDE_COMPLETED:-0}" == "1" ]]; then return 1; fi
  [[ ! -f "$f" ]] && return 1
  local completed updated age
  completed=$(jq -r '.completed // false' "$f" 2>/dev/null)
  [[ "$completed" == "true" ]] && return 1  # completed=true は should_hide_completed が担当
  # Issue #645: liveness を考慮。
  local live; live=$(pin_liveness "$f")
  # anchor が生存 → 長時間でも表示維持 (オーナー方針: 生きてる長タスクはそのまま)
  [[ "$live" == "alive" ]] && return 1
  # anchor が死亡確定 → 即非表示
  [[ "$live" == "dead" ]] && return 0
  # anchorless (unknown): ORPHAN_HIDE_SEC 超は孤児とみなして非表示。
  # 旧 STALE_HIDE_SEC(24h) は長すぎたため ORPHAN_HIDE_SEC(default 30分) に短縮。
  updated=$(jq -r '(.updated | tonumber?) // 0' "$f" 2>/dev/null)
  [[ -z "$updated" || ! "$updated" =~ ^[0-9]+$ ]] && updated=0
  age=$(( $(now_ts) - updated ))
  if [[ $age -ge $ORPHAN_HIDE_SEC ]]; then
    return 0  # hide (orphan)
  fi
  return 1  # show
}

# ------ 循環参照検出 (Issue #72) ------
# check_circular <id> <proposed_parent>
# 「proposed_parent から 5 段祖先を辿って id に到達したら循環」を検出。
# 到達した場合: stderr にエラーを出力して exit 2。
# 到達しない場合: 正常終了 (return 0)。
# 引数:
#   $1 = id        : 親を設定しようとしている job の id
#   $2 = parent_id : 設定しようとしている parent の id
check_circular() {
  local id=$1 parent_id=$2
  # 自己参照チェック
  if [[ "$id" == "$parent_id" ]]; then
    echo "Error: circular reference detected — '$id' cannot be its own parent" >&2
    exit 2
  fi
  # 5 段祖先を辿って id に到達するか確認
  local cur_anc="$parent_id"
  local depth=0
  while [[ $depth -lt 5 && -n "$cur_anc" ]]; do
    local anc_file="$PROGRESS_DIR/${cur_anc}.json"
    [[ ! -f "$anc_file" ]] && break
    local anc_parent
    anc_parent=$(jq -r '.parent // empty' "$anc_file" 2>/dev/null)
    [[ -z "$anc_parent" ]] && break
    if [[ "$anc_parent" == "$id" ]]; then
      echo "Error: circular reference detected — setting '$id' parent to '$parent_id' would create a cycle" >&2
      exit 2
    fi
    cur_anc="$anc_parent"
    depth=$((depth + 1))
  done
  return 0
}

# ------ 再帰的集約ヘルパ (Issue #72) ------
# sum_descendants <rid> <all_ids_varname>
# rid の全子孫 (直接・間接) の cur と total を再帰的に sum して出力。
# "cur total has_child" 形式で echo する。
# all_ids_varname は "all_ids" または "all_ids_full" を指定 (nameref 相当を bash で実現)。
# sa: prefix の id は集約から除外する。
#
# 実装: bash は再帰関数をサポートするが、nameref (declare -n) は bash 4.3+ のため、
# macOS (bash 3.2) 互換にするためグローバル変数 _SUM_CUR, _SUM_TOTAL, _HAS_CHILD を使う。
_SUM_CUR=0
_SUM_TOTAL=0
_HAS_CHILD=0

_accum_descendants() {
  local rid=$1
  local ids_str=$2
  local depth=${3:-0}
  if (( depth >= 10 )); then
    printf "[WARN] _accum_descendants: MAX_DEPTH exceeded for %s
" "$rid" >&2
    return
  fi
  for cid in $ids_str ; do
    [[ "$cid" == sa:* ]] && continue
    local cf="$PROGRESS_DIR/${cid}.json"
    [[ ! -f "$cf" ]] && continue
    local cp
    cp=$(jq -r ".parent // empty" "$cf" 2>/dev/null)
    [[ "$cp" != "$rid" ]] && continue
    local c t
    c=$(jq -r ".current // 0" "$cf")
    t=$(jq -r ".total // 0" "$cf")
    _SUM_CUR=$((_SUM_CUR + c))
    _SUM_TOTAL=$((_SUM_TOTAL + t))
    _HAS_CHILD=1
    _accum_descendants "$cid" "$ids_str" $(( depth + 1 ))
  done
}

aggregate_root_for() {
  local rid=$1
  local ids_str=$2
  _SUM_CUR=0
  _SUM_TOTAL=0
  _HAS_CHILD=0
  _accum_descendants "$rid" "$ids_str"
  if [[ $_HAS_CHILD -eq 1 ]]; then
    echo "$_SUM_CUR $_SUM_TOTAL"
  else
    echo ""
  fi
}

# ------ サブコマンド ------

cmd=${1:-show}
case "$cmd" in
  write)
    # Issue #645: liveness anchor flag (--pid / --agent-file) を positional 引数と
    # 混在で受け付ける。flag を抽出してから残りを従来の positional として解釈する。
    shift  # drop 'write'
    pid=""; agent_file=""
    pos=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pid)        pid=${2:-};        shift 2 || { echo "Error: --pid requires a value" >&2; exit 2; } ;;
        --agent-file) agent_file=${2:-}; shift 2 || { echo "Error: --agent-file requires a value" >&2; exit 2; } ;;
        *) pos+=("$1"); shift ;;
      esac
    done
    id=${pos[0]:-}; cur=${pos[1]:-}; total=${pos[2]:-}; label=${pos[3]:-}; parent=${pos[4]:-}
    # Issue #78: label の改行は --short の 1 行契約を破壊するため、入力時点で
    # 空白に正規化する。tab / CR も同様に正規化 (status line 表示崩れ防止)。
    label=$(printf '%s' "$label" | tr '\n\r\t' '   ')
    validate_id "$id"
    [[ -n "$parent" ]] && validate_id "$parent"
    # Issue #258: cur / total の入力バリデーション。非負整数以外は exit 2。
    [[ "$cur" =~ ^[0-9]+$ ]] || { echo "Error: cur must be non-negative integer, got '$cur'" >&2; exit 2; }
    [[ "$total" =~ ^[0-9]+$ ]] || { echo "Error: total must be non-negative integer, got '$total'" >&2; exit 2; }
    # Issue #645: pid は非負整数のみ (kill -0 に渡すため)
    [[ -n "$pid" && ! "$pid" =~ ^[0-9]+$ ]] && { echo "Error: --pid must be non-negative integer, got '$pid'" >&2; exit 2; }
    file="$PROGRESS_DIR/${id}.json"
    started=$(now_ts)
    existing_parent=""
    existing_pid=""; existing_agent_file=""
    if [[ -f "$file" ]]; then
      started=$(jq -r '.started // empty' "$file" 2>/dev/null)
      [[ -z "$started" ]] && started=$(now_ts)
      # 既存の parent を保持 (write 時に再指定なしなら)
      existing_parent=$(jq -r '.parent // empty' "$file" 2>/dev/null)
      # Issue #645: 既存 anchor を保持 (flag 省略時)
      existing_pid=$(jq -r '.pid // empty' "$file" 2>/dev/null)
      existing_agent_file=$(jq -r '.agent_file // empty' "$file" 2>/dev/null)
    fi
    [[ -z "$parent" && -n "$existing_parent" ]] && parent="$existing_parent"
    [[ -z "$pid" && -n "$existing_pid" ]] && pid="$existing_pid"
    [[ -z "$agent_file" && -n "$existing_agent_file" ]] && agent_file="$existing_agent_file"
    # Issue #72: parent 指定時に循環参照を検出 (5 段祖先辿り)
    [[ -n "$parent" ]] && check_circular "$id" "$parent"
    # symlink 攻撃防止 + jq 失敗破壊防止: tmpfile 経由 + safe_atomic_write で検証
    tmpfile=$(mktemp "${PROGRESS_DIR}/.${id}.XXXXXX")
    jq -n --arg label "$label" --arg parent "$parent" \
          --arg pid "$pid" --arg agent_file "$agent_file" \
          --argjson cur "$cur" --argjson total "$total" \
          --argjson updated "$(now_ts)" --argjson started "$started" \
          '{current: $cur, total: $total, label: $label, updated: $updated, started: $started, completed: false}
           + (if $parent == "" then {} else {parent: $parent} end)
           + (if $pid == "" then {} else {pid: ($pid|tonumber)} end)
           + (if $agent_file == "" then {} else {agent_file: $agent_file} end)' \
      > "$tmpfile" 2>/dev/null
    jq_status=$?
    if ! safe_atomic_write "$tmpfile" "$file" "$jq_status"; then
      exit 3
    fi
    ;;

  set-parent)
    # 既存 job に親後付け: ai-org-progress set-parent <id> <parent_id>
    id=$2; parent=$3
    validate_id "$id"; validate_id "$parent"
    file="$PROGRESS_DIR/${id}.json"
    [[ ! -f "$file" ]] && { echo "no such job: $id" >&2 ; exit 2 ; }
    # Issue #72: 循環参照を検出 (5 段祖先辿り)
    check_circular "$id" "$parent"
    tmpfile=$(mktemp "${PROGRESS_DIR}/.${id}.XXXXXX")
    jq --arg parent "$parent" '.parent = $parent' "$file" > "$tmpfile" 2>/dev/null
    jq_status=$?
    # Issue #77: jq 失敗 (壊れた JSON 等) で空 tmp を mv して既存ファイル破壊する事故を防ぐ
    if ! safe_atomic_write "$tmpfile" "$file" "$jq_status"; then
      exit 3
    fi
    ;;

  set-anchor)
    # Issue #645: 既存 pin に liveness anchor (pid / agent_file) を後付けマージする。
    # auto-pin hook が subagent の agentId から jsonl パスを解決して呼ぶ。
    # usage: ai-org-progress set-anchor <id> [--pid <n>] [--agent-file <path>]
    shift  # drop 'set-anchor'
    sa_id=${1:-}; shift || true
    validate_id "$sa_id"
    sa_pid=""; sa_agent_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --pid)        sa_pid=${2:-};        shift 2 || { echo "Error: --pid requires a value" >&2; exit 2; } ;;
        --agent-file) sa_agent_file=${2:-}; shift 2 || { echo "Error: --agent-file requires a value" >&2; exit 2; } ;;
        *) echo "Error: unknown set-anchor option '$1'" >&2; exit 2 ;;
      esac
    done
    [[ -n "$sa_pid" && ! "$sa_pid" =~ ^[0-9]+$ ]] && { echo "Error: --pid must be non-negative integer, got '$sa_pid'" >&2; exit 2; }
    file="$PROGRESS_DIR/${sa_id}.json"
    [[ ! -f "$file" ]] && { echo "no such job: $sa_id" >&2 ; exit 2 ; }
    tmpfile=$(mktemp "${PROGRESS_DIR}/.${sa_id}.XXXXXX")
    jq --arg pid "$sa_pid" --arg agent_file "$sa_agent_file" \
       '. + (if $pid == "" then {} else {pid: ($pid|tonumber)} end)
          + (if $agent_file == "" then {} else {agent_file: $agent_file} end)' \
       "$file" > "$tmpfile" 2>/dev/null
    jq_status=$?
    if ! safe_atomic_write "$tmpfile" "$file" "$jq_status"; then
      exit 3
    fi
    ;;

  cleanup-stale)
    # Issue #489: STALE_HIDE_SEC 超の全 JSON を削除 (trash → rm fallback)
    # usage: ai-org-progress cleanup-stale [HOURS]   (default: 24)
    hours=${2:-24}
    if [[ ! "$hours" =~ ^[0-9]+$ ]]; then
      echo "Error: hours must be non-negative integer, got '$hours'" >&2
      exit 2
    fi
    threshold=$(( hours * 3600 ))
    count=0
    for f in "$PROGRESS_DIR"/*.json; do
      [[ ! -f "$f" ]] && continue
      updated=$(jq -r '.updated // 0' "$f" 2>/dev/null)
      [[ -z "$updated" || ! "$updated" =~ ^[0-9]+$ ]] && updated=0
      age=$(( $(now_ts) - updated ))
      if [[ $age -ge $threshold ]]; then
        id=$(basename "$f" .json)
        if command -v trash >/dev/null 2>&1; then
          trash "$f" 2>/dev/null || rm -f "$f"
        else
          rm -f "$f"
        fi
        count=$((count+1))
        echo "cleaned: $id (${age}s old)" >&2
      fi
    done
    echo "cleanup-stale: removed ${count} job(s) older than ${hours}h"
    ;;

  reap)
    # Issue #645: liveness ベースで死んだ / 孤児化した non-completed pin を clear。
    # subagent-watch (launchd) / statusline から定期実行して "stuck?" の残骸を一掃する。
    #   - anchor (pid/agent_file) が死亡確定 → 即 reap
    #   - anchorless で ORPHAN_HIDE_SEC 超の未更新 → 孤児とみなし reap
    #   - completed=true は reap しない (should_hide_completed の 600s ロジックに委譲)
    #   - anchor が生存中の長時間タスクは温存 (オーナー方針)
    files=("$PROGRESS_DIR"/*.json)
    [[ ! -e "${files[0]}" ]] && { echo "reap: removed 0 dead/orphan pin(s)"; exit 0; }
    reaped=0
    for f in "${files[@]}"; do
      [[ -f "$f" ]] || continue
      completed=$(jq -r '.completed // false' "$f" 2>/dev/null)
      [[ "$completed" == "true" ]] && continue
      live=$(pin_liveness "$f")
      do_reap=0
      if [[ "$live" == "dead" ]]; then
        do_reap=1
      elif [[ "$live" == "unknown" ]]; then
        updated=$(jq -r '(.updated | tonumber?) // 0' "$f" 2>/dev/null); updated=${updated%.*}
        [[ -z "$updated" || ! "$updated" =~ ^[0-9]+$ ]] && updated=0
        age=$(( $(now_ts) - updated ))
        [[ $age -ge $ORPHAN_HIDE_SEC ]] && do_reap=1
      fi
      if [[ $do_reap -eq 1 && ! -L "$f" ]]; then
        rid=$(basename "$f" .json)
        if command -v trash >/dev/null 2>&1; then
          trash "$f" 2>/dev/null || rm -f "$f"
        else
          rm -f "$f"
        fi
        reaped=$((reaped+1))
        echo "reaped: $rid (liveness=$live)" >&2
      fi
    done
    echo "reap: removed ${reaped} dead/orphan pin(s)"
    ;;

  clear)
    id=$2
    validate_id "$id"
    file="$PROGRESS_DIR/${id}.json"
    # 通常ファイル (symlink でない) かつ PROGRESS_DIR 配下であることを再確認してから削除
    # Issue #77 (CTO+2): trash がない環境 (Linux CI / Docker / minimal PATH) で
    # silent fail して進捗ファイルが削除されない事故を防ぐ。trash → rm の順で
    # try する fallback 方式に変更。
    if [[ -f "$file" && ! -L "$file" ]]; then
      if command -v trash >/dev/null 2>&1; then
        trash "$file" 2>/dev/null || rm -f "$file"
      else
        rm -f "$file"
      fi
    fi
    ;;

  complete)
    # 完了マーク + 親の current を +1 連動 (2026-05-05 オーナー指示「連動させれば良い」)
    # subagent / script が「自分のタスク完了」した時に呼ぶ
    # 効果:
    #   1. この pin の current = total (100%) にする
    #   2. parent があれば parent.current を +1 (total 超えない)
    #   3. この pin はファイル残す (履歴保持、別途 clear で削除)
    #
    # Issue #71 (2026-05-06): idempotent 化。同一 id に対する 2 回目以降の
    # complete は親 current を再加算しない。subagent retry / launchd 再起動 /
    # shell 二重実行で発生する暴走を防ぐ。state は JSON 内 `.completed = true`
    # で表現し、再実行時はそれを参照して no-op + warning。
    id=$2
    validate_id "$id"
    file="$PROGRESS_DIR/${id}.json"
    if [[ ! -f "$file" ]]; then
      echo "no such job: $id" >&2
      exit 2
    fi
    # 既に completed なら親 +1 をスキップ (idempotent)
    already_completed=$(jq -r '.completed // false' "$file" 2>/dev/null)
    [[ -z "$already_completed" ]] && already_completed=false

    # この pin を 100% + completed=true に (再書き込みは安全)
    # Issue #77: 壊れた JSON を読んだ時に jq -r '.total // 0' は空文字を返すケースがある。
    # 整数化を強制し、その後 safe_atomic_write で空 tmp 破壊を防ぐ。
    total=$(jq -r '.total // 0' "$file" 2>/dev/null)
    label=$(jq -r '.label // ""' "$file" 2>/dev/null)
    started=$(jq -r '.started // 0' "$file" 2>/dev/null)
    parent=$(jq -r '.parent // empty' "$file" 2>/dev/null)
    # 数値 fallback (jq 失敗 / 壊れた JSON 耐性)
    [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]] && total=0
    [[ -z "$started" || ! "$started" =~ ^[0-9]+$ ]] && started=0
    tmpfile=$(mktemp "${PROGRESS_DIR}/.${id}.XXXXXX")
    jq -n --arg label "$label" --arg parent "$parent" \
          --argjson cur "$total" --argjson total "$total" \
          --argjson updated "$(now_ts)" --argjson started "$started" \
          '{current: $cur, total: $total, label: $label, updated: $updated, started: $started, completed: true} + (if $parent == "" then {} else {parent: $parent} end)' \
      > "$tmpfile" 2>/dev/null
    jq_status=$?
    if ! safe_atomic_write "$tmpfile" "$file" "$jq_status"; then
      exit 3
    fi

    if [[ "$already_completed" == "true" ]]; then
      # idempotent: 親 +1 を再実行しない
      echo "[complete] $id already completed, skipping parent +1" >&2
    elif [[ -n "$parent" ]]; then
      # 親があれば parent.current += 1 (cap to parent.total)
      parent_file="$PROGRESS_DIR/${parent}.json"
      if [[ -f "$parent_file" ]]; then
        pcur=$(jq -r '.current // 0' "$parent_file")
        ptotal=$(jq -r '.total // 0' "$parent_file")
        plabel=$(jq -r '.label // ""' "$parent_file")
        pstarted=$(jq -r '.started // 0' "$parent_file")
        pgrandparent=$(jq -r '.parent // empty' "$parent_file")
        # 親側で既存 completed フラグを保持 (親自身が complete 済なら維持)
        pcompleted=$(jq -r '.completed // false' "$parent_file" 2>/dev/null)
        [[ -z "$pcompleted" ]] && pcompleted=false
        new_cur=$((pcur + 1))
        [[ $new_cur -gt $ptotal ]] && new_cur=$ptotal
        ptmpfile=$(mktemp "${PROGRESS_DIR}/.${parent}.XXXXXX")
        jq -n --arg label "$plabel" --arg parent "$pgrandparent" \
              --argjson cur "$new_cur" --argjson total "$ptotal" \
              --argjson updated "$(now_ts)" --argjson started "$pstarted" \
              --argjson completed "$pcompleted" \
              '{current: $cur, total: $total, label: $label, updated: $updated, started: $started, completed: $completed} + (if $parent == "" then {} else {parent: $parent} end)' \
          > "$ptmpfile" 2>/dev/null
        jq_status=$?
        # Issue #77: parent 更新でも jq 失敗時に親 JSON を破壊しないよう safe_atomic_write
        if safe_atomic_write "$ptmpfile" "$parent_file" "$jq_status"; then
          echo "[complete] $id done → parent $parent: $new_cur/$ptotal" >&2
        fi
        # Issue #300: propagate +1 up all ancestors
        propagate_up() {
         local child_id=$1
         local pdepth=${2:-0}
         if (( pdepth >= 10 )); then
           printf "[WARN] propagate_up: MAX_DEPTH exceeded for %s\n" "$child_id" >&2
           return
         fi
         local anc_id
         anc_id=$(jq -r ".parent // empty" "$PROGRESS_DIR/$child_id.json" 2>/dev/null) || return
         [[ -z "$anc_id" ]] && return
         local anc_file="$PROGRESS_DIR/$anc_id.json"
         [[ -f "$anc_file" ]] || return
         local anc_cur anc_total anc_label anc_started anc_gp anc_completed
         anc_cur=$(jq -r ".current // 0" "$anc_file")
         anc_total=$(jq -r ".total // 0" "$anc_file")
         anc_label=$(jq -r ".label // empty" "$anc_file")
         anc_started=$(jq -r ".started // 0" "$anc_file")
         anc_gp=$(jq -r ".parent // empty" "$anc_file")
         anc_completed=$(jq -r ".completed // false" "$anc_file" 2>/dev/null)
         [[ -z "$anc_completed" ]] && anc_completed=false
         (( anc_total > 0 && anc_cur >= anc_total )) && return
         local anc_new_cur=$(( anc_cur + 1 ))
         [[ $anc_new_cur -gt $anc_total ]] && anc_new_cur=$anc_total
         local anc_tmp
         anc_tmp=$(mktemp "${PROGRESS_DIR}/.${anc_id}.XXXXXX")
         jq -n --arg label "$anc_label" --arg parent "$anc_gp" \
               --argjson cur "$anc_new_cur" --argjson total "$anc_total" \
               --argjson updated "$(now_ts)" --argjson started "$anc_started" \
               --argjson completed "$anc_completed" \
               '{current: $cur, total: $total, label: $label, updated: $updated, started: $started, completed: $completed} + (if $parent == "" then {} else {parent: $parent} end)' \
           > "$anc_tmp" 2>/dev/null
         local anc_jq_status=$?
         if safe_atomic_write "$anc_tmp" "$anc_file" "$anc_jq_status"; then
           echo "[complete] propagate_up -> $anc_id: $anc_new_cur/$anc_total" >&2
         fi
         propagate_up "$anc_id" $(( pdepth + 1 ))
        }
        propagate_up "$parent"
      fi
    fi
    ;;

  --short)
    # status line 用: job ごと改行。表示は root + 直下 child を各1行（2階層）。
    # 孫以降は root に集約され表示行には出ない（行数 = 表示pin数・末尾改行なし）。
    # オプション: --include-completed で完了 10 分超も含めて表示 (debug 用)
    shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --include-completed) export INCLUDE_COMPLETED=1 ;;
        *) echo "Unknown --short option: $1" >&2; exit 2 ;;
      esac
      shift
    done

    files=("$PROGRESS_DIR"/*.json)
    [[ ! -e "${files[0]}" ]] && exit 0  # ジョブなし

    # tree 構造: root → child の順、子は └── でインデント (2026-05-05 オーナー指示)
    # bash 3 互換 (macOS default、連想配列なし)

    all_ids=()
    for f in "${files[@]}" ; do
      [[ ! -f "$f" ]] && continue
      # Issue #77: --short は SHORT_STICKY_SEC (default 60s) で hide。
      # オーナー指示 (UX HIGH 2): 完了 pin が status line に粘着するのを防ぐ。
      should_hide_completed "$f" short && continue
      # Issue #489: completed=false でも STALE_HIDE_SEC 超は非表示
      should_hide_stale "$f" && continue
      all_ids+=("$(basename "$f" .json)")
    done

    # 全 pin が hide 対象なら静かに exit (status line を汚さない)
    [[ ${#all_ids[@]} -eq 0 ]] && exit 0

    get_parent() {
      jq -r '.parent // empty' "$PROGRESS_DIR/$1.json" 2>/dev/null
    }

    # root の集約進捗 (Issue #72: 再帰的に全子孫を sum、subagent sa: 除外)
    # Issue302: aggregate_root removed

    print_short_row() {
      local id=$1 indent=$2
      local f="$PROGRESS_DIR/${id}.json"
      [[ ! -f "$f" ]] && return
      local cur total updated label started
      cur=$(jq -r '.current // 0' "$f")
      total=$(jq -r '.total // 0' "$f")
      updated=$(jq -r '.updated // 0' "$f")
      label=$(jq -r '.label // ""' "$f")
      # row 単位の改行/CR/tab 正規化（防御の自己完結）。
      # write 時にも除去するが、手書き/別プロセス生成 JSON で改行 label が入っても
      # 1 row が複数行に化けないよう、表示直前にも空白化する（行数=表示pin数 を保証）。
      label=${label//$'\n'/ }; label=${label//$'\r'/ }; label=${label//$'\t'/ }
      started=$(jq -r '.started // 0' "$f")
      # root (indent=0) で子があれば集約値で上書き
      if [[ "$indent" -eq 0 ]]; then
        local agg
        agg=$(aggregate_root_for "$id" "${all_ids[*]}")
        if [[ -n "$agg" ]]; then
          cur=$(echo "$agg" | awk '{print $1}')
          total=$(echo "$agg" | awk '{print $2}')
        fi
      fi
      local bar mark elapsed_str last_str short_id label_short prefix
      bar=$(draw_bar "$cur" "$total" 8)
      mark=$(status_marker "$f")
      elapsed_str=$(age_str "$started")
      last_str=$(age_str "$updated")
      short_id="${id:0:18}"
      label_short="${label:0:24}"
      [[ ${#label} -gt 24 ]] && label_short="${label_short}…"
      if [[ "$indent" -eq 0 ]]; then prefix="🔧 "; else prefix="   └── "; fi
      if [[ -n "$label_short" ]]; then
        printf "%s%s 「%s」 %s elapsed=%s last=%s %s" "$prefix" "$short_id" "$label_short" "$bar" "$elapsed_str" "$last_str" "$mark"
      else
        printf "%s%s %s elapsed=%s last=%s %s" "$prefix" "$short_id" "$bar" "$elapsed_str" "$last_str" "$mark"
      fi
    }

    # 2nd pass: root を出力 → 各 root の子を出力
    # オーナー指示 (2026-06-07): bg job ごとに改行して表示する (status line が縦に
    #   伸びても良い)。旧 Issue #78 の「1 行 (改行なし) 契約」を廃止。
    # → 全 row を buffer に集め、改行で連結して複数行出力する。
    #   label 内の改行は write 時 + print_short_row で除去するので 1 row は必ず1行。
    #   出力行数 = 表示pin数（root + 直下 child）で安定。末尾改行は出さない（呼び出し側が連結）。
    SEP=$'\n'
    buf=""
    output_count=0
    for rid in "${all_ids[@]}" ; do
      rp=$(get_parent "$rid")
      [[ -n "$rp" ]] && continue
      if [[ $output_count -gt 0 ]]; then buf+="$SEP"; fi
      buf+=$(print_short_row "$rid" 0)
      output_count=$((output_count+1))
      for cid in "${all_ids[@]}" ; do
        cp=$(get_parent "$cid")
        if [[ "$cp" == "$rid" ]]; then
          buf+="$SEP"
          buf+=$(print_short_row "$cid" 1)
        fi
      done
    done
    # job 間は改行で区切る（オーナー 2026-06-07）。末尾改行は出さない（呼び出し側が連結）。
    # 行頭の余分な改行（最初の SEP）を除去してから出力。
    printf '%s' "${buf#$'\n'}"
    ;;

  show|"")
    # 詳細表示 (table、tree 構造、ELAPSED 列追加)
    # オプション解析: --include-completed で完了 10 分超も表示
    shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --include-completed) export INCLUDE_COMPLETED=1 ;;
        *) echo "Unknown show option: $1" >&2; exit 2 ;;
      esac
      shift
    done

    files=("$PROGRESS_DIR"/*.json)
    [[ ! -e "${files[0]}" ]] && { echo "(no progress files in $PROGRESS_DIR)"; exit 0; }

    all_ids_full=()
    for f in "${files[@]}" ; do
      [[ ! -f "$f" ]] && continue
      # オーナー指示 2026-05-06: 完了 COMPLETED_HIDE_SEC (default 600s) 超は表示外。
      # show は履歴表示性が高いので default mode で 10 分粒度。
      should_hide_completed "$f" show && continue
      # Issue #489: completed=false でも STALE_HIDE_SEC 超は非表示
      should_hide_stale "$f" && continue
      all_ids_full+=("$(basename "$f" .json)")
    done

    if [[ ${#all_ids_full[@]} -eq 0 ]]; then
      echo "(no active progress, all pins completed >${COMPLETED_HIDE_SEC}s ago. use --include-completed to view)"
      exit 0
    fi

    printf "%-22s %-20s %-8s %-10s %-10s %-10s  %s\n" "JOB ID" "PROGRESS" "PCT" "ELAPSED" "LAST UPD" "STATUS" "LABEL"
    printf "%-22s %-20s %-8s %-10s %-10s %-10s\n" "----------------------" "--------------------" "--------" "----------" "----------" "----------"

    get_parent_full() {
      jq -r '.parent // empty' "$PROGRESS_DIR/$1.json" 2>/dev/null
    }

    # root 集約 (Issue #72: 再帰的に全子孫を sum、subagent 除外)
    # Issue302: aggregate_root_full removed

    print_show_row() {
      local id=$1 indent=$2
      local f="$PROGRESS_DIR/${id}.json"
      [[ ! -f "$f" ]] && return
      local cur total label updated started bar pct_only bar_only mark elapsed_str last_str
      cur=$(jq -r '.current // 0' "$f")
      total=$(jq -r '.total // 0' "$f")
      label=$(jq -r '.label // ""' "$f")
      updated=$(jq -r '.updated // 0' "$f")
      started=$(jq -r '.started // 0' "$f")
      if [[ "$indent" -eq 0 ]]; then
        local agg
        agg=$(aggregate_root_for "$id" "${all_ids_full[*]}")
        if [[ -n "$agg" ]]; then
          cur=$(echo "$agg" | awk '{print $1}')
          total=$(echo "$agg" | awk '{print $2}')
        fi
      fi
      bar=$(draw_bar "$cur" "$total" 14)
      pct_only="${bar##* }"
      bar_only="${bar% *}"
      mark=$(status_marker "$f")
      elapsed_str=$(age_str "$started")
      last_str=$(age_str "$updated")
      local prefix=""
      [[ "$indent" -eq 1 ]] && prefix="└── "
      printf "%-22s %-20s %-8s %-10s %-10s %-10s  %s\n" \
        "${prefix}${id:0:22}" "$bar_only ($cur/$total)" "$pct_only" "$elapsed_str" "$last_str" "$mark" "$label"
    }

    for rid in "${all_ids_full[@]}" ; do
      rp=$(get_parent_full "$rid")
      [[ -n "$rp" ]] && continue
      print_show_row "$rid" 0
      for cid in "${all_ids_full[@]}" ; do
        cp=$(get_parent_full "$cid")
        if [[ "$cp" == "$rid" ]]; then
          print_show_row "$cid" 1
        fi
      done
    done
    ;;

  --help|-h)
    sed -n '2,22p' "$0"
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Try: ai-org-progress --help" >&2
    exit 2
    ;;
esac

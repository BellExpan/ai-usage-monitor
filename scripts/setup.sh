#!/bin/bash
# AI Usage Monitor — one-command setup
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="com.aiorg.usage-monitor"
PLIST_SRC="$REPO_DIR/launchd/$PLIST_NAME.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SELFCHECK_PLIST_NAME="com.aiorg.usage-selfcheck"
SELFCHECK_PLIST_SRC="$REPO_DIR/launchd/$SELFCHECK_PLIST_NAME.plist"
SELFCHECK_PLIST_DST="$HOME/Library/LaunchAgents/$SELFCHECK_PLIST_NAME.plist"
SWIFTBAR_PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# shellcheck source=lib/launchd-deploy.sh
source "$REPO_DIR/scripts/lib/launchd-deploy.sh"  # aum_render_plist / aum_deploy / aum_verify_health（#24）

echo "=== AI Usage Monitor セットアップ ==="

# 1. キャッシュ更新スクリプトに実行権限
chmod +x "$REPO_DIR/scripts/cache-update.sh"
chmod +x "$REPO_DIR/scripts/usage-source-selfcheck.sh"
chmod +x "$REPO_DIR/scripts/usage-selfcheck-notify.sh"
chmod +x "$REPO_DIR/swiftbar/ai_usage.5m.sh"
chmod +x "$REPO_DIR/hooks/session-start.sh"
echo "✓ 実行権限付与"

# 2. launchd plist インストール + 健全性 verify（Issue #24: bootout/bootstrap + fail-loud）
#    plist の program は TCC 付与済みの $AUM_PROGRAM（/opt/homebrew/bin/bash）で、外部 repo の
#    cache-update.sh を引数に読む。外部ボリューム上のスクリプトを program として直接 exec すると
#    EX_CONFIG(78) penalty box になり 5分毎更新が停止する事故（#24）を構造的に防ぐ。
# program が実行可能か先に確認（Intel Mac / Homebrew 未導入だと $AUM_PROGRAM 不在で silent 破壊）。
[ -x "$AUM_PROGRAM" ] || {
  echo "✗ launchd program が実行不可: $AUM_PROGRAM（Homebrew bash 未導入 / Intel Mac?）" >&2
  echo "  外部ボリューム(/Volumes)上のスクリプトを読むには TCC 付与済みの bash が必要（#24）" >&2
  exit 1
}
aum_render_plist "$PLIST_SRC" "$REPO_DIR" "$HOME" "$PLIST_DST" || {
  echo "✗ plist render に失敗（$PLIST_SRC → $PLIST_DST）" >&2; exit 1; }
aum_deploy "$PLIST_DST" || {
  echo "✗ launchd deploy(bootstrap) に失敗（$PLIST_DST）" >&2; exit 1; }
# kickstart は非同期のため、初回 run が完走するまで待ってから last exit code を verify する
# （待たずに print すると前回の exit code を見てしまい fail-loud が空振りする・#24 で実証）。
sleep 6
# install 後に健全性を機械検証。penalty box / last exit≠0 なら fail-loud（landed 保証）。
# 特に program が TCC 未付与の /bin/bash 等だと exit 126 になる → ここで確実に検出する。
_health=$(aum_verify_health) || {
  echo "✗ launchd 登録の健全性検証に失敗: $_health（penalty box / 非0 exit）" >&2
  echo "  外部ボリューム上のスクリプトを読める TCC 付与済み bash か、plist を確認してください" >&2
  echo "  launchctl print $(aum_service) / tail /tmp/ai-usage-monitor.err で調査" >&2
  exit 1
}
echo "✓ launchd 登録済み (5分ごと自動更新・health=$_health)"

# 2a. usage-source selfcheck（日次監査 + 通知）
aum_render_plist "$SELFCHECK_PLIST_SRC" "$REPO_DIR" "$HOME" "$SELFCHECK_PLIST_DST" || {
  echo "✗ selfcheck plist render に失敗（$SELFCHECK_PLIST_SRC → $SELFCHECK_PLIST_DST）" >&2; exit 1; }
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$SELFCHECK_PLIST_DST" >/dev/null 2>&1 || {
    echo "✗ selfcheck plist lint に失敗: $SELFCHECK_PLIST_DST" >&2; exit 1; }
fi
/bin/launchctl bootout "gui/$(id -u)/$SELFCHECK_PLIST_NAME" 2>/dev/null || true
/bin/launchctl bootout "gui/$(id -u)" "$SELFCHECK_PLIST_DST" 2>/dev/null || true
/bin/launchctl bootstrap "gui/$(id -u)" "$SELFCHECK_PLIST_DST" || {
  echo "✗ selfcheck launchd deploy に失敗（$SELFCHECK_PLIST_DST）" >&2; exit 1; }
/bin/launchctl kickstart -k "gui/$(id -u)/$SELFCHECK_PLIST_NAME" 2>/dev/null || true
if /bin/launchctl print "gui/$(id -u)/$SELFCHECK_PLIST_NAME" >/dev/null 2>&1; then
  echo "✓ selfcheck launchd 登録済み (1日1回監査)"
else
  echo "✗ selfcheck launchd 登録確認に失敗" >&2
  exit 1
fi

# 2b. 旧監視の孤児 launchd を撤去（Issue #24）
#     com.ai-org.usage-cache は旧版 ai-org 監視の残骸で、現行 status line が読まない
#     legacy ファイル /tmp/.codex_usage_cache に書き込むだけ。診断ノイズ源のため掃除する。
_ORPHAN_PLIST="$HOME/Library/LaunchAgents/com.ai-org.usage-cache.plist"
if launchctl print "gui/$(id -u)/com.ai-org.usage-cache" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)/com.ai-org.usage-cache" 2>/dev/null || true
  echo "✓ 孤児 launchd com.ai-org.usage-cache を撤去"
fi
if [ -f "$_ORPHAN_PLIST" ]; then
  mv -f "$_ORPHAN_PLIST" "$_ORPHAN_PLIST.disabled" 2>/dev/null \
    && echo "✓ 孤児 plist を退避: $_ORPHAN_PLIST.disabled（戻すには .disabled を外して再 bootstrap）"
fi

# 3. SwiftBar プラグイン
if [ -d "$SWIFTBAR_PLUGIN_DIR" ]; then
  ln -sf "$REPO_DIR/swiftbar/ai_usage.5m.sh" \
    "$SWIFTBAR_PLUGIN_DIR/ai_usage.5m.sh"
  echo "✓ SwiftBar プラグイン登録済み"
else
  echo "⚠ SwiftBar 未インストール。brew install --cask swiftbar 後に再実行"
fi

# 4. Claude Code SessionStart hook
if command -v python3 >/dev/null && [ -f "$CLAUDE_SETTINGS" ]; then
  python3 - "$CLAUDE_SETTINGS" "$REPO_DIR/hooks/session-start.sh" <<'PYEOF'
import json, sys
def _atomic_write_json(path, data):
    """settings.json は Claude Code の生命線。途中失敗で壊さないよう temp→os.replace で原子的に置換する。"""
    import os, tempfile
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
ss_hooks = hooks.setdefault("SessionStart", [])
entry = {"type": "command", "command": hook_path}
if not any(h.get("command") == hook_path for h in ss_hooks):
    ss_hooks.append(entry)
    _atomic_write_json(settings_path, d)
    print("✓ Claude Code SessionStart hook 登録済み")
else:
    print("✓ SessionStart hook は登録済みです")
PYEOF
else
  echo "⚠ ~/.claude/settings.json が見つかりません。手動でSessionStartフックを登録してください"
  echo "  hook path: $REPO_DIR/hooks/session-start.sh"
fi

# 4b. Issue #645: 進捗監視ツール (ai-org-progress / subagent-watch) + Agent hooks
#     を ai-org から ai-usage-monitor へ移管。本 repo が正典。
LOCAL_BIN="$HOME/.local/bin"
HOOKS_DST="$HOME/.claude/hooks"
mkdir -p "$LOCAL_BIN" "$HOOKS_DST"

# 進捗 CLI / subagent-watch を ~/.local/bin に install (statusline / launchd が参照する固定パス)
install -m 0755 "$REPO_DIR/scripts/ai-org-progress.sh"       "$LOCAL_BIN/ai-org-progress"
install -m 0755 "$REPO_DIR/scripts/ai-org-subagent-watch.sh" "$LOCAL_BIN/ai-org-subagent-watch"
echo "✓ ai-org-progress / ai-org-subagent-watch を $LOCAL_BIN に install"

# Agent hooks を ~/.claude/hooks/ の正典パスへ同期 (settings.json の登録パスと一致させる)
install -m 0755 "$REPO_DIR/hooks/enforce-subagent-progress.sh" "$HOOKS_DST/enforce_subagent_progress.sh"
install -m 0755 "$REPO_DIR/hooks/auto-pin-subagent.sh"         "$HOOKS_DST/auto_pin_subagent.sh"
echo "✓ enforce_subagent_progress / auto_pin_subagent hook を同期"

# subagent-watch launchd (10s 周期で pin 同期 + Issue #645 死活 reap)
SW_PLIST_SRC="$REPO_DIR/launchd/com.ai-org.subagent-watch.plist"
SW_PLIST_DST="$HOME/Library/LaunchAgents/com.ai-org.subagent-watch.plist"
sed -e "s|HOME_DIR|$HOME|g" "$SW_PLIST_SRC" > "$SW_PLIST_DST"
launchctl unload "$SW_PLIST_DST" 2>/dev/null || true
launchctl load "$SW_PLIST_DST"
echo "✓ subagent-watch launchd 登録 (10s 周期で死活 reap)"

# Agent hooks を settings.json に idempotent 登録 (既存登録があれば no-op)
if command -v python3 >/dev/null && [ -f "$CLAUDE_SETTINGS" ]; then
  python3 - "$CLAUDE_SETTINGS" "$HOOKS_DST/enforce_subagent_progress.sh" "$HOOKS_DST/auto_pin_subagent.sh" <<'PYEOF'
import json, sys
def _atomic_write_json(path, data):
    """settings.json は Claude Code の生命線。途中失敗で壊さないよう temp→os.replace で原子的に置換する。"""
    import os, tempfile
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
settings_path, enforce_path, autopin_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
def ensure(event, cmd):
    arr = hooks.setdefault(event, [])
    for group in arr:
        for h in group.get("hooks", []):
            existing = h.get("command") or ""
            # LOW-2: 部分一致だと auto_pin_subagent_v2 等で誤マッチするため
            # コマンド末尾 (スクリプトパス) の完全一致で判定する。
            if existing == cmd or existing == f"bash {cmd}" or existing.endswith(f" {cmd}"):
                return False
    arr.append({"matcher": "Agent", "hooks": [{"type": "command", "command": f"bash {cmd}"}]})
    return True
changed = ensure("PreToolUse", enforce_path) | ensure("PostToolUse", autopin_path)
if changed:
    _atomic_write_json(settings_path, d)
    print("✓ Agent hooks を settings.json に登録")
else:
    print("✓ Agent hooks は既に登録済み")
PYEOF
fi

# 4c. Issue #42: ターン状態 hook
#     statusline の ✅完了 / 🔵bg / ⏳実行中 / 🔴要操作 と iTerm2 タブタイトルの単一情報源。
#     複数 terminal 運用で「このタブは終わったのか」を判別可能にする。
install -m 0755 "$REPO_DIR/hooks/turn-state.sh" "$HOOKS_DST/claude_turn_state.sh"
echo "✓ claude_turn_state hook を同期"

if command -v python3 >/dev/null && [ -f "$CLAUDE_SETTINGS" ]; then
  python3 - "$CLAUDE_SETTINGS" "$HOOKS_DST/claude_turn_state.sh" <<'PYEOF'
import json, sys
def _atomic_write_json(path, data):
    """settings.json は Claude Code の生命線。途中失敗で壊さないよう temp→os.replace で原子的に置換する。"""
    import os, tempfile
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
settings_path, hook = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
# PreToolUse も張るのは、bg タスク完了で Claude が再開した時に ⏳ へ戻すため。
# hook 側が「同じ状態なら書かない」ので、通常のツール呼び出しに実コストは乗らない。
WIRING = [("UserPromptSubmit", "busy"), ("PreToolUse", "busy"),
          ("Notification", "wait"), ("Stop", "idle")]
changed = False
for event, arg in WIRING:
    cmd = f"bash {hook} {arg}"
    arr = hooks.setdefault(event, [])
    if any((h.get("command") or "") == cmd
           for group in arr for h in group.get("hooks", [])):
        continue
    arr.append({"hooks": [{"type": "command", "command": cmd}]})
    changed = True
if changed:
    _atomic_write_json(settings_path, d)
    print("✓ ターン状態 hook を登録 (UserPromptSubmit/PreToolUse/Notification/Stop)")
else:
    print("✓ ターン状態 hook は既に登録済み")
PYEOF
fi

# 5. 旧パス移行（$DARWIN_USER_TEMP_DIR 配下に移行）
# shellcheck source=lib/cache-path.sh
source "$REPO_DIR/scripts/lib/cache-path.sh"
init_cache_dir

# 旧パス1: /tmp/.ai_usage_cache (v1)
# 旧パス2: /tmp/.ai_usage_<UID>_cache (v2)
# 旧 lockdir: /tmp/.ai_usage_<UID>_cache_update.lockdir (v1/v2 時代の孤児)
# 汚染キャッシュ昇格リスクを避けるため mv せず破棄し、初回 cache-update で再生成する
for OLD_CACHE in "/tmp/.ai_usage_cache" "/tmp/.ai_usage_$(id -u)_cache"; do
  if [ -L "$OLD_CACHE" ]; then
    rm -f "$OLD_CACHE"
    echo "✓ 旧キャッシュ（シンボリックリンク）を削除 ($OLD_CACHE)"
  elif [ -f "$OLD_CACHE" ] && [ -O "$OLD_CACHE" ]; then
    rm -f "$OLD_CACHE"
    echo "✓ 旧キャッシュファイルを削除（初回更新で再生成）($OLD_CACHE)"
  elif [ -f "$OLD_CACHE" ]; then
    echo "⚠ 旧キャッシュが別ユーザー所有のためスキップ ($OLD_CACHE)"
  fi
done
OLD_LOCKDIR="/tmp/.ai_usage_$(id -u)_cache_update.lockdir"
if [ -d "$OLD_LOCKDIR" ]; then
  rm -rf "$OLD_LOCKDIR"
  echo "✓ 旧 lockdir を削除 ($OLD_LOCKDIR)"
fi
# 現行 LOCK_DIR の stale lock を掃除（setup 再実行時に cache-update がスキップされるのを防ぐ）
# active lock（生きている PID + 10分以内）は削除しない
if [ -d "$LOCK_DIR" ]; then
  _setup_lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
  _setup_lock_mtime=$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
  _setup_lock_age=$(( $(date +%s) - _setup_lock_mtime ))
  if [[ "$_setup_lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$_setup_lock_pid" 2>/dev/null && [ "$_setup_lock_age" -le 600 ]; then
    echo "⚠ cache-update 実行中のため lockdir をスキップ ($LOCK_DIR, PID=$_setup_lock_pid)"
  else
    rm -rf "$LOCK_DIR"
    echo "✓ stale lockdir を削除 ($LOCK_DIR)"
  fi
  unset _setup_lock_pid _setup_lock_mtime _setup_lock_age
fi

# 5b. 既存キャッシュファイルの権限ドリフト修復（644→600）
# symlink を拒否（chmod がリンク先に作用するのを防ぐ）
if [ -f "$CACHE_FILE" ] && [ ! -L "$CACHE_FILE" ] && [ -O "$CACHE_FILE" ]; then
  chmod 600 "$CACHE_FILE" 2>/dev/null && echo "✓ キャッシュ権限を 600 に修復 ($CACHE_FILE)"
fi

# 6. 初回キャッシュ更新
echo "→ 初回キャッシュ更新中..."
"$REPO_DIR/scripts/cache-update.sh" && echo "✓ キャッシュ更新完了"

echo ""
echo "=== セットアップ完了 ==="
echo "SwiftBar でメニューバーを確認してください"

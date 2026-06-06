#!/bin/bash
# AI Usage Monitor — one-command setup
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="com.aiorg.usage-monitor"
PLIST_SRC="$REPO_DIR/launchd/$PLIST_NAME.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SWIFTBAR_PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/Library/Application Support/SwiftBar/Plugins}"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "=== AI Usage Monitor セットアップ ==="

# 1. キャッシュ更新スクリプトに実行権限
chmod +x "$REPO_DIR/scripts/cache-update.sh"
chmod +x "$REPO_DIR/swiftbar/ai_usage.5m.sh"
chmod +x "$REPO_DIR/hooks/session-start.sh"
echo "✓ 実行権限付与"

# 2. launchd plist インストール
sed \
  -e "s|REPO_DIR|$REPO_DIR|g" \
  -e "s|HOME_DIR|$HOME|g" \
  "$PLIST_SRC" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "✓ launchd 登録済み (5分ごと自動更新)"

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
settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    d = json.load(f)
hooks = d.setdefault("hooks", {})
ss_hooks = hooks.setdefault("SessionStart", [])
entry = {"type": "command", "command": hook_path}
if not any(h.get("command") == hook_path for h in ss_hooks):
    ss_hooks.append(entry)
    with open(settings_path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print("✓ Claude Code SessionStart hook 登録済み")
else:
    print("✓ SessionStart hook は登録済みです")
PYEOF
else
  echo "⚠ ~/.claude/settings.json が見つかりません。手動でSessionStartフックを登録してください"
  echo "  hook path: $REPO_DIR/hooks/session-start.sh"
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

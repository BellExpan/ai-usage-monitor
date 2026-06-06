#!/bin/bash
# scripts/lib/cache-path.sh — キャッシュパス正典（全スクリプト共通）
#
# DARWIN_USER_TEMP_DIR の末尾スラッシュ保証なし → ${DIR%/}/... で明示 join。
# source して AI_USAGE_DIR / CACHE_FILE / LOCK_DIR を参照する。

# AI_USAGE_BASE_DIR が設定されていれば優先（テスト・移行スクリプト向けオーバーライド用）
# 相対パスが渡された場合はデフォルトにフォールバック（security: パス traversal 防止）
# ※ このファイルは source される（exit 不可）ため、警告後に AI_USAGE_BASE_DIR を空にして続行
if [ -n "${AI_USAGE_BASE_DIR:-}" ] && [[ "$AI_USAGE_BASE_DIR" != /* ]]; then
  echo "ai-usage-monitor: AI_USAGE_BASE_DIR must be an absolute path (got: $AI_USAGE_BASE_DIR) — falling back to default" >&2
  AI_USAGE_BASE_DIR=""
fi
_cache_base=${AI_USAGE_BASE_DIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "/tmp/.ai_usage_$(id -u)/")}
AI_USAGE_DIR="${_cache_base%/}/ai-usage-monitor"
CACHE_FILE="$AI_USAGE_DIR/cache"
LOCK_DIR="$AI_USAGE_DIR/.lockdir"
unset _cache_base

# キャッシュディレクトリを初期化（存在保証 + 0700）
# 呼び出し元スクリプトから明示的に呼ぶこと。
# 失敗時は stderr に出力して return 1。
#   - set -e が有効な呼び出し元（setup.sh 等）では即 exit する（意図どおり）
#   - set -e 非適用の呼び出し元（session-start.sh）では return 1 として継続可能
init_cache_dir() {
  if ! mkdir -p "$AI_USAGE_DIR" 2>/dev/null; then
    echo "ai-usage-monitor: cannot create cache dir: $AI_USAGE_DIR" >&2
    return 1
  fi
  # symlink 攻撃対策: シンボリックリンクは拒否する（chmod/write がリンク先に作用するのを防ぐ）
  if [ -L "$AI_USAGE_DIR" ]; then
    echo "ai-usage-monitor: cache dir is a symlink, rejecting: $AI_USAGE_DIR" >&2
    return 1
  fi
  # squatting 対策: ディレクトリが自分所有でない場合は使用しない
  # (Linux フォールバック /tmp/ でのディレクトリ先占攻撃を防ぐ)
  if ! [ -O "$AI_USAGE_DIR" ]; then
    echo "ai-usage-monitor: cache dir not owned by current user: $AI_USAGE_DIR" >&2
    return 1
  fi
  if ! chmod 700 "$AI_USAGE_DIR" 2>/dev/null; then
    echo "ai-usage-monitor: cannot chmod cache dir: $AI_USAGE_DIR" >&2
    return 1
  fi
}

#!/usr/bin/env bats
# Tests for scripts/lib/settings_json.py — settings.json の安全な書き換え（Issue #42）
#
# Codex レビュー指摘: 素朴な os.replace() は settings.json が symlink の場合に
# symlink 自体を通常ファイルへ置き換えてしまい、dotfiles 管理を壊す（従来挙動からの退行）。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib"
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "$WORK"; }

_write() {  # _write <path> <json>
  PYTHONPATH="$LIB" python3 -c "
import sys, json
from settings_json import atomic_write_json
atomic_write_json(sys.argv[1], json.loads(sys.argv[2]))
" "$1" "$2"
}

@test "writes valid JSON" {
  _write "$WORK/s.json" '{"a": 1}'
  run python3 -c "import json;print(json.load(open('$WORK/s.json'))['a'])"
  [ "$output" = "1" ]
}

@test "keeps a symlink a symlink and writes through to its target" {
  echo '{"old": true}' > "$WORK/real.json"
  ln -s "$WORK/real.json" "$WORK/link.json"
  _write "$WORK/link.json" '{"new": true}'
  [ -L "$WORK/link.json" ]                                   # symlink のまま
  run python3 -c "import json;print('new' in json.load(open('$WORK/real.json')))"
  [ "$output" = "True" ]                                     # 実体が更新されている
}

@test "preserves the original file mode" {
  echo '{}' > "$WORK/s.json"
  chmod 600 "$WORK/s.json"
  _write "$WORK/s.json" '{"a": 1}'
  run bash -c "ls -l '$WORK/s.json' | cut -c1-10"
  [ "$output" = "-rw-------" ]
}

@test "leaves no temp residue on success" {
  _write "$WORK/s.json" '{"a": 1}'
  run bash -c "ls -A '$WORK' | grep -c '^\.settings-' || true"
  [ "$output" = "0" ]
}

@test "leaves the original intact and no residue when serialization fails" {
  echo '{"keep": true}' > "$WORK/s.json"
  run bash -c "PYTHONPATH='$LIB' python3 -c \"
from settings_json import atomic_write_json
class Bad: pass
try:
    atomic_write_json('$WORK/s.json', {'x': Bad()})
except Exception:
    pass
\""
  [ "$status" -eq 0 ]
  run python3 -c "import json;print(json.load(open('$WORK/s.json'))['keep'])"
  [ "$output" = "True" ]                                     # 元ファイルは無傷
  run bash -c "ls -A '$WORK' | grep -c '^\.settings-' || true"
  [ "$output" = "0" ]                                        # 残骸なし
}

@test "creates a new file when none exists" {
  _write "$WORK/new.json" '{"a": 1}'
  [ -f "$WORK/new.json" ]
}

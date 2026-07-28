"""~/.claude/settings.json を安全に書き換えるための共通ヘルパー（Issue #42 / Codex レビュー指摘）。

setup.sh の 3 つの python ブロック（SessionStart / Agent hooks / ターン状態 hook）が
同じ書き込みロジックを重複実装していたため、ここに集約する。

要件:
  1. **atomic** — 途中失敗で settings.json を破損させない（Claude Code の生命線）。
  2. **symlink 透過** — dotfiles 管理で settings.json が symlink のことがある。
     素朴な os.replace() は symlink 自体を通常ファイルへ置き換えてしまうため、
     必ず realpath を解決してから置換する（従来の open(path,"w") と同じ挙動を維持）。
  3. **mode 保持** — mkstemp は 0600 で作るので、元ファイルの権限を引き継ぐ。
"""

import json
import os
import tempfile


def atomic_write_json(path, data):
    """data を JSON として path へ原子的に書き込む。symlink とファイル mode を保持する。"""
    # symlink の場合は実体へ書く（symlink 自体を置き換えない）
    real = os.path.realpath(path)
    directory = os.path.dirname(real) or "."

    try:
        mode = os.stat(real).st_mode & 0o777
    except OSError:
        mode = 0o600  # 新規作成時は保守的に owner のみ

    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

#!/usr/bin/env bats
# Tests for scripts/lib/launchd-deploy.sh (Issue #24)
# drift 検出 / plist render / expected script / self-heal fail-soft を検証する。
# 実 launchd（bootout/bootstrap/print）には触れない純粋ロジックのみ対象。
# Run: bats tests/launchd-deploy.bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=../scripts/lib/launchd-deploy.sh
  source "$REPO_ROOT/scripts/lib/launchd-deploy.sh"
  TMPD=$(mktemp -d)
  FAKE_REPO="/Volumes/EX_SSD/bellExpan/GitHub/tools/ai-usage-monitor"
  FAKE_HOME="/Users/tester"
}

teardown() { rm -rf "$TMPD"; }

# --- 期待スクリプトパス ---
@test "aum_expected_script returns repo/scripts/cache-update.sh" {
  run aum_expected_script "$FAKE_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$FAKE_REPO/scripts/cache-update.sh" ]
}

@test "AUM_PROGRAM is TCC-granted /opt/homebrew/bin/bash (NOT /bin/bash)" {
  # /bin/bash は外部ボリューム(/Volumes/EX_SSD)を TCC で読めず exit 126 になる（#24）。
  [ "$AUM_PROGRAM" = "/opt/homebrew/bin/bash" ]
}

# --- render ---
@test "aum_render_plist expands REPO_DIR and HOME_DIR" {
  # macOS 依存（BSD stat の mtime 粒度 / ps の出力形式 / launchd plist）。
  # Linux CI では skip する。macOS self-hosted runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  aum_render_plist "$REPO_ROOT/launchd/com.aiorg.usage-monitor.plist" "$FAKE_REPO" "$FAKE_HOME" "$TMPD/out.plist"
  [ -f "$TMPD/out.plist" ]
  # ProgramArguments が [/opt/homebrew/bin/bash, <repo>/scripts/cache-update.sh] であること
  run /usr/libexec/PlistBuddy -c "Print ProgramArguments:0" "$TMPD/out.plist"
  [ "$output" = "/opt/homebrew/bin/bash" ]
  run /usr/libexec/PlistBuddy -c "Print ProgramArguments:1" "$TMPD/out.plist"
  [ "$output" = "$FAKE_REPO/scripts/cache-update.sh" ]
  # 未展開の REPO_DIR / HOME_DIR プレースホルダが残っていないこと
  run grep -c "REPO_DIR\|HOME_DIR" "$TMPD/out.plist"
  [ "$output" = "0" ]
}

@test "aum_render_plist rejects path containing pipe char" {
  run aum_render_plist "$REPO_ROOT/launchd/com.aiorg.usage-monitor.plist" "/bad|path" "$FAKE_HOME" "$TMPD/out.plist"
  [ "$status" -ne 0 ]
}

@test "aum_render_plist rejects path containing backslash or ampersand" {
  run aum_render_plist "$REPO_ROOT/launchd/com.aiorg.usage-monitor.plist" '/bad\path' "$FAKE_HOME" "$TMPD/out.plist"
  [ "$status" -ne 0 ]
  run aum_render_plist "$REPO_ROOT/launchd/com.aiorg.usage-monitor.plist" '/bad&path' "$FAKE_HOME" "$TMPD/out.plist"
  [ "$status" -ne 0 ]
}

@test "aum_render_plist fails when template missing" {
  run aum_render_plist "$TMPD/nonexistent.plist" "$FAKE_REPO" "$FAKE_HOME" "$TMPD/out.plist"
  [ "$status" -ne 0 ]
}

# --- drift 検出 ---
@test "correct plist is NOT drifted" {
  # macOS 依存（BSD stat の mtime 粒度 / ps の出力形式 / launchd plist）。
  # Linux CI では skip する。macOS self-hosted runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  aum_render_plist "$REPO_ROOT/launchd/com.aiorg.usage-monitor.plist" "$FAKE_REPO" "$FAKE_HOME" "$TMPD/ok.plist"
  run aum_plist_drifted "$TMPD/ok.plist" "$FAKE_REPO"
  [ "$status" -eq 1 ]   # return 1 = drift なし
}

@test "old single-element (external script) plist IS drifted" {
  # Issue #24 の事故 plist を再現: ProgramArguments = [外部スクリプト] のみ
  cat > "$TMPD/old.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.aiorg.usage-monitor</string>
  <key>ProgramArguments</key><array>
    <string>$FAKE_REPO/scripts/cache-update.sh</string>
  </array>
</dict></plist>
EOF
  run aum_plist_drifted "$TMPD/old.plist" "$FAKE_REPO"
  [ "$status" -eq 0 ]   # return 0 = drift あり
}

@test "wrong program (/bin/bash) IS drifted vs /opt/homebrew canon" {
  # /bin/bash は TCC で外部ボリュームを読めず exit 126 になるため drift 扱い（#24）。
  cat > "$TMPD/sysbash.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.aiorg.usage-monitor</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$FAKE_REPO/scripts/cache-update.sh</string>
  </array>
</dict></plist>
EOF
  run aum_plist_drifted "$TMPD/sysbash.plist" "$FAKE_REPO"
  [ "$status" -eq 0 ]
}

@test "missing plist is treated as drifted" {
  run aum_plist_drifted "$TMPD/does-not-exist.plist" "$FAKE_REPO"
  [ "$status" -eq 0 ]
}

# --- self-heal fail-soft ---
@test "aum_self_heal_if_needed returns 0 (fail-soft) when template unreadable" {
  # 外部ボリューム未マウント相当: テンプレ不在 repo を渡しても crash せず return 0
  export AI_USAGE_DIR="$TMPD"
  run aum_self_heal_if_needed "$TMPD/no-such-repo"
  [ "$status" -eq 0 ]
}

@test "aum_self_heal_if_needed skips within cooldown" {
  # macOS 依存（BSD stat の mtime 粒度 / ps の出力形式 / launchd plist）。
  # Linux CI では skip する。macOS self-hosted runner 復旧後にフル実行へ戻す（#40）。
  [ "$(uname)" = "Darwin" ] || skip "macOS only (see #40)"
  # cooldown マーカーを新鮮な状態で置くと、drift 判定に到達せず即 return 0
  export AI_USAGE_DIR="$TMPD"
  : > "$TMPD/.selfheal-cooldown"
  run aum_self_heal_if_needed "$TMPD/no-such-repo"
  [ "$status" -eq 0 ]
}

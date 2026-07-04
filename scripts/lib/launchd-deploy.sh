#!/bin/bash
# scripts/lib/launchd-deploy.sh — usage-monitor launchd デプロイ/検証の正典（単一情報源）
#
# setup.sh（install 時 fail-loud verify）と hooks/session-start.sh（stale 時 drift 自己修復）
# の双方が source する。source して関数を使う（exit しない設計・hook から安全に呼べる）。
#
# 責務:
#   - render : テンプレ plist を実パスに sed 展開
#   - deploy : bootout → bootstrap → kickstart（modern launchctl）
#   - verify : launchctl print で健全性（penalty box なし / last exit 0）
#   - drift  : installed plist の ProgramArguments が期待値と一致するか
#
# Issue #24: 外部ボリューム上のスクリプトを launchd が program として直接 exec すると
# LWCR/マウントで EX_CONFIG(78) penalty box に入り 5分毎更新が止まる。program は bash に
# し、外部 repo の cache-update.sh は引数（データ）として読ませる。

AUM_LABEL="com.aiorg.usage-monitor"

# launchd program は /opt/homebrew/bin/bash 必須（/bin/bash に変えるな）。
# 理由: cache-update.sh は外部ボリューム(/Volumes/EX_SSD)上にあり、macOS TCC の
# 「Removable Volumes」制限で TCC 付与済みの Homebrew bash だけが読める。システムの
# /bin/bash は launchd 実行時に "Operation not permitted"(exit 126) になる（#24 で実証）。
# memory: feedback_macos_tcc_removable_volumes
AUM_PROGRAM="/opt/homebrew/bin/bash"

aum_domain()  { echo "gui/$(id -u)"; }
aum_service() { echo "gui/$(id -u)/$AUM_LABEL"; }

# 期待する ProgramArguments[1]（cache-update.sh の実パス）。 $1=repo_dir
aum_expected_script() { echo "$1/scripts/cache-update.sh"; }

# テンプレ plist を実パスに展開して dst に書く。 $1=template $2=repo_dir $3=home $4=dst
# sed 区切りは | を使うため path に | / & が入ると壊れる → 事前に拒否。
aum_render_plist() {
  local tmpl="$1" repo="$2" home="$3" dst="$4"
  case "$repo$home" in *'|'*|*'&'*|*'\'*|*'
'*)
    echo "aum_render_plist: repo/home path に | & \\ 改行 を含むため中断: $repo" >&2; return 1;;
  esac
  [ -r "$tmpl" ] || { echo "aum_render_plist: テンプレ不在: $tmpl" >&2; return 1; }
  sed -e "s|REPO_DIR|$repo|g" -e "s|HOME_DIR|$home|g" "$tmpl" > "$dst" || return 1
}

# plist を再デプロイ（bootout→bootstrap→kickstart）。 $1=plist_dst
aum_deploy() {
  local dst="$1" domain service
  domain=$(aum_domain); service=$(aum_service)
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$dst" >/dev/null 2>&1 || { echo "aum_deploy: plutil lint 失敗: $dst" >&2; return 1; }
  fi
  /bin/launchctl bootout "$service" 2>/dev/null || true
  /bin/launchctl bootout "$domain" "$dst" 2>/dev/null || true
  /bin/launchctl bootstrap "$domain" "$dst" || { echo "aum_deploy: bootstrap 失敗: $dst" >&2; return 1; }
  /bin/launchctl kickstart -k "$service" 2>/dev/null || true
  return 0
}

# installed plist の ProgramArguments:N を取得。 $1=installed_plist $2=index
aum_installed_program() {
  local dst="$1" idx="$2"
  [ -r "$dst" ] || return 1
  /usr/libexec/PlistBuddy -c "Print ProgramArguments:$idx" "$dst" 2>/dev/null
}

# drift 判定: installed の PA[0]/PA[1] が期待値と不一致 or 不在なら drift（return 0）。
# 一致なら return 1。 $1=installed_plist $2=repo_dir
aum_plist_drifted() {
  local dst="$1" repo="$2" p0 p1 exp1
  exp1=$(aum_expected_script "$repo")
  p0=$(aum_installed_program "$dst" 0) || return 0   # 読めない/不在 = drift
  p1=$(aum_installed_program "$dst" 1)               # 単一要素旧 plist では空 → drift
  [ "$p0" = "$AUM_PROGRAM" ] && [ "$p1" = "$exp1" ] && return 1
  return 0
}

# 健全性判定: loaded かつ penalty box でなく last exit code が 0 or 未記録なら healthy(return 0)。
# 不健全/未ロードなら return 1、理由を stdout に1行。
aum_verify_health() {
  local service out code
  service=$(aum_service)
  out=$(/bin/launchctl print "$service" 2>/dev/null) || { echo "not-loaded"; return 1; }
  if printf '%s' "$out" | grep -qi "penalty box"; then echo "penalty-box"; return 1; fi
  code=$(printf '%s\n' "$out" | grep -iE "last exit code" | grep -oE "[0-9]+" | head -1)
  if [ -n "$code" ] && [ "$code" != "0" ]; then echo "exit-$code"; return 1; fi
  echo "healthy"; return 0
}

# stale 時に呼ぶ自己修復。drift/unhealthy を検出したら plist 再デプロイ。
# cooldown（既定600s）で毎回叩かない。fail-soft（常に return 0）。 $1=repo_dir
aum_self_heal_if_needed() {
  local repo="$1" home="$HOME"
  local plist_tmpl="$repo/launchd/$AUM_LABEL.plist"
  local plist_dst="$home/Library/LaunchAgents/$AUM_LABEL.plist"
  local cooldown="${AI_USAGE_DIR:-/tmp}/.selfheal-cooldown"

  # cooldown 内なら skip（毎セッション launchd を触らない）
  if [ -f "$cooldown" ]; then
    local mt age; mt=$(stat -f %m "$cooldown" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mt ))
    [ "$age" -lt 600 ] && return 0
  fi

  # drift も unhealthy も無ければ何もしない（副作用ゼロ）
  if ! aum_plist_drifted "$plist_dst" "$repo" && aum_verify_health >/dev/null 2>&1; then
    return 0
  fi

  # テンプレが読めない（外部ボリューム未マウント等）→ 修復不能・skip
  [ -r "$plist_tmpl" ] || return 0

  echo "[AI使用量司令塔] 🔧 launchd plist ドリフト/不健全を検出 → 再デプロイ（Issue #24 自己修復）" >&2
  if aum_render_plist "$plist_tmpl" "$repo" "$home" "$plist_dst" 2>/dev/null; then
    aum_deploy "$plist_dst" 2>/dev/null || true
  fi
  : > "$cooldown" 2>/dev/null || true
  return 0
}

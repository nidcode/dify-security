#!/usr/bin/env bash
# =============================================================================
# ログの保存 (ホストのディレクトリ) とローテーションを、このホストの既存環境に適用する。
#   既定は計画の表示のみ (何も変更しない)。--apply で実行する (sudo を使う)。
#   新しく作るインスタンスは dify-new.sh が同じ構成にするため、主に既存環境への適用用。
#   何度実行してもよい (冪等)。
#
#   使い方: bash scripts/log-setup.sh <dify|gateway|litellm> [--apply]
#     dify    : Dify VM    — 全インスタンスのログを各インスタンスの logs/ に保存 + /etc/logrotate.d/dify-*
#     gateway : Gateway VM — front-nginx のログを logs/gateway/ に保存 + /etc/logrotate.d/gateway-*
#     litellm : LiteLLM VM — ファイルに出すログは無い (Docker ログの上限のみ)
#   共通: Docker のログ (/var/lib/docker) に上限を設定する (/etc/docker/daemon.json)。
#         既存コンテナは作り直すまで上限が効かないため、上限の無いコンテナがあるスタックは作り直す。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/dify-instance.sh

USAGE="usage: log-setup.sh <dify|gateway|litellm> [--apply]"
ROLE="${1:?$USAGE}"
APPLY=0
case "${2:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "❌ 不明な引数: $2 ($USAGE)"; exit 1 ;;
esac
case "$ROLE" in
  dify)    LOGROTATE_SRC=(dify/logrotate/*) ;;
  gateway) LOGROTATE_SRC=(gateway/logrotate/*) ;;
  litellm) LOGROTATE_SRC=() ;;
  *) echo "❌ 不明な役割: $ROLE ($USAGE)"; exit 1 ;;
esac
REPO_DIR="$(pwd)"
[[ "$REPO_DIR" != *[[:space:]]* ]] || { echo "❌ リポジトリのパスに空白を含むと logrotate の設定に書けません: $REPO_DIR"; exit 1; }
# root で丸ごと実行すると、生成物 (ログ設定の compose ファイル・logs/) が root 所有になり、
# 以後の運用ユーザーでの操作 (dify-upgrade.sh 等) やバックアップの読み取りが失敗する。
# sudo が要る箇所 (/etc 配下と Docker の再起動) だけ内部で sudo を使う。
(( EUID != 0 )) || { echo "❌ sudo を付けずに運用ユーザーで実行すること (必要な箇所だけ sudo を使う)"; exit 1; }
SUDO="sudo"

# Docker ログの上限 (コンテナごと)。/var/lib/docker を使い切らないための最優先の設定。
DAEMON_JSON=/etc/docker/daemon.json
LOG_MAX_SIZE=10m
LOG_MAX_FILE=5

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

echo "==> log-setup: $ROLE"

# --- 1. Docker ログの上限 -----------------------------------------------------
#   既に上限がある (json-file で max-size 設定済み / local ドライバ) なら変更しない。
#   json-file 以外の独自ドライバ (journald 等) を使っている場合も変更しない (運用者の選択を尊重)。
echo ""
echo "--- 1. Docker ログの上限 ($DAEMON_JSON) ---"
daemon_state="$(python3 - "$DAEMON_JSON" "$TMPD/daemon.json" "$LOG_MAX_SIZE" "$LOG_MAX_FILE" <<'PY'
import json, os, sys
path, out, size, count = sys.argv[1:5]
conf = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
driver = conf.get("log-driver", "json-file")
opts = conf.get("log-opts", {})
if driver == "json-file" and opts.get("max-size"):
    print(f"ok json-file max-size={opts['max-size']} max-file={opts.get('max-file', '1')}")
elif driver == "local":
    print("ok local (ドライバ内蔵の上限あり)")
elif driver != "json-file":
    print(f"other {driver}")
else:
    conf["log-driver"] = "json-file"
    conf["log-opts"] = {**opts, "max-size": size, "max-file": count}
    json.dump(conf, open(out, "w"), indent=2)
    print("change")
PY
)"
DAEMON_CHANGE=0
case "$daemon_state" in
  ok*)    echo "  設定済み: ${daemon_state#ok } (変更しない)" ;;
  other*) echo "  ⚠ 独自のログドライバ (${daemon_state#other }) のため変更しない。上限はそのドライバ側で確認すること" ;;
  change)
    DAEMON_CHANGE=1
    echo "  上限なし → max-size=$LOG_MAX_SIZE / max-file=$LOG_MAX_FILE を設定 (既存の設定は保持)"
    echo "  ⚠ 反映に Docker の再起動が必要 = このホストの全コンテナが一度再起動する"
    ;;
esac

# --- 2. logrotate -------------------------------------------------------------
#   配置先が無ければ置く。あって内容が違う場合は、保持期間などの編集を尊重して上書きしない。
echo ""
echo "--- 2. logrotate (/etc/logrotate.d/) ---"
LR_INSTALL=()
if (( ${#LOGROTATE_SRC[@]} == 0 )); then
  echo "  (この役割にファイルに出すログは無い)"
else
  command -v logrotate >/dev/null || echo "  ⚠ logrotate が見つかりません (apt-get install -y logrotate)"
  for src in "${LOGROTATE_SRC[@]}"; do
    name="$(basename "$src")"
    dest="/etc/logrotate.d/$name"
    sed "s|@REPO_DIR@|$REPO_DIR|g" "$src" > "$TMPD/$name"
    if [[ ! -e "$dest" ]]; then
      echo "  $name: 新規に配置"
      LR_INSTALL+=("$name")
    elif cmp -s "$TMPD/$name" "$dest"; then
      echo "  $name: 配置済み (変更なし)"
    else
      echo "  $name: 配置済みで内容が異なる → 上書きしない (編集を尊重。更新したい場合は削除して再実行)"
    fi
  done
fi

# --- 3. ログの保存先と各スタックへの反映 ---------------------------------------
#   上限の無いコンテナの数 (compose が付ける working_dir ラベルでスタックのコンテナを特定)
unlimited_in() {
  docker ps -aq --filter "label=com.docker.compose.project.working_dir=$1" \
    | xargs -r docker inspect -f '{{.HostConfig.LogConfig.Type}} {{index .HostConfig.LogConfig.Config "max-size"}}' \
    | awk '$1 == "json-file" && $2 == "" { n++ } END { print n + 0 }'
}
# 作り直しが要るか (Docker ログの上限を変える場合 / 上限の無いコンテナがある場合) → up のオプション
recreate_flag() {
  local n
  n="$(unlimited_in "$1")"
  if (( DAEMON_CHANGE || n > 0 )); then echo "--force-recreate"; fi
}

echo ""
echo "--- 3. ログの保存先と反映 ---"
STACKS=()   # "表示名|working_dir"
case "$ROLE" in
  dify)
    for d in dify/instances/*/; do
      d="${d%/}"
      [[ -f "$d/.env" && -f "$d/docker-compose.yaml" ]] || continue
      STACKS+=("$(basename "$d")|$REPO_DIR/$d")
    done
    (( ${#STACKS[@]} )) || echo "  (インスタンスなし)"
    ;;
  gateway|litellm) STACKS+=("$ROLE|$REPO_DIR") ;;
esac
for s in "${STACKS[@]}"; do
  label="${s%%|*}"; dir="${s#*|}"
  flag="$(recreate_flag "$dir")"
  case "$ROLE" in
    dify)    echo "  $label: ログ → ${dir#"$REPO_DIR"/}/logs/<サービス>/" ;;
    gateway) echo "  gateway: front-nginx のログ → logs/gateway/nginx/" ;;
    litellm) echo "  litellm: ファイルに出すログは無い" ;;
  esac
  if [[ -n "$flag" ]]; then
    echo "    作り直す (Docker ログの上限を効かせるため。上限の無いコンテナ: $(unlimited_in "$dir") 個)"
  elif [[ "$ROLE" != "litellm" ]]; then
    echo "    設定の変わったサービスだけ作り直す (docker compose up -d)"
  fi
done

if (( ! APPLY )); then
  echo ""
  echo "計画の表示のみ (何も変更していません)。実行するには (sudo のパスワードを求められる):"
  echo "  bash scripts/log-setup.sh $ROLE --apply"
  exit 0
fi

# =============================================================================
# ここから --apply
# =============================================================================
echo ""
if (( DAEMON_CHANGE )); then
  echo "==> Docker ログの上限を設定して Docker を再起動"
  $SUDO install -m 644 "$TMPD/daemon.json" "$DAEMON_JSON"
  $SUDO systemctl restart docker
  for _ in $(seq 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  docker info >/dev/null 2>&1 || { echo "❌ Docker が再起動後に応答しません (sudo systemctl status docker)"; exit 1; }
fi

for name in "${LR_INSTALL[@]}"; do
  echo "==> /etc/logrotate.d/$name を配置"
  $SUDO install -o root -g root -m 644 "$TMPD/$name" "/etc/logrotate.d/$name"   # root 所有でないと logrotate が無視する
  $SUDO logrotate -d "/etc/logrotate.d/$name" >/dev/null 2>"$TMPD/lr.err" \
    || { cat "$TMPD/lr.err"; echo "❌ /etc/logrotate.d/$name の検証に失敗しました"; exit 1; }
done

for s in "${STACKS[@]}"; do
  label="${s%%|*}"; dir="${s#*|}"
  flag="$(recreate_flag "$dir")"
  echo "==> $label に反映 ${flag:-}"
  case "$ROLE" in
    dify)
      dify_install_log_config "$dir"
      (cd "$dir" && docker compose up -d $flag)
      ;;
    gateway)
      mkdir -p logs/gateway/nginx   # 運用ユーザーが作る (バックアップで読めるように)
      bash scripts/gateway-compose.sh up -d $flag
      ;;
    litellm)
      if [[ -n "$flag" ]]; then make up UP_FLAGS="$flag"; else echo "  (変更なし)"; fi
      ;;
  esac
done

echo ""
echo "✅ 完了。確認:"
echo "   docker ps -q | xargs docker inspect -f '{{.Name}} {{index .HostConfig.LogConfig.Config \"max-size\"}}'   # 全コンテナに上限"
case "$ROLE" in
  dify)    echo "   ls -l dify/instances/*/logs/*/                                   # ログファイル" ;;
  gateway) echo "   ls -l logs/gateway/nginx/                                        # ログファイル" ;;
esac

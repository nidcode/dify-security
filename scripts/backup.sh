#!/usr/bin/env bash
# =============================================================================
# 日常のバックアップ (手順書03)。cron から定期実行する。
#   取得 → 検証 → 古い世代の削除 までを行う (オフサイトへの複製は手順書03の rclone で別に行う)。
#   1つでも失敗したら 0 以外で終わる (cron の通知で気付けるように)。取れなかった対象の
#   古い世代は消さない。
#
#   使い方: bash scripts/backup.sh <対象> [<Difyインスタンス名>...]
#     dify-db    : Dify VM — DB                (日次)  インスタンス名を省略すると全インスタンス
#     dify-files : Dify VM — インスタンスフォルダ一式 (週次。Weaviate を一時停止)  同上
#     gateway    : Gateway VM — Keycloak DB + ファイル一式 (日次)
#     litellm    : LiteLLM VM — LiteLLM DB + ファイル一式  (日次)
#
#   設定 (ルート .env):
#     BACKUP_DIR             保存先 (必須)
#     BACKUP_KEEP            残す世代数 (既定 14)
#     BACKUP_KEEP_DIFY_FILES Dify のファイル一式だけ別に残す世代数 (既定 4。週次で容量も大きいため)
#
#   ファイル名は <名前>-<日付>.<拡張子> (手順書03のリストア手順はこの名前で探す)。
#   同じ日に再実行すると上書きする。dify-upgrade.sh の更新前バックアップ (名前に pre-upgrade を
#   含む) は世代削除の対象外。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/dify-instance.sh
. scripts/lib/backup.sh

USAGE="usage: backup.sh <dify-db|dify-files|gateway|litellm> [<Difyインスタンス名>...]"
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "$USAGE"; exit 1; }
shift
[[ -f .env ]] || { echo "❌ .env がありません"; exit 1; }

BD="$(backup_dir)"
[[ -n "$BD" ]] || { echo "❌ ルート .env の BACKUP_DIR が未設定です"; exit 1; }
KEEP="$(root_env BACKUP_KEEP)"; KEEP="${KEEP:-14}"
KEEP_DIFY_FILES="$(root_env BACKUP_KEEP_DIFY_FILES)"; KEEP_DIFY_FILES="${KEEP_DIFY_FILES:-4}"
[[ "$KEEP" =~ ^[1-9][0-9]*$ && "$KEEP_DIFY_FILES" =~ ^[1-9][0-9]*$ ]] || {
  echo "❌ BACKUP_KEEP / BACKUP_KEEP_DIFY_FILES は 1 以上の整数で指定してください"; exit 1
}
mkdir -p "$BD"
TODAY="$(date +%F)"
FAILED=0

# <prefix>-YYYY-MM-DD.<ext> のうち新しい方から <keep> 世代だけ残す。
#   日付の形に完全一致するものだけが対象 (pre-upgrade や、名前が前方一致する別インスタンスは消さない)。
#   glob は名前順 = 日付順に並ぶ。
prune() {  # usage: prune <prefix> <ext> <keep>
  local prefix="$1" ext="$2" keep="$3" f gens=()
  shopt -s nullglob
  gens=("$BD/$prefix"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]."$ext")
  shopt -u nullglob
  (( ${#gens[@]} > keep )) || return 0
  for f in "${gens[@]:0:${#gens[@]}-keep}"; do
    rm -f -- "$f"
    echo "  削除 (古い世代): $f"
  done
}

# 1つ取得して検証し、成功したら古い世代を削除する。失敗は記録して次へ進む。
take() {  # usage: take <prefix> <ext> <keep> <cmd...>
  local prefix="$1" ext="$2" keep="$3" out
  shift 3
  out="$BD/$prefix-$TODAY.$ext"
  echo "==> $prefix"
  if backup_save "$out" "$@"; then
    echo "  ✅ $out ($(du -h "$out" | cut -f1))"
    prune "$prefix" "$ext" "$keep"
  else
    FAILED=1
  fi
}

# 存在するものだけを残す (構成によって無いファイルがある: 素通しモードの oauth2-proxy 群など)。
existing() { local p; for p in "$@"; do [[ -e "$p" ]] && printf '%s\n' "$p"; done; return 0; }

# --- 対象ごとの取得 -------------------------------------------------------------
dify_instances() {  # 引数があればそれを、無ければ全インスタンスを出力
  local d
  if (( $# )); then printf '%s\n' "$@"; return; fi
  for d in dify/instances/*/; do [[ -f "$d/.env" ]] && basename "$d"; done
  return 0
}

backup_dify() {  # usage: backup_dify <db|files> [name...]
  local kind="$1" name dir reason
  shift
  local names=()
  mapfile -t names < <(dify_instances "$@")
  (( ${#names[@]} )) || { echo "❌ Dify インスタンスがありません (dify/instances/)"; FAILED=1; return; }
  for name in "${names[@]}"; do
    dir="dify/instances/$name"
    if [[ ! -f "$dir/.env" ]]; then
      echo "❌ $dir がありません"; FAILED=1; continue
    fi
    if reason="$(dify_backup_unsupported "$dir")"; then
      echo "❌ $name: $reason は未対応 (手順書03のバックアップは同梱 Postgres + Weaviate 前提)"; FAILED=1; continue
    fi
    case "$kind" in
      db)    take "dify-$name-db"    sql.gz "$KEEP"            dify_backup_db    "$dir" ;;
      files) take "dify-$name-files" tar.gz "$KEEP_DIFY_FILES" dify_backup_files "$dir" ;;
    esac
  done
}

backup_gateway() {
  . scripts/lib/gateway.sh
  # Keycloak の DB への接続方法は Makefile (gateway-db-dump) に一元化。
  gateway_db() { make -s gateway-db-dump | gzip; }
  # .env / compose 定義 (overlay 含む) / 運用スクリプト / ログ / nginx 設定一式 /
  # チーム別 oauth2-proxy 定義 / TLS 証明書
  local files=()
  mapfile -t files < <(existing .env "$GATEWAY_COMPOSE_FILE" "$GATEWAY_PASSTHRU_FILE" \
    "$GATEWAY_PASSTHRU_TLS_FILE" Makefile scripts logs "$GATEWAY_PROXIES_FILE" gateway/nginx gateway/certs)
  take keycloak-db   sql.gz "$KEEP" gateway_db
  take gateway-files tar.gz "$KEEP" backup_tar . "${files[@]}"
}

backup_litellm() {
  # LiteLLM の DB への接続方法は Makefile (litellm-db-dump) に一元化。
  litellm_db() { make -s litellm-db-dump | gzip; }
  # .env / compose 定義 / Makefile / モデル設定 / Vertex WIF 資格情報
  local files=()
  mapfile -t files < <(existing .env compose.litellm.yaml Makefile litellm/config.yaml gateway/wif)
  take litellm-db    sql.gz "$KEEP" litellm_db
  take litellm-files tar.gz "$KEEP" backup_tar . "${files[@]}"
}

case "$TARGET" in
  dify-db)    backup_dify db "$@" ;;
  dify-files) backup_dify files "$@" ;;
  gateway)    backup_gateway ;;
  litellm)    backup_litellm ;;
  *) echo "❌ 不明な対象: $TARGET ($USAGE)"; exit 1 ;;
esac

if (( FAILED )); then
  echo "❌ 失敗した処理があります (上の ❌ を確認)"
  exit 1
fi
echo "✅ 完了"

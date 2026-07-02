#!/usr/bin/env bash
# =============================================================================
# 既存 Dify インスタンスの .env を「前段公開ドメイン」用に調整する。
#   前段(front-nginx)で公開すると、Dify は絶対 URL (共有リンク/ファイル/コンソール)
#   と cookie/CORS を公開ドメイン基準にする必要がある。
#
#   触るのは dify/instances/<name>/.env のみ (生成物・gitignore 済み)。
#   compose/override には手を入れない = 既存構成へ疎結合。
#
#   使い方: bash scripts/gateway-difyenv.sh <team> [subdomain]
#   反映:   cd dify/instances/<name> && docker compose up -d   (env 反映のため再作成)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: gateway-difyenv.sh <name> [subdomain]}"
SUB="${2:-$NAME}"
ENV="dify/instances/${NAME}/.env"
[[ -f "$ENV" ]] || { echo "❌ $ENV がありません (先に make dify-new)"; exit 1; }
[[ -f .env ]] || { echo "❌ ルート .env がありません"; exit 1; }
set -a; . ./.env; set +a
: "${GATEWAY_DOMAIN:?}"

FQDN="${SUB}.${GATEWAY_DOMAIN}"
URL="https://${FQDN}"

set_env() {  # 既存行は置換、無ければ追記
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV"; then sed -i "s|^${key}=.*|${key}=${val}|" "$ENV";
  else printf '%s=%s\n' "$key" "$val" >> "$ENV"; fi
}

set_env NGINX_SERVER_NAME "$FQDN"
set_env CONSOLE_API_URL   "$URL"
set_env CONSOLE_WEB_URL   "$URL"
set_env SERVICE_API_URL   "$URL"
set_env APP_API_URL       "$URL"
set_env APP_WEB_URL       "$URL"
set_env FILES_URL         "$URL"
# TLS は front-nginx で終端。インスタンス側 nginx は http のまま。
set_env NGINX_HTTPS_ENABLED "false"

echo "✅ $ENV を $URL 用に更新 (NGINX_SERVER_NAME / *_URL)"
echo "   反映: cd dify/instances/${NAME} && docker compose up -d"

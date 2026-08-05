#!/usr/bin/env bash
# =============================================================================
# Keycloak から client_credentials で JWT を取得し、GCP WIF (external_account)
# の credential-source-file が読む場所に書き込む。cron/systemd timer で定期実行する。
#
#   Keycloak realm の accessTokenLifespan (既定 300s) より短い間隔で実行すること。
#   このリポジトリの realm 'aiop' は 300s なので、2分毎 (*/2 * * * *) を推奨。
#
#   Keycloak イメージに curl/wget/python3 が無いため、bash の /dev/tcp で
#   コンテナ内から生の HTTP リクエストを送る (gateway-wif-client.sh と同じ手法)。
#
#   使い方:
#     bash scripts/gateway-wif-refresh-token.sh [client-id]
#     例: bash scripts/gateway-wif-refresh-token.sh litellm-vertex-wif
#
#   crontab 例 (2分毎):
#     */2 * * * * cd /path/to/dify-security && \
#       bash scripts/gateway-wif-refresh-token.sh litellm-vertex-wif >> /var/log/gateway-wif-refresh.log 2>&1
#
#   前提: scripts/gateway-wif-client.sh 実行済み (gateway/wif/<client-id>.env が存在)。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT="${1:-litellm-vertex-wif}"
ENVFILE="gateway/wif/${CLIENT}.env"
OUTFILE="gateway/wif/keycloak-token.jwt"

[[ -f "$ENVFILE" ]] || { echo "❌ ${ENVFILE} がありません。先に: bash scripts/gateway-wif-client.sh ${CLIENT}"; exit 1; }
set -a; . "./${ENVFILE}"; set +a
: "${KEYCLOAK_TOKEN_URL_INTERNAL:?}"; : "${WIF_CLIENT_ID:?}"; : "${WIF_CLIENT_SECRET:?}"

# KEYCLOAK_TOKEN_URL_INTERNAL は http://localhost:8080/realms/<realm>/protocol/openid-connect/token
REALM_PATH="${KEYCLOAK_TOKEN_URL_INTERNAL#http://localhost:8080}"

TOKEN_BODY="grant_type=client_credentials&client_id=${WIF_CLIENT_ID}&client_secret=${WIF_CLIENT_SECRET}"
TOKEN_BODY_LEN="${#TOKEN_BODY}"

GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"

RESPONSE="$($GW exec -T keycloak bash -c "
exec 3<>/dev/tcp/localhost/8080
printf 'POST ${REALM_PATH} HTTP/1.0\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: ${TOKEN_BODY_LEN}\r\n\r\n${TOKEN_BODY}' >&3
cat <&3
" | tr -d '\r' | awk 'BEGIN{body=0} /^$/ && body==0 {body=1; next} body{print}')"

ACCESS_TOKEN="$(printf '%s' "$RESPONSE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' 2>/dev/null)" || {
  echo "❌ トークン取得失敗。レスポンス: ${RESPONSE}"; exit 1;
}

printf '%s' "$ACCESS_TOKEN" > "$OUTFILE"
chmod 600 "$OUTFILE"
echo "✅ $(date '+%F %T') トークン更新: ${OUTFILE}"

#!/usr/bin/env bash
# =============================================================================
# GCP Workload Identity Federation 用の Keycloak confidential client を作成する。
#
#   やること:
#     1. Keycloak に client <client-id> を作成
#        - Standard flow / Direct access grants: 無効
#        - Service accounts roles: 有効 (client_credentials grant 専用)
#     2. Audience protocol mapper を付与 (access token に aud=<audience> を固定で載せる)
#        → GCP 側 workload-identity-pools providers create-oidc の
#          --allowed-audiences とここの <audience> を一致させる。
#     3. client secret を生成し、<client-id> + secret + issuer/audience を
#        gateway/wif/<client-id>.env に書き出す (chmod 600, .gitignore 済み)。
#        このファイルを、LiteLLM ホスト側でトークンを定期取得するスクリプトが読む。
#
#   GCP 側の attribute-condition は "assertion.azp=='<client-id>'" にする
#   (Keycloak は client_credentials で発行したトークンにも azp=client_id を必ず載せる)。
#
#   使い方:
#     bash scripts/gateway-wif-client.sh [client-id] [audience]
#     例: bash scripts/gateway-wif-client.sh litellm-vertex-wif \
#           https://gcp-wif.dify-security.internal/litellm-vertex
#
#   前提: Gateway 起動済み + scripts/gateway-keycloak-init.sh 実行済み。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT="${1:-litellm-vertex-wif}"
AUDIENCE="${2:-https://gcp-wif.dify-security.internal/${CLIENT}}"

[[ -f .env ]] || { echo "❌ .env がありません"; exit 1; }
set -a; . ./.env; set +a
: "${GATEWAY_DOMAIN:?}"; : "${KEYCLOAK_REALM:?}"
: "${KEYCLOAK_ADMIN:?}"; : "${KEYCLOAK_ADMIN_PASSWORD:?}"

OUTDIR="gateway/wif"
OUTFILE="${OUTDIR}/${CLIENT}.env"
mkdir -p "$OUTDIR"

GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

echo "🔑 Keycloak にログイン ..."
KC config credentials --server http://localhost:8080 \
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# --- 既存チェック ---
if KC get clients -r "$KEYCLOAK_REALM" -q "clientId=$CLIENT" --fields id --format csv 2>/dev/null | grep -q '"'; then
  echo "❌ client '$CLIENT' は既に存在します (再作成するには先に Keycloak 管理UIか";
  echo "   'KC delete clients/<id> -r $KEYCLOAK_REALM' で削除してください)"; exit 1
fi

# --- 1. client 作成 (service account 専用: 対話フローは全て無効) ---
CLIENT_SECRET="$(openssl rand -hex 24)"
CID="$(KC create clients -r "$KEYCLOAK_REALM" \
  -s clientId="$CLIENT" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s clientAuthenticatorType=client-secret \
  -s standardFlowEnabled=false \
  -s implicitFlowEnabled=false \
  -s directAccessGrantsEnabled=false \
  -s serviceAccountsEnabled=true \
  -i)"
# シークレットは作成後に明示 update で確実に設定 (create -s secret= は版により無視される)
KC update "clients/$CID" -r "$KEYCLOAK_REALM" -s "secret=$CLIENT_SECRET" >/dev/null
echo "✅ client '$CLIENT' を作成 (id=$CID, service account 有効)"

# --- 2. Audience mapper (aud=<audience> をアクセストークンに固定付与) ---
KC create "clients/$CID/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
  -s name=gcp-wif-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper \
  -s "config.\"included.custom.audience\"=${AUDIENCE}" \
  -s 'config."access.token.claim"=true' \
  -s 'config."id.token.claim"=false' >/dev/null
echo "✅ client に Audience マッパーを付与 (aud=${AUDIENCE})"

# --- 3. 出力 (LiteLLM ホスト側のトークン取得スクリプトが参照する) ---
ISSUER_URI="https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}"
TOKEN_URL="https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
cat > "$OUTFILE" <<EOF
# 生成物 (scripts/gateway-wif-client.sh)。client secret を含むため .gitignore 済み・chmod 600。
KEYCLOAK_ISSUER_URI=${ISSUER_URI}
KEYCLOAK_TOKEN_URL=${TOKEN_URL}
WIF_CLIENT_ID=${CLIENT}
WIF_CLIENT_SECRET=${CLIENT_SECRET}
WIF_AUDIENCE=${AUDIENCE}
EOF
chmod 600 "$OUTFILE"
echo "✅ 出力: ${OUTFILE}"

cat <<EOF

────────────────────────────────────────────────────────────────
✅ WIF 用 Keycloak client '${CLIENT}' を作成

GCP 側でこの値を使う (前回提示した手順の変数と対応):
  ISSUER_URI="${ISSUER_URI}"
  AUDIENCE="${AUDIENCE}"
  KC_CLIENT_ID="${CLIENT}"

  → providers create-oidc の --issuer-uri / --allowed-audiences と
    --attribute-condition="assertion.azp=='${CLIENT}'" に反映してください。

疎通確認 (client_credentials で実際にトークンが取れるか):
  curl -s -d grant_type=client_credentials \\
    -d client_id=${CLIENT} -d client_secret=${CLIENT_SECRET} \\
    ${TOKEN_URL} | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"][:40], "...")'
────────────────────────────────────────────────────────────────
EOF

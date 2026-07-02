#!/usr/bin/env bash
# =============================================================================
# Keycloak realm 初期化 (一度だけ実行)。
#   - realm ${KEYCLOAK_REALM} を作成
#   - EntraID (Azure AD) を OIDC IdP としてブローカー登録
#
#   前提: Keycloak が起動していること:
#           docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml up -d
#         .env に KEYCLOAK_* / ENTRA_* / GATEWAY_DOMAIN / KEYCLOAK_REALM が設定済み。
#
#   使い方: bash scripts/gateway-keycloak-init.sh
#
#   ※ グループ / client / EntraID→グループ対応は「チーム追加」で作る:
#       bash scripts/gateway-add.sh teamA 8081 [subdomain] [approle] [claim]
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "❌ .env がありません。'make bootstrap'"; exit 1; }
set -a; . ./.env; set +a

: "${GATEWAY_DOMAIN:?GATEWAY_DOMAIN を .env に設定}"
: "${KEYCLOAK_REALM:?KEYCLOAK_REALM を .env に設定}"
: "${KEYCLOAK_ADMIN:?}"; : "${KEYCLOAK_ADMIN_PASSWORD:?}"
: "${ENTRA_TENANT_ID:?}"; : "${ENTRA_CLIENT_ID:?}"; : "${ENTRA_CLIENT_SECRET:?}"

GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

echo "⏳ Keycloak の起動を待機 (最大 ~120s) ..."
for i in $(seq 1 40); do
  if KC config credentials --server http://localhost:8080 \
        --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; then
    echo "✅ Keycloak 管理APIに接続"; break
  fi
  [[ $i -eq 40 ]] && { echo "❌ Keycloak に接続できませんでした ('$GW logs keycloak' を確認)"; exit 1; }
  sleep 3
done

# --- realm ---
if KC get "realms/${KEYCLOAK_REALM}" >/dev/null 2>&1; then
  echo "ℹ realm '${KEYCLOAK_REALM}' は既に存在"
else
  KC create realms -s realm="${KEYCLOAK_REALM}" -s enabled=true
  echo "✅ realm '${KEYCLOAK_REALM}' を作成"
fi

# --- EntraID (Azure AD) を OIDC ブローカーとして登録 ---
if KC get "identity-provider/instances/entraid" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1; then
  echo "ℹ IdP 'entraid' は既に存在 (更新はスキップ)"
else
  KC create identity-provider/instances -r "${KEYCLOAK_REALM}" \
    -s alias=entraid \
    -s displayName="Microsoft EntraID" \
    -s providerId=oidc \
    -s enabled=true \
    -s trustEmail=true \
    -s "config.clientId=${ENTRA_CLIENT_ID}" \
    -s "config.clientSecret=${ENTRA_CLIENT_SECRET}" \
    -s "config.issuer=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0" \
    -s "config.authorizationUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/authorize" \
    -s "config.tokenUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token" \
    -s "config.jwksUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys" \
    -s "config.userInfoUrl=https://graph.microsoft.com/oidc/userinfo" \
    -s "config.useJwksUrl=true" \
    -s "config.defaultScope=openid profile email" \
    -s "config.clientAuthMethod=client_secret_post" \
    -s "config.syncMode=FORCE"
  echo "✅ IdP 'entraid' を登録"
fi

cat <<EOF

────────────────────────────────────────────────────────────────
✅ Keycloak 初期化完了 (realm=${KEYCLOAK_REALM})

次にやること:
1) EntraID (Azure ポータル) 側のアプリ登録で リダイレクト URI を追加:
     https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}/broker/entraid/endpoint
   さらに トークンにグループ/ロールを載せる設定を行う (推奨: App Roles):
     - アプリ登録 > アプリ ロール で 例) role=aiop-teamA を定義
     - エンタープライズ アプリケーション > ユーザーとグループ で
       EntraID グループ/ユーザーに そのロールを割り当て
     ( → トークンの "roles" クレームに "aiop-teamA" が載る )

2) チーム(=Dify インスタンス)ごとに公開範囲を作成:
     bash scripts/gateway-add.sh teamA 8081 teamA aiop-teamA
     # 引数: <team> <dify-port> [subdomain] [entra_group/approle] [entra_claim=roles]
   第4引数には 上の App ロール名 (または EntraID グループの Object ID) を渡す。
────────────────────────────────────────────────────────────────
EOF

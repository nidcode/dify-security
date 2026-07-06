#!/usr/bin/env bash
# =============================================================================
# チーム(=Dify インスタンス)を1つ「前段」に公開する = A' 構成の1単位を作る。
#
#   やること:
#     1. Keycloak にグループ /aiop-<team> を作成            (認可の受け皿)
#     2. Keycloak に confidential client oauth2-proxy-<team> を作成
#        - redirect: https://<sub>.<domain>/oauth2/callback
#        - client に group-membership マッパーを付与 (groups クレーム=フルパス)
#     3. (任意) EntraID の App ロール/グループ → /aiop-<team> の IdP マッパーを作成
#        → 「誰が teamA か」を Keycloak 側で一元管理 (EntraID 割当を変えるだけ)
#     4. oauth2-proxy サービス定義を gateway/oauth2-proxies.gateway.yaml に追記
#     5. front-nginx の server ブロックを gateway/nginx/templates/team-<sub>.conf.template に生成
#
#   認可の考え方 (A'):
#     - 「誰が入れるか」の 割当 は Keycloak (グループ + EntraID マッパー) で管理 = live 変更可。
#     - 経路上の門番 oauth2-proxy は --allowed-group=/aiop-<team> で存在検査するだけ
#       (この値はインスタンス固有の定数で、組織変更では触らない)。
#
#   使い方:
#     bash scripts/gateway-add.sh <team> <dify-port> [subdomain] [entra_group/approle] [entra_claim=roles]
#     例: bash scripts/gateway-add.sh teamA 8081 teamA aiop-teamA
#
#   前提: Gateway 起動済み + scripts/gateway-keycloak-init.sh 実行済み。.env に GATEWAY_DOMAIN 等。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: gateway-add.sh <name> <port> [subdomain] [entra_group] [entra_claim]}"
PORT="${2:?usage: gateway-add.sh <name> <port> [subdomain] [entra_group] [entra_claim]}"
SUB="${3:-$NAME}"
ENTRA_GROUP="${4:-}"          # App ロール名 or EntraID グループ Object ID (任意)
ENTRA_CLAIM="${5:-roles}"     # roles(App ロール) | groups(セキュリティグループ)

[[ -f .env ]] || { echo "❌ .env がありません"; exit 1; }
set -a; . ./.env; set +a
: "${GATEWAY_DOMAIN:?}"; : "${KEYCLOAK_REALM:?}"
: "${KEYCLOAK_ADMIN:?}"; : "${KEYCLOAK_ADMIN_PASSWORD:?}"
: "${OAUTH2_PROXY_COOKIE_SECRET:?}"

FQDN="${SUB}.${GATEWAY_DOMAIN}"
GROUP="aiop-${NAME}"
CLIENT="oauth2-proxy-${NAME}"
AGG="gateway/oauth2-proxies.gateway.yaml"
NCONF="gateway/nginx/templates/team-${SUB}.conf.template"

if [[ -f "$AGG" ]] && grep -q "^  oauth2-proxy-${NAME}:" "$AGG"; then
  echo "❌ oauth2-proxy-${NAME} は既に $AGG に存在します"; exit 1
fi

GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

echo "🔑 Keycloak にログイン ..."
KC config credentials --server http://localhost:8080 \
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# --- 1. グループ /aiop-<team> ---
if KC get groups -r "$KEYCLOAK_REALM" --fields name --format csv 2>/dev/null | grep -qx "\"$GROUP\""; then
  echo "ℹ グループ '$GROUP' は既に存在"
else
  KC create groups -r "$KEYCLOAK_REALM" -s name="$GROUP" >/dev/null
  echo "✅ グループ '$GROUP' を作成"
fi

# --- 2. client oauth2-proxy-<team> ---
CLIENT_SECRET="$(openssl rand -hex 24)"
CID="$(KC create clients -r "$KEYCLOAK_REALM" \
  -s clientId="$CLIENT" \
  -s enabled=true \
  -s protocol=openid-connect \
  -s publicClient=false \
  -s clientAuthenticatorType=client-secret \
  -s standardFlowEnabled=true \
  -s directAccessGrantsEnabled=false \
  -s "redirectUris=[\"https://${FQDN}/oauth2/callback\"]" \
  -s "webOrigins=[\"https://${FQDN}\"]" \
  -i)"
# シークレットは作成後に明示 update で確実に設定 (create -s secret= は版により無視されるため)
KC update "clients/$CID" -r "$KEYCLOAK_REALM" -s "secret=$CLIENT_SECRET" >/dev/null
echo "✅ client '$CLIENT' を作成 (id=$CID)"

# client に group-membership マッパー (Keycloak グループを groups クレームにフルパスで出力)。
# client 直付けなので要求スコープに関係なく常に emit される → oauth2-proxy が --allowed-group で判定可能。
KC create "clients/$CID/protocol-mappers/models" -r "$KEYCLOAK_REALM" \
  -s name=groups -s protocol=openid-connect -s protocolMapper=oidc-group-membership-mapper \
  -s 'config."full.path"=true' \
  -s 'config."claim.name"=groups' \
  -s 'config."id.token.claim"=true' \
  -s 'config."access.token.claim"=true' \
  -s 'config."userinfo.token.claim"=true' >/dev/null
echo "✅ client に groups マッパーを付与"

# --- 3. (任意) EntraID → /aiop-<team> の IdP マッパー ---
if [[ -n "$ENTRA_GROUP" ]]; then
  KC create identity-provider/instances/entraid/mappers -r "$KEYCLOAK_REALM" \
    -s name="${GROUP}-from-entra" \
    -s identityProviderAlias=entraid \
    -s identityProviderMapper=oidc-advanced-group-idp-mapper \
    -s "config.claims=[{\"key\":\"${ENTRA_CLAIM}\",\"value\":\"${ENTRA_GROUP}\"}]" \
    -s "config.group=/${GROUP}" \
    -s 'config.syncMode=FORCE' >/dev/null
  echo "✅ IdP マッパー: EntraID ${ENTRA_CLAIM}='${ENTRA_GROUP}' → /${GROUP}"
else
  echo "ℹ ENTRA_GROUP 未指定 → EntraID 対応マッパーは未作成。"
  echo "   後で Keycloak 管理画面 (Identity Providers > entraid > Mappers) で作成するか、"
  echo "   ユーザーを直接グループ /${GROUP} に入れてもよい。"
fi

# --- 4. oauth2-proxy サービスを集約 compose ファイルに追記 ---
if [[ ! -f "$AGG" ]]; then
  printf '# oauth2-proxy サービス群 (scripts/gateway-add.sh がチームごとに追記)。\n# client secret を含むため .gitignore 済み・chmod 600。\nservices:\n' > "$AGG"
fi
cat >> "$AGG" <<YAML
  # team=${NAME} / sub=${SUB} / port=${PORT}
  oauth2-proxy-${NAME}:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    restart: always
    command:
      - --http-address=0.0.0.0:4180
      - --reverse-proxy=true
      - --provider=oidc
      - --skip-oidc-discovery=true
      - --oidc-issuer-url=https://auth.\${GATEWAY_DOMAIN}/realms/\${KEYCLOAK_REALM}
      - --login-url=https://auth.\${GATEWAY_DOMAIN}/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/auth
      - --redeem-url=http://keycloak:8080/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/token
      - --oidc-jwks-url=http://keycloak:8080/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/certs
      - --profile-url=http://keycloak:8080/realms/\${KEYCLOAK_REALM}/protocol/openid-connect/userinfo
      - --client-id=${CLIENT}
      - --client-secret=${CLIENT_SECRET}
      - --redirect-url=https://${FQDN}/oauth2/callback
      - --cookie-domain=${FQDN}
      - --whitelist-domain=${FQDN}
      - --cookie-secret=\${OAUTH2_PROXY_COOKIE_SECRET}
      - --cookie-secure=true
      - --email-domain=*
      - --scope=openid email profile
      - --allowed-group=/${GROUP}
      - --set-xauthrequest=true
      - --skip-provider-button=true
      - --upstream=static://200
    networks:
      - gateway-internal
YAML
chmod 600 "$AGG"
echo "✅ 追記: $AGG (oauth2-proxy-${NAME})"

# --- 5. front-nginx server ブロック ---
cat > "$NCONF" <<NGINX
# 生成物 (scripts/gateway-add.sh)。sub=${SUB} → Dify インスタンス port=${PORT}
# 共通プロキシヘッダは nginx.conf の http{} で設定済み。\${GATEWAY_DOMAIN} は起動時 envsubst。
server {
    listen 443 ssl;
    http2 on;
    server_name ${SUB}.\${GATEWAY_DOMAIN};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;

    # 変数 + resolver(nginx.conf) で遅延解決 → 起動順・チーム削除に強い。
    set \$oap oauth2-proxy-${NAME};

    # oauth2-proxy (サインイン + 認可判定)
    location /oauth2/ {
        proxy_pass http://\$oap:4180;
    }
    location = /oauth2/auth {
        proxy_pass http://\$oap:4180;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URI      \$request_uri;
        # ログイン後に元の URL へ戻すため oauth2-proxy に返送先を伝える
        proxy_set_header X-Auth-Request-Redirect \$scheme://\$host\$request_uri;
    }

    # --- 機械系エンドポイント: 対話 SSO を課さない (Dify 内の APIキー/署名で認証) ---
    # /v1 /triggers /e /mcp とその配下だけに厳密一致させる。素の前方一致 (location /v1) は
    # /v1x や /mcp-admin 等にも一致して無認証範囲が広がるため正規表現で境界を切る。
    # X-Auth-* は nginx.conf の http{} で空にクリア済み = ここへ注入されても Dify へは渡らない。
    # /files をAPI取得する運用なら files を追加: ^/(v1|triggers|e|mcp|files)(/|\$)
    location ~ ^/(v1|triggers|e|mcp)(/|\$) {
        proxy_pass http://host.docker.internal:${PORT};
    }

    # --- 対話系: EntraID/Keycloak で認可 (/aiop-${NAME} 所属者のみ) ---
    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        # このブロックは proxy_set_header を自前定義するため http{} の共通ヘッダを継承しない
        # (nginx の array 継承は all-or-nothing)。Host/X-Forwarded/WebSocket を明示再掲する。
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-Port  443;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        # 認証済み ID は auth_request の結果のみ信頼 (クライアント送信値を上書き)。
        proxy_set_header X-Auth-User  \$auth_user;
        proxy_set_header X-Auth-Email \$auth_email;
        proxy_pass http://host.docker.internal:${PORT};
    }
}
NGINX
echo "✅ 生成: $NCONF"

cat <<EOF

────────────────────────────────────────────────────────────────
✅ チーム '${NAME}' を追加 (公開: https://${FQDN} → Dify :${PORT})

反映 (oauth2-proxy-${NAME} を起動 + front-nginx をリロード):
  docker compose -p aiop-gateway --env-file .env \\
    -f compose.gateway.yaml -f gateway/oauth2-proxies.gateway.yaml up -d

チェック:
  - DNS: ${FQDN} を gateway ホストへ向ける (auth.${GATEWAY_DOMAIN} も)
  - Dify 側 .env (dify/instances/${NAME}/.env) の URL を公開ドメインに:
      bash scripts/gateway-difyenv.sh ${NAME} ${SUB}
  - 認可: EntraID で ${ENTRA_CLAIM}='${ENTRA_GROUP:-<未設定>}' を対象ユーザー/グループへ割当
          (または Keycloak でユーザーを /${GROUP} に追加)
────────────────────────────────────────────────────────────────
EOF

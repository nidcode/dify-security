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
#   auth.${GATEWAY_DOMAIN} を GCP から到達させたくない場合 (issuer 非公開運用):
#     - GCP 側は providers create-oidc に --jwk-json-path で JWKS を静的登録すれば、
#       GCP は issuer に一切アクセスしない (iss クレームの文字列一致のみで検証)。
#     - トークン取得自体も Keycloak がホストへポート非公開のため外部URLを使わずに
#       完結できる。ただし quay.io/keycloak/keycloak イメージには curl/wget/python3 が
#       無く bash のみなので、`docker compose exec keycloak bash` の中で bash 組込みの
#       /dev/tcp を使い生の HTTP リクエストを送る (実行例は最後の出力を参照)。
#
#   使い方:
#     bash scripts/gateway-wif-client.sh [client-id] [audience]
#     例: bash scripts/gateway-wif-client.sh litellm-vertex-wif \
#           https://gcp-wif.dify-security.internal/litellm-vertex
#
#   前提: Gateway 起動済み (make gateway-up) + scripts/gateway-keycloak-init.sh 実行済み。
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

# compose 構成 / KC() / 起動前チェック は scripts/lib/gateway.sh に一元化。
. scripts/lib/gateway.sh
gateway_require_up

echo "🔑 Keycloak にログイン ..."
kc_login

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
# ISSUER_URI は KC_HOSTNAME (compose.gateway.yaml) 由来で iss クレームに埋め込まれる値。
# GCP 側 --issuer-uri / --attribute-condition の文字列一致にのみ使う識別子であり、
# --jwk-json-path で静的検証する場合はこの URL に GCP が到達できる必要はない。
ISSUER_URI="https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}"
# Keycloak はホストへポート非公開のため、外部URLではなくコンテナ内部の localhost を指す。
# コンテナに curl/wget/python3 が無いため、呼び出し側は
# `docker compose exec keycloak bash` の中で /dev/tcp 経由でこのパスを叩くこと
# (ホストから直接 curl しても localhost:8080 は届かない/別プロセスに当たる)。
TOKEN_URL_INTERNAL="http://localhost:8080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token"
JWKS_URL_INTERNAL="http://localhost:8080/realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs"
# umask をサブシェル内だけ制限し、cat による新規作成時点から 0600 にする
# (作成直後に chmod するだけだと、その間だけ既定umaskの緩いパーミッションで露出する窓ができる)。
(
  umask 077
  cat > "$OUTFILE" <<EOF
# 生成物 (scripts/gateway-wif-client.sh)。client secret を含むため .gitignore 済み・chmod 600。
KEYCLOAK_ISSUER_URI=${ISSUER_URI}
# 以下2つは Keycloak コンテナの内部 localhost 宛パス。curl/wget/python3 が無いイメージなので
#   docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml exec -T keycloak bash
# の中で /dev/tcp 経由 (実行例は本スクリプト実行時の最後の出力を参照) で叩くこと。
KEYCLOAK_TOKEN_URL_INTERNAL=${TOKEN_URL_INTERNAL}
KEYCLOAK_JWKS_URL_INTERNAL=${JWKS_URL_INTERNAL}
WIF_CLIENT_ID=${CLIENT}
WIF_CLIENT_SECRET=${CLIENT_SECRET}
WIF_AUDIENCE=${AUDIENCE}
EOF
)
chmod 600 "$OUTFILE"   # umask漏れ・想定外の作成経路に備えた保険 (通常は既に0600のはず)
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

  issuer を GCP から到達させたくない場合は --jwk-json-path で JWKS を静的登録:
  (コンテナに curl が無いため bash の /dev/tcp で生の HTTP を送る。gateway/wif は無ければ作る)
    mkdir -p gateway/wif
    ${GW} exec -T keycloak bash -c '
    exec 3<>/dev/tcp/localhost/8080
    printf "GET /realms/${KEYCLOAK_REALM}/protocol/openid-connect/certs HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
    cat <&3
    ' | tr -d '\r' | awk 'BEGIN{body=0} /^$/ && body==0 {body=1; next} body{print}' \
      > gateway/wif/${CLIENT}-jwks.json
    → gcloud ... providers create-oidc ... --jwk-json-path=gateway/wif/${CLIENT}-jwks.json
  ※ Keycloak の署名鍵ローテーション時は再取得・再登録が必要 (自動フェッチ方式ならこの手間は不要)。

疎通確認 (client_credentials で実際にトークンが取れるか):
  bash scripts/gateway-wif-refresh-token.sh ${CLIENT}
  (${OUTFILE} からシークレットを読んで叩くだけなので、この画面にも他のログにも
   client secret 自体は出力されない。成功すると gateway/wif/keycloak-token.jwt が更新される)
────────────────────────────────────────────────────────────────
EOF

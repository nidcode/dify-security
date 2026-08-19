#!/usr/bin/env bash
# =============================================================================
# Keycloak realm 初期化 (一度だけ実行)。
#   - realm ${KEYCLOAK_REALM} を作成
#   - EntraID (Azure AD) を OIDC IdP としてブローカー登録
#
#   前提: Gateway (Keycloak) が起動していること: make gateway-up
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

# compose 構成 / KC() / 起動前チェック / モード判定 は scripts/lib/gateway.sh に一元化。
. scripts/lib/gateway.sh
gateway_mode_init

# 素通しでは Keycloak を使わない。起動前チェックより先に判定する
# (require_up を先にすると、未起動時に「front-nginx を起動しろ」と要求した挙句
#  起動後に「初期化は不要」と告げる誤案内になる)。
if gateway_is_passthrough; then
  echo "ℹ GATEWAY_AUTH=none (素通し) では Keycloak を使いません。初期化は不要です。"
  echo "   認証を有効にするには .env の GATEWAY_AUTH=sso に戻してから再実行してください。"
  exit 0
fi

gateway_require_up

# --- EntraID 設定の有無を判定 ---------------------------------------------
# gen-env.sh は ENTRA_* に雛形値を書くため「空かどうか」では判定できない。
# 雛形のまま (xxxxxxxx-... / CHANGE-ME-...) なら未設定として扱い、IdP 登録を飛ばす。
# 未設定でも realm / グループ / client は作れるので、Keycloak ローカルユーザーで
# ログインする構成としてゲートウェイは動作する。
entra_configured() {
  local v
  for v in "${ENTRA_TENANT_ID:-}" "${ENTRA_CLIENT_ID:-}" "${ENTRA_CLIENT_SECRET:-}"; do
    [[ -n "$v" ]] || return 1
    [[ "$v" == CHANGE-ME* ]] && return 1
    [[ "$v" =~ ^x+-x+-x+-x+-x+$ ]] && return 1
  done
  return 0
}

# 初回は DB マイグレーション等で時間がかかるため長めに待つ (40回 x 3s = 最大 ~120s)。
kc_login 40 3

# --- realm ---
if KC get "realms/${KEYCLOAK_REALM}" >/dev/null 2>&1; then
  echo "ℹ realm '${KEYCLOAK_REALM}' は既に存在"
else
  KC create realms -s realm="${KEYCLOAK_REALM}" -s enabled=true
  echo "✅ realm '${KEYCLOAK_REALM}' を作成"
fi

# --- EntraID (Azure AD) を OIDC ブローカーとして登録 ---
# 「ENTRA_* が設定済みか」と「IdP が登録済みか」は独立なので4象限で扱う。
# 特に .env の再生成等で ENTRA_* が雛形値に戻っても、登録済み IdP は残っている
# (= EntraID ログインは以前の設定のまま有効) ため、ローカルユーザー運用と混同しない。
ENTRA_IDP_EXISTS=0
KC get "identity-provider/instances/entraid" -r "${KEYCLOAK_REALM}" >/dev/null 2>&1 && ENTRA_IDP_EXISTS=1

if ! entra_configured && [[ "$ENTRA_IDP_EXISTS" == 1 ]]; then
  echo "⚠ ENTRA_* は雛形値ですが、realm には IdP 'entraid' が登録済みのまま残っています。"
  echo "   EntraID ログインは以前に登録した設定 (client secret 等) のまま有効です。"
  echo "   - 設定を更新する場合: .env の ENTRA_* を実値に戻し、先に IdP を削除してから再実行:"
  echo "       KC delete identity-provider/instances/entraid -r ${KEYCLOAK_REALM}"
  echo "   - EntraID をやめる場合も上記コマンドで IdP を削除してください。"
elif ! entra_configured; then
  echo "⏭ ENTRA_* が未設定 (雛形値) のため IdP 'entraid' の登録をスキップしました。"
  echo "   → Keycloak ローカルユーザーでログインする構成として動作します。"
  echo "     ユーザー作成: Keycloak 管理UI (https://auth.${GATEWAY_DOMAIN}) > Users > Add user"
  echo "     作成後 Groups タブで /<接頭辞>-<team> に Join させると当該インスタンスに入れます。"
  echo "   → EntraID を使う場合は .env の ENTRA_* を実値にして本スクリプトを再実行してください。"
elif [[ "$ENTRA_IDP_EXISTS" == 1 ]]; then
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

if entra_configured || [[ "$ENTRA_IDP_EXISTS" == 1 ]]; then
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
else
cat <<EOF

────────────────────────────────────────────────────────────────
✅ Keycloak 初期化完了 (realm=${KEYCLOAK_REALM}) / EntraID なし

EntraID が未設定のため、ログインは Keycloak のローカルユーザーで行います。

次にやること:
1) チーム(=Dify インスタンス)ごとに公開範囲を作成:
     bash scripts/gateway-add.sh teamA 8081
2) 利用者を作る (Keycloak 管理UI: https://auth.${GATEWAY_DOMAIN}):
     Users > Add user → Credentials タブでパスワード設定
     → Groups タブで /${KEYCLOAK_GROUP_PREFIX:-aiop}-teamA に Join
   これで https://teamA.${GATEWAY_DOMAIN} に入れます。

後から EntraID に移行する場合は .env の ENTRA_* を実値にして本スクリプトを再実行
(realm やグループは作り直さず、IdP 登録だけが追加されます)。
────────────────────────────────────────────────────────────────
EOF
fi

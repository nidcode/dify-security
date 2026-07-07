#!/usr/bin/env bash
# =============================================================================
# 部署(EntraID) → Dify インスタンス(Keycloak グループ /aiop-<team>) の
# 「アクセス許可」を1つ 追加/削除 する。EntraID の licensing 差で2パターンあるが、
# どちらも「EntraID のクレーム値 → /aiop-<team>」を写す IdP マッパー1個に集約される。
#
#   A (Free / P1なし):  セキュリティグループ。claim=groups、値はグループの Object ID(GUID)。
#       前提: Azure アプリ登録 > トークン構成 で "groups" クレームを発行。
#   B (Entra ID P1以上): App ロール。claim=roles(既定)、値は App ロール名。
#       前提: Enterprise App > ユーザーとグループ で 部署グループを App ロールに割当。
#
#   syncMode=FORCE のため、該当ロール/グループを持つ人は「次回ログインで自動的に所属」、
#   割当が外れた人は「次回ログインで自動的に除去」される (人事異動は EntraID 側だけで完結)。
#
# 多対多対応: 同一インスタンスに複数部署を許可する場合、部署ごとにこのコマンドを実行
#             (マッパー名は team+claim+値で一意化)。
#
# 使い方:
#   bash scripts/gateway-grant.sh <team> <entra_value> [claim]           # 追加
#   bash scripts/gateway-grant.sh --remove <team> <entra_value> [claim]  # 削除
#     <team>        インスタンス名 (= グループ /aiop-<team>)
#     <entra_value> App ロール名 (claim=roles) または グループ Object ID (claim=groups)
#     [claim]       roles(既定) | groups
#   例(B/P1):  bash scripts/gateway-grant.sh dify aiop-dify
#   例(A/Free): bash scripts/gateway-grant.sh dify 11111111-2222-3333-4444-555555555555 groups
#
# 前提: Gateway 起動済み + gateway-keycloak-init.sh 実行済み + 対象インスタンスが
#       gateway-add.sh で作成済み (グループ /aiop-<team> が存在)。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

REMOVE=0
if [[ "${1:-}" == "--remove" || "${1:-}" == "-d" ]]; then REMOVE=1; shift; fi
NAME="${1:?usage: gateway-grant.sh [--remove] <team> <entra_value> [claim=roles]}"
VALUE="${2:?usage: gateway-grant.sh [--remove] <team> <entra_value> [claim=roles]}"
CLAIM="${3:-roles}"
[[ "$CLAIM" == "roles" || "$CLAIM" == "groups" ]] || { echo "❌ claim は roles か groups"; exit 1; }

[[ -f .env ]] || { echo "❌ .env がありません"; exit 1; }
set -a; . ./.env; set +a
: "${KEYCLOAK_REALM:?}"; : "${KEYCLOAK_ADMIN:?}"; : "${KEYCLOAK_ADMIN_PASSWORD:?}"

GROUP="aiop-${NAME}"
# マッパー名は team+claim+値で一意 (多対多で複数部署→同一インスタンスを許可するため)。
# Keycloak マッパー名に使えない文字は _ に置換。
SAFE_VALUE="$(printf '%s' "$VALUE" | tr -c 'A-Za-z0-9._-' '_')"
MAPPER="${GROUP}-from-${CLAIM}-${SAFE_VALUE}"

GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
KC config credentials --server http://localhost:8080 \
  --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

# 対象グループ (=インスタンス) の存在確認
if ! KC get groups -r "$KEYCLOAK_REALM" --fields name --format csv 2>/dev/null | grep -qx "\"$GROUP\""; then
  echo "❌ グループ /$GROUP がありません。先に: bash scripts/gateway-add.sh $NAME <port>"; exit 1
fi

# 既存マッパー(同名)の id を取得 (csv: \"id\",\"name\")
MROW="$(KC get identity-provider/instances/entraid/mappers -r "$KEYCLOAK_REALM" \
          --fields id,name --format csv 2>/dev/null | grep ",\"${MAPPER}\"$" || true)"
EID="$(printf '%s' "$MROW" | cut -d, -f1 | tr -d '"')"

if [[ "$REMOVE" == "1" ]]; then
  if [[ -z "$EID" ]]; then echo "ℹ マッパー '$MAPPER' は存在しません (削除不要)"; exit 0; fi
  KC delete "identity-provider/instances/entraid/mappers/$EID" -r "$KEYCLOAK_REALM"
  echo "✅ 剥奪: ${CLAIM}='${VALUE}' → /${GROUP} のマッパーを削除"
  echo "   ※ 既に /${GROUP} に入っているユーザーは次回ログイン(syncMode=FORCE)まで残る。"
  echo "     即時剥奪は Keycloak でグループ /${GROUP} のメンバーを手動削除。"
  exit 0
fi

if [[ -n "$EID" ]]; then echo "ℹ マッパー '$MAPPER' は既に存在 (スキップ)"; exit 0; fi

# oidc-advanced-group-idp-mapper: config.claims は JSON 文字列。-f - で body 投入する
# (kcadm の -s config.claims=[...] は exec 経由でクォートが壊れ "Cannot parse the JSON" になる)。
CLAIMS_ESC="[{\\\"key\\\":\\\"${CLAIM}\\\",\\\"value\\\":\\\"${VALUE}\\\"}]"
BODY=$(cat <<JSON
{
  "name": "${MAPPER}",
  "identityProviderAlias": "entraid",
  "identityProviderMapper": "oidc-advanced-group-idp-mapper",
  "config": {
    "syncMode": "FORCE",
    "group": "/${GROUP}",
    "are.claim.values.regex": "false",
    "claims": "${CLAIMS_ESC}"
  }
}
JSON
)
printf '%s' "$BODY" | KC create identity-provider/instances/entraid/mappers -r "$KEYCLOAK_REALM" -f - >/dev/null
LABEL="$( [[ "$CLAIM" == roles ]] && echo 'App ロール' || echo 'セキュリティグループ' )"
echo "✅ 付与: ${CLAIM}='${VALUE}' → /${GROUP}  (mapper=${MAPPER})"
echo "   EntraID で該当${LABEL}を持つユーザーは次回ログインで自動的に /${GROUP} に所属する。"

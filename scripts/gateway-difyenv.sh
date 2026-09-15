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
# GATEWAY_DOMAIN_SUFFIX (FQDN組み立て用の派生値) は gateway_mode_init が確定させる
# (GATEWAY_DOMAIN が空 = フラットな独立ホスト名構成なら空文字)。
. scripts/lib/gateway.sh
gateway_mode_init

FQDN="${SUB}${GATEWAY_DOMAIN_SUFFIX}"
URL="https://${FQDN}"

# CONSOLE_API_URL/APP_API_URL を安全に公開URLへ倒せるかは、対象インスタンスが
# 作成された時点の docker-compose.yaml (dify-new.sh がテンプレを複製した実体。
# dify/docker/ を後から make bootstrap で更新しても既存インスタンスには
# 反映されない) が SERVER_CONSOLE_API_URL によるSSR用内部URL分離
# (Dify 1.15.0+) を持つかどうかで変わる。無ければ CONSOLE_API_URL=$URL は
# webのSSR fetchを壊す (実機で確認済み)。
COMPOSE_FILE="dify/instances/${NAME}/docker-compose.yaml"
if grep -q '\${SERVER_CONSOLE_API_URL' "$COMPOSE_FILE" 2>/dev/null; then
  SUPPORTS_SERVER_CONSOLE_API_URL=1
else
  SUPPORTS_SERVER_CONSOLE_API_URL=0
fi

set_env() {  # 既存行は置換、無ければ追記
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV"; then sed -i "s|^${key}=.*|${key}=${val}|" "$ENV";
  else printf '%s=%s\n' "$key" "$val" >> "$ENV"; fi
}

set_env NGINX_SERVER_NAME "$FQDN"
# CONSOLE_WEB_URL/APP_WEB_URL/FILES_URL/SERVICE_API_URL/TRIGGER_URL/
# ENDPOINT_URL_TEMPLATE/NEXT_PUBLIC_SOCKET_URL は表示・署名・外部コールバック
# 生成用のみ (このプロセス自身がその値へ通信するわけではない) なので $URL を
# 書いて問題ない。既定値が http(s)://localhost 系のまま放置すると、
# Webhook/トリガーURLの表示や、コラボレーション用WebSocket接続が
# 実運用で壊れる (自分自身のlocalhostに繋ぎに行ってしまう) ため明示する。
set_env CONSOLE_WEB_URL   "$URL"
set_env SERVICE_API_URL   "$URL"
set_env APP_WEB_URL       "$URL"
set_env FILES_URL         "$URL"
set_env TRIGGER_URL       "$URL"
set_env ENDPOINT_URL_TEMPLATE "${URL}/e/{hook_id}"
set_env NEXT_PUBLIC_SOCKET_URL "wss://${FQDN}"
if [[ "$SUPPORTS_SERVER_CONSOLE_API_URL" == "1" ]]; then
  # SERVER_CONSOLE_API_URL 対応済み (Dify 1.15.0+) インスタンス: SSRは
  # SERVER_CONSOLE_API_URL(内部)を使うので、CONSOLE_API_URL/APP_API_URLは
  # 従来通り公開URLのままで良い (Notion連携等の外部コールバックも成立する)。
  set_env CONSOLE_API_URL "$URL"
  set_env APP_API_URL     "$URL"
else
  # 未対応 (Dify 1.14.2以前で作成された既存インスタンス) の場合:
  # CONSOLE_API_URL/APP_API_URLは「外部向け絶対URL」と「webのSSRが自分自身に
  # 対して行うfetch」を兼ねてしまうため、$URL (裸ホスト名、ポート省略=443/https
  # 前提) を明示すると実際の到達経路と食い違い、"/install" 等がSSRのfetch失敗で
  # 固まる不具合を実機で確認済み (2026-09)。空にすればブラウザ側のfetchは
  # 相対パス化されアクセスしたオリジンに自動追従するので単一オリジン構成では
  # 実害なし (Notion連携等、外部への絶対URLが要る機能のみ動かない)。
  # 過去のバージョンのこのスクリプトで既に $URL を書き込み済みの既存インスタンス
  # にも再実行で収束するよう、明示的に空へ戻す (未設定のまま放置ではなく上書き)。
  set_env CONSOLE_API_URL ""
  set_env APP_API_URL ""
fi
# 1.14.2以前では単に無視される無害な設定。1.15.0+へアップグレードした際に
# 自動的に正しい構成へ寄っていくよう、対応可否によらず常に設定しておく。
set_env SERVER_CONSOLE_API_URL "http://api:5001"
# TLS は front-nginx で終端。インスタンス側 nginx は http のまま。
set_env NGINX_HTTPS_ENABLED "false"

echo "✅ $ENV を $URL 用に更新 (NGINX_SERVER_NAME / CONSOLE_WEB_URL / SERVICE_API_URL / APP_WEB_URL / FILES_URL / TRIGGER_URL / ENDPOINT_URL_TEMPLATE / NEXT_PUBLIC_SOCKET_URL)"
if [[ "$SUPPORTS_SERVER_CONSOLE_API_URL" == "1" ]]; then
  echo "   CONSOLE_API_URL / APP_API_URL も $URL に設定 (SERVER_CONSOLE_API_URL 対応版のため)"
else
  echo "   CONSOLE_API_URL / APP_API_URL は意図的に未設定のままにしています"
  echo "   (SERVER_CONSOLE_API_URL 未対応バージョンのため。Notion連携等、Dify自身が"
  echo "    外部へ渡す絶対URLが要る機能を使うには Dify 1.15.0+ へのアップグレードが必要)。"
fi
echo "   反映: cd dify/instances/${NAME} && docker compose up -d"

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
# CONSOLE_API_URL/APP_API_URL は意図的に空のままにする (Dify側の実装):
#   - ブラウザからのfetchはこれが空だと相対パス化され、アクセスしたオリジンに
#     自動で追従するので単一オリジン構成では実害なし。
#   - 一方 web(Next.js SSR) はこの値を「自分自身が外向きに」HTTPで叩く用途にも
#     使う実装がある。稼働環境で $URL (裸ホスト名、ポート省略=443/https前提) を
#     明示すると、実際の到達経路(ポート/TLS終端の有無)と食い違い、
#     "/install" 等がSSRのfetch失敗で固まる不具合を確認済み (2026-09)。
#   代わりに SERVER_CONSOLE_API_URL でSSR用の内部到達先を明示する
#   (対応していない旧バージョンでは単に無視される無害な設定)。
#   過去のバージョンのこのスクリプトで既に $URL を書き込み済みの既存インスタンスにも
#   再実行で収束するよう、明示的に空へ戻す (未設定のまま放置ではなく上書き)。
set_env CONSOLE_API_URL ""
set_env APP_API_URL ""
set_env SERVER_CONSOLE_API_URL "http://api:5001"
# TLS は front-nginx で終端。インスタンス側 nginx は http のまま。
set_env NGINX_HTTPS_ENABLED "false"

echo "✅ $ENV を $URL 用に更新 (NGINX_SERVER_NAME / CONSOLE_WEB_URL / SERVICE_API_URL / APP_WEB_URL / FILES_URL / TRIGGER_URL / ENDPOINT_URL_TEMPLATE / NEXT_PUBLIC_SOCKET_URL)"
echo "   CONSOLE_API_URL / APP_API_URL は意図的に未設定のままにしています"
echo "   (Notion連携等、Dify自身が外部へ渡す絶対URLが要る機能を使うなら別途検討要)。"
echo "   反映: cd dify/instances/${NAME} && docker compose up -d"

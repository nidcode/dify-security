#!/usr/bin/env bash
# =============================================================================
# Gateway スタックへの docker compose 薄いラッパ。
#   bash scripts/gateway-compose.sh up -d | down | ps | logs -f | pull ...
#
#   compose プロジェクト名 (aiop-gateway) と compose ファイル構成は
#   scripts/lib/gateway.sh に一元化してあり、ここはそれを呼ぶだけ (DRY)。
#   oauth2-proxy 群 (gateway/oauth2-proxies.gateway.yaml) は存在すれば自動で重なる。
#
#   Makefile の gateway-up / gateway-down / gateway-ps / gateway-logs の実体。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

. scripts/lib/gateway.sh

[[ -f .env ]] || { echo "❌ .env がありません。'make bootstrap' を実行してください"; exit 1; }
[[ $# -gt 0 ]] || { echo "usage: bash scripts/gateway-compose.sh <docker compose の引数...>"; exit 1; }

# 動作モード (GATEWAY_AUTH / GATEWAY_TLS) は .env に持つので読み込む。
set -a; . ./.env; set +a
gateway_mode_init

if [[ "$1" == "up" ]]; then
  # front-nginx がクラッシュループする典型原因 (証明書欠落) を先に知らせる。
  gateway_warn_missing_certs
  # 素通しモードは server ブロックが生成物なので、起動前に土台を書き出す。
  if gateway_is_passthrough; then
    bash scripts/gateway-render.sh
    echo "ℹ 素通しモード (GATEWAY_AUTH=none): Keycloak / oauth2-proxy は起動しません。"
  fi
fi

# down は先に残骸を撤去する (SSO→素通し切替で残った keycloak 等がネットワークに
# 繋がったままだと、down の network rm が active endpoints で失敗するため)。
if [[ "$1" == "down" ]]; then
  gateway_stop_stale_auth
fi

gw_compose "$@"

if [[ "$1" == "up" ]]; then
  # SSO→素通し切替で残った認証系コンテナ (compose の管理対象外) を撤去する。
  gateway_stop_stale_auth
  # 既に動いている front-nginx にテンプレート追加が反映されていなければ再起動する
  # (nginx イメージの envsubst は起動時のみ = up -d だけでは新しい vhost が出てこない)。
  gateway_reload_nginx_if_stale
  # 起動後の次手順の案内。モード判定は lib に一元化してあるのでここで分岐する。
  if ! gateway_is_passthrough; then
    echo "✅ Gateway 起動。初回は 'bash scripts/gateway-keycloak-init.sh' を実行"
  fi
fi

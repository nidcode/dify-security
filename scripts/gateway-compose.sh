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

# up の時だけ、front-nginx がクラッシュループする典型原因 (証明書欠落) を先に知らせる。
[[ "$1" == "up" ]] && gateway_warn_missing_certs

gw_compose "$@"

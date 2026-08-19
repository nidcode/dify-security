#!/usr/bin/env bash
# =============================================================================
# 素通しモード (GATEWAY_AUTH=none) の front-nginx 土台 server ブロックを書き出す。
#
#   出力先: gateway/nginx/passthrough/ (生成物・.gitignore 済み)
#     00-forwarded.conf.template    X-Forwarded-Proto/Port の決め方 (TLS モード依存)
#     00-default-deny.conf.template server_name 不一致を 444 で拒否
#     00-redirect.conf.template     http→https 恒久リダイレクト (自前終端のときだけ)
#   チーム別の vhost (team-<sub>.conf.template) は scripts/gateway-add.sh が同じ場所に生成する。
#
#   make gateway-up (scripts/gateway-compose.sh) が起動前に自動実行するので、
#   通常は直接叩かなくてよい。.env の GATEWAY_TLS を変えた後に手で流してもよい。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "❌ .env がありません。'make bootstrap' を実行してください"; exit 1; }
set -a; . ./.env; set +a

. scripts/lib/gateway.sh
gateway_mode_init

gateway_is_passthrough || {
  echo "ℹ GATEWAY_AUTH=${GATEWAY_AUTH} (SSO) では土台テンプレートはリポジトリ管理のため生成不要"; exit 0; }

DIR="$(gateway_templates_dir)"
mkdir -p "$DIR"

# --- X-Forwarded-Proto / Port -------------------------------------------------
# nginx.conf の http{} は $fwd_proto / $fwd_port を参照する。どう決めるかはここで切り替える。
if [[ "$GATEWAY_TLS" == "terminate" ]]; then
  cat > "$DIR/00-forwarded.conf.template" <<'NGINX'
# 生成物 (scripts/gateway-render.sh) / GATEWAY_TLS=terminate
# front-nginx 自身が最外エッジで TLS 終端する = クライアント送信の X-Forwarded-* は
# 信頼せず https/443 に固定する (詐称による Dify 側の絶対URL・secure cookie 汚染を防ぐ)。
map $host $fwd_proto { default https; }
map $host $fwd_port  { default 443; }
NGINX
else
  cat > "$DIR/00-forwarded.conf.template" <<'NGINX'
# 生成物 (scripts/gateway-render.sh) / GATEWAY_TLS=none
# TLS は前段 (別 nginx / ALB / Cloudflare 等) で終端済み。前段が付けた X-Forwarded-* を
# そのまま引き継ぐ。付いていなければ自分の待ち受け (平文 80) をそのまま反映する。
#   ⚠ この構成では front-nginx は最外エッジではない = 前段を信頼している。
#     前段を経由せず直接 80 に到達できる経路が無いこと (閉じた網・SG) が前提。
map $http_x_forwarded_proto $fwd_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
}
map $http_x_forwarded_port $fwd_port {
    default $http_x_forwarded_port;
    ''      $fwd_port_by_proto;
}
# 前段が X-Forwarded-Port を付けない場合の既定値。Proto が https なら 443 と見なす
# ($server_port は平文の待ち受けポートなので、https なのに 80 という不整合を防ぐ)。
map $fwd_proto $fwd_port_by_proto {
    https   443;
    default $server_port;
}
NGINX
fi

# --- 既定拒否 -----------------------------------------------------------------
if [[ "$GATEWAY_TLS" == "terminate" ]]; then
  cat > "$DIR/00-default-deny.conf.template" <<'NGINX'
# 生成物 (scripts/gateway-render.sh) / GATEWAY_TLS=terminate
# server_name にマッチしない Host/SNI が、最初にロードされた vhost へ落ちるのを防ぐ。
# SNI 不一致時はこの default_server の証明書が提示されるため tls.crt/key を指定する。
server {
    listen 443 ssl default_server;
    http2 on;
    server_name _;

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;

    return 444;
}
NGINX
  cat > "$DIR/00-redirect.conf.template" <<'NGINX'
# 生成物 (scripts/gateway-render.sh) / GATEWAY_TLS=terminate
# HTTP(80) は全て HTTPS(443) へ恒久リダイレクト。
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
NGINX
else
  cat > "$DIR/00-default-deny.conf.template" <<'NGINX'
# 生成物 (scripts/gateway-render.sh) / GATEWAY_TLS=none
# TLS は前段で終端済みなので待ち受けは平文 80 のみ。既知の <team>.<domain> 以外は
# 444 (無応答クローズ) で拒否し、未定義 Host が先頭 vhost へ落ちるのを防ぐ。
# https へのリダイレクトはしない (前段が既に https を張っており、ここで 301 すると
# 前段 → front-nginx の平文ホップでループする)。
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
NGINX
  rm -f "$DIR/00-redirect.conf.template"
fi

echo "✅ 素通し用テンプレートを生成: ${DIR}/ (GATEWAY_TLS=${GATEWAY_TLS})"

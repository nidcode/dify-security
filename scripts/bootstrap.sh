#!/usr/bin/env bash
# =============================================================================
# 初期セットアップ:
#   1. docker / compose の確認
#   2. .env の生成 (scripts/gen-env.sh)
#   3. Dify 公式 docker/ ディレクトリの取得 (= インスタンス複製元のテンプレート)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

DIFY_VERSION="${DIFY_VERSION:-1.14.2}"

echo "==> 1/3 docker / compose を確認"
command -v docker >/dev/null 2>&1 || { echo "❌ docker が見つかりません"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "❌ docker compose v2 が必要です"; exit 1; }

echo "==> 2/3 .env を生成"
bash scripts/gen-env.sh

echo "==> 3/3 Dify ${DIFY_VERSION} を取得 (インスタンス複製元のテンプレート)"
if [[ -f dify/docker/docker-compose.yaml ]]; then
  echo "  dify/docker/ は既に存在。再取得するには: rm -rf dify/docker"
else
  if [[ "$DIFY_VERSION" == "main" ]]; then
    url="https://github.com/langgenius/dify/archive/refs/heads/main.tar.gz"; top="dify-main"
  else
    url="https://github.com/langgenius/dify/archive/refs/tags/${DIFY_VERSION}.tar.gz"; top="dify-${DIFY_VERSION}"
  fi
  tmp="$(mktemp -d)"
  echo "  download: $url"
  if ! curl -fsSL "$url" -o "$tmp/dify.tar.gz"; then
    echo "❌ 取得失敗。DIFY_VERSION='${DIFY_VERSION}' のタグが存在するか確認してください。" >&2
    echo "   例) DIFY_VERSION=main make bootstrap" >&2
    rm -rf "$tmp"; exit 1
  fi
  tar -xzf "$tmp/dify.tar.gz" -C "$tmp"
  mkdir -p dify
  cp -R "$tmp/${top}/docker" dify/docker
  rm -rf "$tmp"

  # Dify の .env を作成し SECRET_KEY を生成
  cp dify/docker/.env.example dify/docker/.env
  secret="$(openssl rand -base64 42 | tr -d '\n')"
  esc=${secret//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
  if grep -q '^SECRET_KEY=' dify/docker/.env; then
    sed -i.bak "s|^SECRET_KEY=.*|SECRET_KEY=${esc}|" dify/docker/.env && rm -f dify/docker/.env.bak
  fi
  echo "  Dify を dify/docker/ に配置 (SECRET_KEY 生成済み)"
fi

# override をテンプレート側にも配置しておく (複製時にコピーされる) — 冪等
if [[ -d dify/docker ]]; then
  cp dify/compose.override.yaml dify/docker/docker-compose.override.yaml
  echo "  docker-compose.override.yaml を配置 (host-gateway 経由で LiteLLM 到達)"
  mkdir -p dify/docker/model-egress-guard
  cp -R dify/model-egress-guard/. dify/docker/model-egress-guard/
  echo "  model-egress-guard を配置 (主要モデルプロバイダへの直接到達を既定で遮断)"
fi

echo ""
echo "🎉 bootstrap 完了。"
echo "   次の手順:"
echo "     1) .env の ANTHROPIC_API_KEY を実キーに変更"
echo "     2) make up                                    # LiteLLM を起動"
echo "     3) make dify-new NAME=teamA PORT=8081         # Dify を作成 (公式 docker/ を複製)"
echo "     4) cd dify/instances/teamA && docker compose up -d   # Dify を起動 (素の compose)"
echo "     5) make urls                                  # アクセスURLを表示"

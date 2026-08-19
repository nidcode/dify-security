# =============================================================================
# AIOP — Dify + LiteLLM スタック オーケストレーション
#
#   中央 (1個): LiteLLM (+専用Postgres)   → make で管理
#   Dify      : dify/instances/<name>/ (公式 docker/ の複製) を素の docker compose で操作
#
#   ネットワーク: Dify は共有網に載せず host-gateway (host.docker.internal:4000)
#                 経由で LiteLLM に到達する。→ Dify インスタンス間は相互に到達不可。
# =============================================================================

LITELLM := docker compose -p aiop-litellm --env-file .env -f compose.litellm.yaml

# Dify インスタンス一覧 = dify/instances/<name>/ (表示にのみ使用)
INSTANCES := $(notdir $(wildcard dify/instances/*))

.DEFAULT_GOAL := help
.PHONY: help bootstrap gen-env gen-env-force dify-new up down ps logs urls pull embed-test \
        gateway-up gateway-down gateway-ps gateway-logs

help: ## このヘルプを表示
	@echo "AIOP — Dify + LiteLLM"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Dify の起動/停止は各フォルダで素の docker compose:"
	@echo "  cd dify/instances/<name> && docker compose up -d   /   down   /   logs -f"

# --- セットアップ ---------------------------------------------------------
bootstrap: ## 初期セットアップ (.env生成 / Dify取得)
	@bash scripts/bootstrap.sh

gen-env: ## .env を生成 (既存ならスキップ)
	@bash scripts/gen-env.sh

gen-env-force: ## .env を強制再生成 (シークレットが変わる点に注意)
	@bash scripts/gen-env.sh --force

# --- Dify インスタンス作成 (以後は素の docker compose で操作) --------------
dify-new: ## Dify インスタンスを新規作成 (make dify-new NAME=teamA PORT=8081)
	@test -n "$(NAME)" -a -n "$(PORT)" || { echo "❌ NAME= と PORT= を指定 (例: make dify-new NAME=teamA PORT=8081)"; exit 1; }
	@bash scripts/dify-new.sh $(NAME) $(PORT)

# --- 中央スタック (LiteLLM) -----------------------------------------------
up: ## LiteLLM を起動
	@test -f .env || { echo "❌ .env がありません。'make bootstrap' を実行"; exit 1; }
	$(LITELLM) up -d
	@echo "✅ LiteLLM 起動。Dify は 'cd dify/instances/<name> && docker compose up -d'"

down: ## LiteLLM を停止 (Dify は各フォルダで docker compose down)
	-$(LITELLM) down
	@echo "✅ LiteLLM 停止 (データは保持)。"

ps: ## LiteLLM の状態
	@$(LITELLM) ps

logs: ## LiteLLM のログを追従
	$(LITELLM) logs -f --tail=100

pull: ## LiteLLM のイメージを最新に pull
	-$(LITELLM) pull

# --- Gateway スタック (front-nginx + Keycloak + oauth2-proxy) --------------
# compose プロジェクト名 (aiop-gateway) と compose ファイル構成は
# scripts/lib/gateway.sh に一元化。ここは scripts/gateway-compose.sh 経由で呼ぶだけ。
# oauth2-proxy 群 (gateway/oauth2-proxies.gateway.yaml) は存在すれば自動で重なる。
GATEWAY := bash scripts/gateway-compose.sh

gateway-up: ## Gateway を起動 (nginx + Keycloak + oauth2-proxy)
	@test -f .env || { echo "❌ .env がありません。'make bootstrap' を実行"; exit 1; }
	@$(GATEWAY) up -d
	@grep -qE '^GATEWAY_AUTH=none' .env \
	  || echo "✅ Gateway 起動。初回は 'bash scripts/gateway-keycloak-init.sh' を実行"

gateway-down: ## Gateway を停止 (データは保持)
	-@$(GATEWAY) down
	@echo "✅ Gateway 停止 (Keycloak の DB は保持)。"

gateway-ps: ## Gateway の状態
	@$(GATEWAY) ps

gateway-logs: ## Gateway のログを追従
	@$(GATEWAY) logs -f --tail=100

urls: ## アクセスURL一覧
	@echo "LiteLLM 管理UI : http://localhost:4000/ui   (bind ${LITELLM_HOST:-172.17.0.1} / LAN非公開)"
	@echo "LiteLLM API    : http://localhost:4000/v1"
	@echo "Dify 各インスタンスの接続先 (共通): http://host.docker.internal:4000/v1"
	@echo "Dify インスタンス:"
	@for d in $(INSTANCES); do printf "  - %-12s http://localhost:%s\n" "$$d" "$$(grep -E '^EXPOSE_NGINX_PORT=' dify/instances/$$d/.env | cut -d= -f2)"; done
	@test -n "$(INSTANCES)" || echo "  (なし) 'make dify-new NAME=teamA PORT=8081' で作成"

embed-test: ## gemini-embedding を実呼び出しして次元数を確認 (Vertex/ADC)
	@set -a; . ./.env; set +a; \
	curl -s -X POST http://localhost:4000/v1/embeddings \
	  -H "Authorization: Bearer $$LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
	  -d '{"model":"gemini-embedding","input":"embedding test"}' \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ OK / 次元数:', len(d['data'][0]['embedding'])) if 'data' in d else print('❌', d)"

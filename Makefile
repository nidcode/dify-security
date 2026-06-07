# =============================================================================
# AIOP — Dify + LiteLLM + Langfuse スタック オーケストレーション
#
#   起動順序: 共有ネットワーク → Langfuse → LiteLLM → Dify
# =============================================================================

LANGFUSE := docker compose -p aiop-langfuse --env-file .env -f compose.langfuse.yaml
LITELLM  := docker compose -p aiop-litellm  --env-file .env -f compose.litellm.yaml
DIFY_DIR := dify/docker

.DEFAULT_GOAL := help
.PHONY: help bootstrap gen-env gen-env-force net up up-langfuse up-litellm up-dify \
        down down-dify ps logs logs-dify urls pull embed-test clean

help: ## このヘルプを表示
	@echo "AIOP — Dify + LiteLLM + Langfuse"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "クイックスタート: make bootstrap  →  .envのANTHROPIC_API_KEY設定  →  make up  →  make urls"

# --- セットアップ ---------------------------------------------------------
bootstrap: ## 初期セットアップ (.env生成 / ネットワーク / Dify取得)
	@bash scripts/bootstrap.sh

gen-env: ## .env を生成 (既存ならスキップ)
	@bash scripts/gen-env.sh

gen-env-force: ## .env を強制再生成 (シークレットが変わる点に注意)
	@bash scripts/gen-env.sh --force

net: ## 共有ネットワーク aiop を作成
	@docker network inspect aiop >/dev/null 2>&1 || docker network create aiop

# --- 起動 -----------------------------------------------------------------
up: net up-langfuse up-litellm up-dify ## 全スタックを順に起動
	@echo "✅ 全スタック起動。'make urls' でアクセス先を確認。"

up-langfuse: net ## Langfuse のみ起動
	@test -f .env || { echo "❌ .env がありません。'make bootstrap' を実行"; exit 1; }
	$(LANGFUSE) up -d

up-litellm: net ## LiteLLM のみ起動
	@test -f .env || { echo "❌ .env がありません。'make bootstrap' を実行"; exit 1; }
	$(LITELLM) up -d

up-dify: net ## Dify のみ起動
	@test -f $(DIFY_DIR)/docker-compose.yaml || { echo "❌ Dify 未取得。'make bootstrap' を実行"; exit 1; }
	cd $(DIFY_DIR) && docker compose -p dify up -d

# --- 停止 -----------------------------------------------------------------
down: down-dify ## 全スタックを停止
	-$(LITELLM) down
	-$(LANGFUSE) down
	@echo "✅ 停止しました (データは保持)。"

down-dify:
	@test -f $(DIFY_DIR)/docker-compose.yaml && (cd $(DIFY_DIR) && docker compose -p dify down) || true

# --- 運用 -----------------------------------------------------------------
ps: ## 全コンテナの状態
	@echo "── Langfuse ──"; $(LANGFUSE) ps
	@echo "── LiteLLM ──";  $(LITELLM) ps
	@echo "── Dify ──"; test -f $(DIFY_DIR)/docker-compose.yaml && (cd $(DIFY_DIR) && docker compose -p dify ps) || true

logs: ## Langfuse + LiteLLM のログを追従
	$(LANGFUSE) logs -f --tail=100 & $(LITELLM) logs -f --tail=100 & wait

logs-dify: ## Dify のログを追従
	cd $(DIFY_DIR) && docker compose -p dify logs -f --tail=100

pull: ## 全イメージを最新に pull
	-$(LANGFUSE) pull
	-$(LITELLM) pull
	-cd $(DIFY_DIR) && docker compose -p dify pull

embed-test: ## gemini-embedding を実呼び出しして次元数を確認 (Vertex/ADC)
	@set -a; . ./.env; set +a; \
	curl -s -X POST http://localhost:4000/v1/embeddings \
	  -H "Authorization: Bearer $$LITELLM_MASTER_KEY" -H "Content-Type: application/json" \
	  -d '{"model":"gemini-embedding","input":"embedding test"}' \
	  | python3 -c "import sys,json; d=json.load(sys.stdin); print('✅ OK / 次元数:', len(d['data'][0]['embedding'])) if 'data' in d else print('❌', d)"

urls: ## アクセスURL一覧
	@echo "┌─────────────────────────────────────────────────────────────┐"
	@echo "│ Dify  (エージェント基盤) : http://localhost              (80) │"
	@echo "│ LiteLLM 管理UI           : http://localhost:4000/ui          │"
	@echo "│ LiteLLM API (OpenAI互換) : http://localhost:4000/v1          │"
	@echo "│ Langfuse (監査/ログ)     : http://localhost:3000             │"
	@echo "│ MinIO  S3 API            : http://localhost:9090             │"
	@echo "└─────────────────────────────────────────────────────────────┘"
	@echo "LiteLLM UI / Langfuse のログイン情報は .env を参照。"

clean: ## 【破壊的】全停止 + ボリューム削除 + ネットワーク削除
	@echo "⚠️  全データ(トレース/DB/モデル設定/キー)を削除します。"
	@printf "本当に実行しますか? [y/N] " && read ans && [ "$$ans" = "y" ]
	-cd $(DIFY_DIR) && docker compose -p dify down -v
	-$(LITELLM) down -v
	-$(LANGFUSE) down -v
	-docker network rm aiop
	@echo "✅ クリーンアップ完了。"

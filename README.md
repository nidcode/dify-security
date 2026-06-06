# AIOP — Dify + LiteLLM + Langfuse (エージェント統制・監査・ロギング基盤)

エージェントの **監査 / ロギング / Observability** と、**MCP・エージェントの統制** を
1つの docker compose ベースのスタックで実現する構成です。すべて自己ホストで、
外部 SaaS へのトレース送信はありません。

```
   ┌──────────────┐  OpenAI互換   ┌─────────────────────┐   ┌──────────────┐
   │     Dify     │ ────────────▶ │   LiteLLM Gateway   │──▶│  Anthropic   │
   │ エージェント │  /v1          │  ・仮想キー/予算    │   │  Claude      │
   │  ・MCPツール │               │  ・RPM/モデル制限   │   ├──────────────┤
   │  ・ワークフロ│               │  ・MCPゲートウェイ  │──▶│ ローカルOllama│
   └──────┬───────┘               │  ・ガードレール     │   └──────────────┘
          │                       └──────────┬──────────┘
          │ ネイティブ送信                   │ success/failure callback
          ▼                                  ▼
   ┌─────────────────────────────────────────────────────┐
   │                  Langfuse v3 (自己ホスト)            │
   │  トレース / 監査 / コスト / 評価 / プロンプト管理     │
   │  web + worker + postgres + clickhouse + redis + minio│
   └─────────────────────────────────────────────────────┘
```

| レイヤー | 担当 | 役割 |
|---|---|---|
| **Dify** | エージェント/ワークフロー基盤 | アプリ構築、MCPツール接続、人が触る入口 |
| **LiteLLM** | LLM ゲートウェイ = **統制点** | 全LLM呼び出しを集約し、キー/予算/レート/モデル/MCP の統制とロギングを強制 |
| **Langfuse** | Observability = **監査/ログ基盤** | 全トレース・コスト・評価を蓄積。Dify と LiteLLM の両方からネイティブ受信 |

> **なぜ Langfuse か (W&B Weave との比較):** Weave はトレース基盤が実質 W&B クラウド前提で、
> 完全自己ホストは enterprise 構成となり運用負荷が高い。Langfuse は公式サポートの docker compose で
> 完結し外部送信が無く、かつ **Dify・LiteLLM の双方がネイティブ連携**する。自己ホスト・本番寄り・
> 統制という要件では Langfuse が最適。

---

## 前提

- Docker / Docker Compose v2 (Docker Desktop 推奨)
- 空きポート: `80` (Dify), `4000` (LiteLLM), `3000` (Langfuse), `9090` (MinIO)
- メモリ: 合計で 16GB 以上を推奨 (Dify ~6 + Langfuse ~6 + LiteLLM ~1 サービス群)
- Anthropic API キー (`ANTHROPIC_API_KEY`)
- (任意) ローカル `ollama` が `localhost:11434` で稼働

---

## クイックスタート

```bash
# 1) 初期セットアップ: .env生成 / aiopネットワーク作成 / Dify公式composeを取得
make bootstrap

# 2) .env を編集して ANTHROPIC_API_KEY を実キーに変更
#    (他のシークレットは自動生成済み)

# 3) 全スタック起動 (Langfuse → LiteLLM → Dify の順)
make up

# 4) アクセスURLとログイン情報の場所を確認
make urls
```

初回は各イメージの pull に時間がかかります。`make ps` で全コンテナの health を確認できます。

### アクセス先

| サービス | URL | ログイン |
|---|---|---|
| Dify | http://localhost | 初回アクセス時に管理者を作成 |
| LiteLLM 管理UI | http://localhost:4000/ui | `.env` の `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |
| Langfuse | http://localhost:3000 | `.env` の `LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD` |
| MinIO S3 | http://localhost:9090 | `minio` / `LANGFUSE_MINIO_ROOT_PASSWORD` |

---

## 接続設定 (起動後に一度だけ行うUI操作)

### A. Dify → LiteLLM (モデルをゲートウェイ経由にする)

全エージェントの LLM 呼び出しを統制点 (LiteLLM) に通すための設定です。

1. Dify 右上 → **設定 → モデルプロバイダー**
2. **OpenAI-API-compatible** プラグインをインストール (Marketplace)
3. **モデルを追加** で以下を入力:
   - **Model Name**: `claude-sonnet-4-6` (LiteLLM の `config.yaml` の `model_name` と一致させる)
   - **API Key**: LiteLLM の仮想キー (下記 B で発行) または `LITELLM_MASTER_KEY`
   - **API endpoint URL**: `http://litellm:4000/v1`  ← サービス名で解決 (同一 `aiop` ネットワーク)
   - **Completion mode**: Chat
4. 同様に `claude-opus-4-8` / `claude-haiku-4-5` / `local-llama` を追加可能

### B. LiteLLM で統制 (仮想キー・予算・モデル制限・MCP)

統制は LiteLLM 側で「キー」に対して設定します。管理UI (`/ui`) でも、API でも可能。

```bash
# 例: あるチーム用の仮想キーを発行 — モデルを2つに限定 / 月$10予算 / 60 RPM /
#     特定 MCP サーバ・ツールのみ許可
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
        "models": ["claude-sonnet-4-6", "local-llama"],
        "max_budget": 10, "budget_duration": "30d",
        "rpm_limit": 60,
        "object_permission": {
          "mcp_servers": ["example_http_mcp"],
          "mcp_tool_permissions": {"example_http_mcp": ["search", "fetch"]}
        }
      }'
```

発行されたキーを Dify のモデルプロバイダの **API Key** に設定すれば、そのアプリは
「許可モデルのみ・予算/レート上限付き・許可MCPのみ」という統制下で動きます。

### C. MCP 統制 (LiteLLM MCP ゲートウェイ)

`litellm/config.yaml` の `mcp_servers:` に MCP サーバを登録すると、LiteLLM が
単一エンドポイント `http://localhost:4000/mcp` として束ね、**キー単位でどのサーバ・
どのツールに到達できるか** を `object_permission` で制御します。

- MCP クライアント接続: `http://localhost:4000/mcp` に `Authorization: Bearer <仮想キー>`
- 接続を特定サーバに絞る: ヘッダ `x-mcp-servers: <alias or access-group>`
- 権限は キー / チーム / 組織 で交差 (最も厳しい設定が勝つ)

> `config.yaml` の `example_http_mcp` は雛形です。実際の MCP サーバ URL / 認証に置き換えてください。

### D. Dify → Langfuse (アプリのトレース送信)

各 Dify アプリ単位で監査ログを Langfuse に送ります。

1. 対象アプリを開く → 左メニュー **監視 (Monitoring)** → **Tracing**
2. プロバイダに **Langfuse** を選択 → **設定**
3. 認証情報を入力:
   - **Public Key**: `.env` の `LANGFUSE_INIT_PROJECT_PUBLIC_KEY`
   - **Secret Key**: `.env` の `LANGFUSE_INIT_PROJECT_SECRET_KEY`
   - **Host**: `http://langfuse-web:3000`
4. 状態が「started」になれば、以後アプリの実行が Langfuse に記録される

> LiteLLM 経由の呼び出しは **自動的に** Langfuse へ送信済みです (config の success/failure_callback)。
> Dify のトレース設定は「アプリ/ワークフロー単位の文脈」も記録したい場合に追加します。

---

## 監査・ロギングの確認

- **Langfuse** (http://localhost:3000): トレース / セッション / ユーザー / コスト / レイテンシ /
  プロンプト管理 / 評価。LiteLLM 経由の全呼び出しと、Dify アプリの実行が集約される。
- **LiteLLM 管理UI** (http://localhost:4000/ui): キー別のスペンド、レート、モデル使用状況、
  ガードレール、MCP 権限の管理。

---

## 本番ハードニング チェックリスト

このスタックは本番寄りのデフォルトを採用していますが、本番投入前に以下を確認してください。

- [ ] **TLS / リバースプロキシ**: Dify nginx・LiteLLM・Langfuse を nginx/Caddy/Traefik の背後に置き
      HTTPS 終端する。`.env` の `LANGFUSE_WEB_URL` を公開 https URL に。Dify の `CONSOLE_API_URL`
      等 (`dify/docker/.env`) も公開URLに設定。
- [ ] **シークレット管理**: `.env` は自動生成済み。本番では Secrets Manager / Vault 等へ移行。
- [ ] **内部ポート非公開**: 本構成では Langfuse/LiteLLM の DB・ClickHouse・Redis はポート未公開。
      ホスト公開は web(3000)/litellm(4000)/dify(80)/minio(9090) のみ。最小限に保つ。
- [ ] **MinIO presigned URL**: マルチモーダル添付を使う場合、`LANGFUSE_MINIO_PUBLIC_URL` を
      ブラウザから到達可能な公開URLに設定 (デフォルトは localhost:9090)。
- [ ] **イメージのピン留め**: 再現性のため `minio/minio`・`clickhouse/clickhouse-server` 等を
      固定タグ/ダイジェストに。Dify は `DIFY_VERSION` で固定 (デフォルト 1.14.2)。
- [ ] **サインアップ無効化**: Langfuse は `AUTH_DISABLE_SIGNUP=true` 済み。Dify も初回管理者作成後は
      `dify/docker/.env` でメンバー招待制に。
- [ ] **リソース割当**: ClickHouse はメモリを要求 (推奨 ≥16GB)。本番は専用ホスト/マネージドへ。
- [ ] **ガードレール**: 必要に応じて `litellm/config.yaml` の `guardrails:` (PIIマスク等) を有効化。
- [ ] **バックアップ**: docker volume (`*-pgdata`, `*-clickhouse-data`, `*-minio-data`) を定期バックアップ。

---

## よく使うコマンド

```bash
make up            # 全スタック起動
make down          # 全停止 (データ保持)
make ps            # 状態確認
make logs          # Langfuse + LiteLLM ログ追従
make logs-dify     # Dify ログ追従
make pull          # 全イメージ更新
make urls          # アクセスURL
make clean         # 【破壊的】全削除 (ボリューム/ネットワーク含む)
```

個別起動: `make up-langfuse` / `make up-litellm` / `make up-dify`

---

## トラブルシュート

- **Dify からモデル接続が失敗する**: Dify の egress は SSRF プロキシ (Squid) 経由になる場合がある。
  `http://litellm:4000/v1` への到達が拒否されるなら、`dify/docker` の ssrf_proxy 設定で
  `litellm` を許可するか、`api`/`plugin_daemon` が `aiop` ネットワークに参加しているか確認
  (`docker inspect` で確認可能。override で接続済み)。
- **Langfuse にトレースが出ない**: LiteLLM の `LANGFUSE_HOST=http://langfuse-web:3000` と
  `.env` のキー (pk-lf-/sk-lf-) が Langfuse 初期化キーと一致しているか確認。`make logs` で
  LiteLLM のコールバックエラーを確認。
- **ClickHouse が unhealthy**: メモリ不足の可能性。Docker のメモリ割当を増やす。
- **ポート競合**: `.env` の `LITELLM_PORT` / `LANGFUSE_WEB_PORT` / `LANGFUSE_MINIO_PORT`、
  Dify は `dify/docker/.env` の `EXPOSE_NGINX_PORT` で変更。

---

## ディレクトリ構成

```
aiop/
├── README.md
├── Makefile                  # オーケストレーション
├── .env.example              # 全シークレットの単一ソース (→ .env)
├── compose.langfuse.yaml     # Langfuse v3 スタック
├── compose.litellm.yaml      # LiteLLM ゲートウェイ + Postgres
├── litellm/
│   └── config.yaml           # モデル / Langfuseロギング / MCP / ガードレール
├── dify/
│   ├── compose.override.yaml  # aiopネットワーク接続用 override (テンプレート)
│   └── docker/               # ← bootstrap が公式から取得 (gitignore)
└── scripts/
    ├── bootstrap.sh
    └── gen-env.sh
```

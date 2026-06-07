# AIOP — Dify + LiteLLM + Langfuse (エージェント統制・監査・ロギング基盤)

エージェントの **監査 / ロギング / Observability** と、**MCP・エージェントの統制** を
1つの docker compose ベースのスタックで実現する構成です。すべて自己ホストで、
外部 SaaS へのトレース送信はありません。

```
   ┌──────────────┐ OpenAI互換 ┌─────────────────────┐   ┌────────────────────┐
   │     Dify     │ ─────────▶ │   LiteLLM Gateway   │──▶│ Anthropic Claude   │
   │ エージェント │  /v1       │  ・仮想キー/予算    │──▶│ ローカル Ollama    │
   │  ・MCPツール │            │  ・RPM/モデル制限   │──▶│ Vertex AI (Gemini  │
   │  ・ワークフロ│            │  ・MCPゲートウェイ  │   │  埋め込み / ADC)   │
   └──────┬───────┘            │  ・ガードレール     │   └────────────────────┘
          │                    └──────────┬──────────┘
          │ ネイティブ送信                │ success/failure callback
          ▼                               ▼
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

## 提供モデル一覧 (LiteLLM 経由)

`litellm/config.yaml` の `model_list` で定義。Dify など全クライアントはこの `model_name` で呼ぶ。

| model_name | 実体 (provider/model) | 種別 | 認証 |
|---|---|---|---|
| `claude-opus-4-8` | `anthropic/claude-opus-4-8` | LLM | `ANTHROPIC_API_KEY` |
| `claude-sonnet-4-6` | `anthropic/claude-sonnet-4-6` | LLM | `ANTHROPIC_API_KEY` |
| `claude-haiku-4-5` | `anthropic/claude-haiku-4-5` | LLM | `ANTHROPIC_API_KEY` |
| `local-llama` | `ollama_chat/llama3.1` | LLM (ローカル) | 不要 |
| `gemini-embedding` | `vertex_ai/gemini-embedding-001` | **埋め込み (3072次元)** | **ADC (Vertex AI / APIキー不要)** |

> 埋め込みは Vertex AI + **ADC (Application Default Credentials)** で認証。静的な API キーは使いません
> (詳細は「接続設定 B」)。

---

## 前提

- Docker / Docker Compose v2 (Docker Desktop 推奨)
- 空きポート: `80` (Dify), `4000` (LiteLLM), `3000` (Langfuse), `9090` (MinIO)
- メモリ: 合計で 16GB 以上を推奨 (Dify ~6 + Langfuse ~6 + LiteLLM ~1 サービス群)
- **Anthropic API キー** (`ANTHROPIC_API_KEY`)
- **Gemini 埋め込みを使う場合**: gcloud CLI + ADC + Vertex AI 有効なGCPプロジェクト
  - `gcloud auth application-default login` 済み (`~/.config/gcloud/application_default_credentials.json` が存在)
  - 対象プロジェクトで Vertex AI API (`aiplatform.googleapis.com`) が有効
- (任意) ローカル `ollama` が `localhost:11434` で稼働

---

## クイックスタート

```bash
# 1) 初期セットアップ: .env生成 / aiopネットワーク作成 / Dify公式composeを取得
make bootstrap

# 2) .env を編集
#    - ANTHROPIC_API_KEY を実キーに変更
#    - (Gemini埋め込み使用時) VERTEX_PROJECT を対象GCPプロジェクトIDに変更
#    ※ その他のシークレットは自動生成済み

# 3) 全スタック起動 (Langfuse → LiteLLM → Dify の順)
make up

# 4) アクセスURLとログイン情報の場所を確認
make urls
```

初回は各イメージの pull に時間がかかります。`make ps` で全コンテナの health を確認できます。

### アクセス先

| サービス | URL | ログイン |
|---|---|---|
| Dify | http://localhost | 初回アクセス時に管理者を作成 (`/install`) |
| LiteLLM 管理UI | http://localhost:4000/ui | `.env` の `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |
| Langfuse | http://localhost:3000 | `.env` の `LANGFUSE_INIT_USER_EMAIL` / `LANGFUSE_INIT_USER_PASSWORD` |
| MinIO S3 | http://localhost:9090 | `minio` / `LANGFUSE_MINIO_ROOT_PASSWORD` |

> LiteLLM の **API マスター権限**は UI ログインとは別で `LITELLM_MASTER_KEY` (`.env`)。
> 管理 API (`/key/generate` 等) はこのマスターキーを Bearer に使う。

---

## 接続設定 (起動後に一度だけ行う設定)

### A. Dify → LiteLLM (LLM をゲートウェイ経由にする)

全エージェントの LLM 呼び出しを統制点 (LiteLLM) に通すための設定です。

1. Dify 右上 → **設定 → モデルプロバイダー**
2. **OpenAI-API-compatible** プラグインをインストール (Marketplace)
3. **モデルを追加** で以下を入力 (LLM):

   | フィールド | 値 |
   |---|---|
   | Model Type | **LLM** |
   | Model Name | **`claude-sonnet-4-6`** (`config.yaml` の `model_name` と完全一致) |
   | API Key | LiteLLM の **仮想キー** (下記 C で発行) |
   | API endpoint URL | **`http://litellm:4000/v1`** ← localhost ではなくサービス名 |
   | Completion mode | **Chat** |

4. 同様に `claude-opus-4-8` / `claude-haiku-4-5` / `local-llama` を追加 (Model Name のみ変更)

> **重要**: エンドポイントは必ず `http://litellm:4000/v1`。Dify はコンテナ内から呼ぶため
> `localhost` では届きません(同一 `aiop` ネットワーク上でサービス名解決)。

### B. 埋め込み (Vertex AI Gemini + ADC) ★APIキー不要

埋め込みモデル `gemini-embedding` は **Vertex AI + ADC** で動作します。静的キーを使わず、
ホストの gcloud ADC をコンテナにマウントして認証します。

**仕組み (設定済み):**
- `compose.litellm.yaml`: `~/.config/gcloud` を `/gcloud` に読み取り専用マウントし、
  `GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json` を設定
- `litellm/config.yaml`: `model: vertex_ai/gemini-embedding-001` /
  `vertex_project: os.environ/VERTEX_PROJECT` / `vertex_location: os.environ/VERTEX_LOCATION`
- `.env`: `VERTEX_PROJECT` (例: `jbcc-inolab`) / `VERTEX_LOCATION` (例: `us-central1`)
- LiteLLM コンテナは **root 実行**なので、権限 600 の ADC ファイルを読める

**ホスト側の前提:**
```bash
gcloud auth application-default login                       # ADC 作成 (済みなら不要)
gcloud services enable aiplatform.googleapis.com --project <PROJECT>   # Vertex AI 有効化
```

**動作確認:**
```bash
make embed-test        # gemini-embedding を実呼び出しして次元数を表示
```

**Dify への追加 (Text Embedding):**

| フィールド | 値 |
|---|---|
| Model Type | **Text Embedding** |
| Model Name | **`gemini-embedding`** |
| API Key | LiteLLM の仮想キー |
| API endpoint URL | **`http://litellm:4000/v1`** |

→ ナレッジベース作成時に埋め込みモデルとして選択すると Gemini (Vertex/ADC) でベクトル化されます。

> 次元数は既定 **3072**。軽量化したい場合は `config.yaml` の `gemini-embedding` に
> `dimensions: 1536` を追加して LiteLLM を再作成 (縮小時は正規化推奨)。

### C. LiteLLM で統制 (仮想キー・予算・モデル制限・MCP)

統制は LiteLLM 側で「キー」に対して設定します。管理UI (`/ui`) でも API でも可能。

```bash
# 例: Dify 用キー — 5モデル許可 / 月$50 / 120 RPM
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
        "key_alias": "dify-gateway",
        "models": ["claude-opus-4-8","claude-sonnet-4-6","claude-haiku-4-5","local-llama","gemini-embedding"],
        "max_budget": 50, "budget_duration": "30d",
        "rpm_limit": 120,
        "metadata": {"app": "dify"}
      }'

# 後からモデルを追加 (例: 埋め込みを許可リストに追加)
curl -X POST http://localhost:4000/key/update \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" -H "Content-Type: application/json" \
  -d '{"key":"<仮想キー>","models":[... ,"gemini-embedding"]}'
```

発行したキーを Dify の各モデルプロバイダの **API Key** に設定すれば、そのアプリは
「許可モデルのみ・予算/レート上限付き・許可MCPのみ」という統制下で動きます。
発行済みキーの確認・予算編集・失効は **LiteLLM 管理UI** から可能。

> 仮想キーの実値はシークレットのため本 README には記載しません (LiteLLM UI / 発行レスポンスで確認)。

### D. MCP 統制 (LiteLLM MCP ゲートウェイ)

`litellm/config.yaml` の `mcp_servers:` に MCP サーバを登録すると、LiteLLM が
単一エンドポイント `http://localhost:4000/mcp` として束ね、**キー単位でどのサーバ・
どのツールに到達できるか** を `object_permission` で制御します。

- MCP クライアント接続: `http://localhost:4000/mcp` に `Authorization: Bearer <仮想キー>`
- 接続を特定サーバに絞る: ヘッダ `x-mcp-servers: <alias or access-group>`
- 権限は キー / チーム / 組織 で交差 (最も厳しい設定が勝つ)

> `config.yaml` の `example_http_mcp` は雛形です。実際の MCP サーバ URL / 認証に置き換えてください。

### E. Dify → Langfuse (アプリのトレース送信)

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
      等 (`dify/docker/.env`) も公開URLに設定 (localhost運用時の SSR ノイズも解消する)。
- [ ] **シークレット管理**: `.env` は自動生成済み。本番では Secrets Manager / Vault 等へ移行。
- [ ] **ADC / Vertex**: ローカルは gcloud ユーザー ADC で可。本番は **サービスアカウント鍵**または
      **Workload Identity** を推奨。ADC の quota project と `VERTEX_PROJECT` を揃えたい場合は
      `gcloud auth application-default set-quota-project <PROJECT>` (全ADC利用に影響する全体設定)。
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
make embed-test    # gemini-embedding の動作確認 (Vertex/ADC)
make clean         # 【破壊的】全削除 (ボリューム/ネットワーク含む)
```

個別起動: `make up-langfuse` / `make up-litellm` / `make up-dify`

LiteLLM 設定 (`config.yaml`) を変更したら反映:
```bash
docker compose -p aiop-litellm --env-file .env -f compose.litellm.yaml up -d
```

---

## トラブルシュート

- **Dify が起動直後に "Internal Server Error"**: 起動タイミング問題。web が api/DB の準備前に
  リクエストを受けると一時的に 500 になる。api が healthy になれば解消 (ブラウザをハードリフレッシュ)。
  本構成では override で **web を api の health 完了後に起動**するよう対策済み。
- **web ログに `system-features ... ECONNREFUSED localhost`**: localhost 運用時の Dify 標準の
  **無害な SSR ノイズ** (同じ変数が client/server 兼用のため SSR が localhost にフォールバックするだけ。
  ブラウザ側は相対URLで正常に動作)。本番でドメインを `CONSOLE_API_URL` 等に設定すると消える。
- **Dify からモデル接続が失敗する**: `http://litellm:4000/v1` への到達が拒否されるなら、
  `api`/`plugin_daemon` が `aiop` ネットワークに参加しているか確認 (override で接続済み)。
  Dify の egress が SSRF プロキシ経由になる場合は ssrf_proxy 設定で `litellm` を許可。
- **埋め込み (Vertex/ADC) が失敗する**:
  - `docker exec aiop-litellm-litellm-1 ls -l /gcloud/application_default_credentials.json` で
    ADC がマウントされているか確認
  - `VERTEX_PROJECT` の Vertex AI API が有効か / アカウントに `aiplatform.user` 権限があるか
  - quota project 関連エラーなら `gcloud auth application-default set-quota-project <PROJECT>`
- **Langfuse にトレースが出ない**: LiteLLM の `LANGFUSE_HOST=http://langfuse-web:3000` と
  `.env` のキー (pk-lf-/sk-lf-) が Langfuse 初期化キーと一致しているか確認。`make logs` で
  LiteLLM のコールバックエラーを確認。
- **ClickHouse / langfuse-web が unhealthy**: メモリ不足の可能性。Docker のメモリ割当を増やす。
- **ポート競合**: `.env` の `LITELLM_PORT` / `LANGFUSE_WEB_PORT` / `LANGFUSE_MINIO_PORT`、
  Dify は `dify/docker/.env` の `EXPOSE_NGINX_PORT` で変更。

---

## 主要な環境変数 (.env)

| 変数 | 用途 |
|---|---|
| `ANTHROPIC_API_KEY` | Claude 系モデル |
| `VERTEX_PROJECT` / `VERTEX_LOCATION` | Vertex AI (Gemini埋め込み) の対象プロジェクト/リージョン |
| `OLLAMA_API_BASE` | ローカル Ollama のエンドポイント |
| `LITELLM_MASTER_KEY` | LiteLLM 管理API のマスターキー |
| `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` | LiteLLM 管理UI ログイン |
| `LANGFUSE_INIT_PROJECT_PUBLIC_KEY` / `..._SECRET_KEY` | Langfuse プロジェクトキー (LiteLLM/Dify 共用) |
| `LANGFUSE_INIT_USER_EMAIL` / `..._PASSWORD` | Langfuse ログイン |
| `LANGFUSE_*` (各種) | Langfuse 内部シークレット / DB / MinIO |

> 認証情報は `gen-env.sh` で自動生成。`ANTHROPIC_API_KEY` と `VERTEX_PROJECT` のみ手動設定。
> 埋め込みは ADC のため Google 用の静的キーは `.env` に持ちません。

---

## ディレクトリ構成

```
aiop/
├── README.md
├── Makefile                  # オーケストレーション
├── .env.example              # 全シークレットの単一ソース (→ .env)
├── compose.langfuse.yaml     # Langfuse v3 スタック
├── compose.litellm.yaml      # LiteLLM ゲートウェイ + Postgres (+ ADCマウント)
├── litellm/
│   └── config.yaml           # モデル(LLM/埋め込み) / Langfuseロギング / MCP / ガードレール
├── dify/
│   ├── compose.override.yaml  # aiop接続 + web起動順 override (テンプレート)
│   └── docker/               # ← bootstrap が公式から取得 (gitignore)
├── docs/
│   └── agent-governance.md   # エージェント・ガバナンス設計 (A2A非使用パターン)
└── scripts/
    ├── bootstrap.sh
    └── gen-env.sh
```

> エージェント乱立(agent sprawl)への統制方針・台帳・プラットフォーム別の扱い(Dify/LangGraph/Copilot)は
> [docs/agent-governance.md](docs/agent-governance.md) を参照。

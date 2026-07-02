# AIOP — Dify + LiteLLM (エージェント統制ゲートウェイ / マルチインスタンス)

複数の **Dify** インスタンス（各自が独立した postgres/redis/vector を持つ）を、
**単一の LiteLLM ゲートウェイ**の統制下に置く自己ホスト構成です。全 LLM 呼び出しを
LiteLLM に集約し、**仮想キー / 予算 / レート / モデルアクセス / MCP** を一元的に効かせます。

```
   ┌──────────────┐            ┌─────────────────────┐   ┌────────────────────┐
   │ Dify teamA   │            │   LiteLLM Gateway   │──▶│ Anthropic Claude   │
   │ Dify teamB   │  OpenAI互換 │  ・仮想キー/予算    │──▶│ ローカル Ollama    │
   │ Dify teamC   │ ─────────▶ │  ・RPM/モデル制限   │──▶│ Vertex AI (Gemini  │
   │  (各自独立)   │  /v1       │  ・MCPゲートウェイ  │   │  埋め込み / ADC)   │
   └──────────────┘            └──────────┬──────────┘   └────────────────────┘
     ▲ host.docker.internal:4000          │
     │ (共有 docker 網なし = 相互到達不可) │ 172.17.0.1:4000 (bridge gw / LAN非公開)
```

| レイヤー | 担当 | 役割 |
|---|---|---|
| **Dify** ×N | エージェント/ワークフロー基盤 | アプリ構築、MCPツール接続、人が触る入口。**インスタンスごとに完全独立** |
| **LiteLLM** ×1 | LLM ゲートウェイ = **統制点** | 全LLM呼び出しを集約し、キー/予算/レート/モデル/MCP の統制を強制 |

> **セキュリティ設計の要点**: Dify のアプリ層を共有 docker ネットワークに載せず、
> LiteLLM へは **host-gateway (`host.docker.internal:4000`)** 経由で到達させています。
> これにより **Dify インスタンス間に共有 L3 平面が存在せず**、別テナント環境への越境や
> DNS 名前衝突による取り違えが構造的に発生しません。LiteLLM は docker bridge gateway
> (既定 172.17.0.1) にのみ公開 = ホスト内部からのみ到達でき、LAN には露出しません。

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

- Docker / Docker Compose v2 (Docker Desktop / WSL2 backend 推奨)
- 空きポート: `4000` (LiteLLM)、および Dify インスタンスごとに1つ (例 `8081`, `8082` …)
- メモリ: Dify 1台あたり ~6GB + LiteLLM ~1GB。インスタンス数に応じて確保。
- **Anthropic API キー** (`ANTHROPIC_API_KEY`)
- **Gemini 埋め込みを使う場合**: gcloud CLI + ADC + Vertex AI 有効なGCPプロジェクト
  - `gcloud auth application-default login` 済み (`~/.config/gcloud/application_default_credentials.json` が存在)
  - 対象プロジェクトで Vertex AI API (`aiplatform.googleapis.com`) が有効
- (任意) ローカル `ollama` が `localhost:11434` で稼働

---

## クイックスタート

```bash
# 1) 初期セットアップ: ルート .env を生成 (chmod 600)。
#    Dify 本体 (dify/docker/) はリポジトリに同梱済みなので取得はスキップされる。
#    (未取得の場合のみ公式から取得。= 実質 `make gen-env` と同じ)
make bootstrap

# 2) .env を編集
#    - ANTHROPIC_API_KEY を実キーに変更
#    - (Gemini埋め込み使用時) VERTEX_PROJECT を対象GCPプロジェクトIDに変更
#    ※ その他のシークレットは自動生成済み

# 3) LiteLLM ゲートウェイを起動
make up

# 4) Dify インスタンスを作成 (公式 docker/ を複製、ポートを一意に / 機密は自動再生成)
make dify-new NAME=teamA PORT=8081
make dify-new NAME=teamB PORT=8082

# 5) 各 Dify を起動 — 素の docker compose (公式のまま)
cd dify/instances/teamA && docker compose up -d && cd -
cd dify/instances/teamB && docker compose up -d && cd -

# 6) アクセスURLを確認
make urls
```

初回は各イメージの pull に時間がかかります。仕組みは [Dify マルチインスタンス](#dify-マルチインスタンス) を参照。

### アクセス先

| サービス | URL | ログイン |
|---|---|---|
| Dify (teamA) | http://localhost:8081 | 初回アクセス時に管理者を作成 (`/install`)。ゲートは `INIT_PASSWORD` |
| Dify (teamB) | http://localhost:8082 | 同上 |
| LiteLLM 管理UI | http://localhost:4000/ui | `.env` の `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` |

> Dify のポートは `make dify-new` の `PORT=`（複製先 `.env` の `EXPOSE_NGINX_PORT`）。インスタンスごとに一意にする。
> `INIT_PASSWORD` はインスタンス作成時に自動生成: `grep '^INIT_PASSWORD=' dify/instances/<name>/.env`

> LiteLLM の **API マスター権限**は UI ログインとは別で `LITELLM_MASTER_KEY` (`.env`)。
> 管理 API (`/key/generate` 等) はこのマスターキーを Bearer に使う。

---

## Dify マルチインスタンス

dify+redis+postgres を複数、LiteLLM は1つ。
**1 インスタンス = {dify api/worker/web + redis + postgres + vector 等} 一式**。これを
複数並べ、全インスタンスが**単一の LiteLLM ゲートウェイ**を共有します。

```
              LiteLLM (172.17.0.1:4000 / +litellm-db)  ← 統制を集約 (1個)
                        ▲ host.docker.internal:4000
        ┌───────────────┼───────────────┐   ← 各 Dify はホスト経由で到達
   ┌────┴─────┐   ┌─────┴──────┐   ┌─────┴──────┐
   │ dify-teamA│   │ dify-teamB │   │ dify-teamC │  … N個 (各自 redis+PG+vector)
   │ :8081     │   │ :8082      │   │ :8083      │
   └───────────┘   └────────────┘   └────────────┘
   互いに共有 docker 網を持たない = インスタンス間で相互到達不可
```

### 仕組み — 公式のやり方 + 分離強化

Dify を複数動かす公式的な方法は「**`docker/` フォルダを複製して `.env` を変える**」だけ。
本リポジトリはこれを `make dify-new` で行い、以後は**素の `docker compose`** で操作します。

`make dify-new NAME=teamA PORT=8081` がやること:
1. `dify/docker/` を `dify/instances/teamA/` に複製 (各自の redis/PG/volumes を物理分離)
2. host-gateway override (`docker-compose.override.yaml`) をコピー
3. 複製先 `.env` を書き換え:

| 変数 | 役割 | 備考 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | コンテナ/ネットワーク名を分離 | Docker Compose 標準 (`-p` 不要になる) |
| `EXPOSE_NGINX_PORT` | ホスト公開ポート | Dify 標準 (`PORT=`) |
| `SECRET_KEY` | セッション鍵 | インスタンス固有に**再生成** |
| `INIT_PASSWORD` | 管理者登録ゲート | **再生成** |
| `DB_PASSWORD` / `REDIS_PASSWORD` | データストア認証 | 既知デフォルト(`difyai123456`)を**再生成** |
| `SANDBOX_API_KEY` / `CODE_EXECUTION_API_KEY` | コード実行境界の鍵 | 既知デフォルト(`dify-sandbox`)を**再生成** (両者一致) |
| `PLUGIN_DAEMON_KEY` / `INNER_API_KEY_FOR_PLUGIN` | プラグイン基盤の相互認証 | **再生成** |
| `WEAVIATE_API_KEY` (+ server 側 allowed keys) | 既定ベクタDBの認証 | 既知デフォルト(`WVF5…`)を**再生成** (client/server 一致) |

> `REDIS_PASSWORD` を埋め込む URL (`CELERY_BROKER_URL` 等) も同じ新パスワードに追従します。

> **なぜ全部再生成するか**: 公式 `.env` は既知のデフォルト認証情報を同梱しており、複製しただけだと
> **全インスタンスが同一の既知パスワードを共有**します。1台侵害時の横移動を断つため、`dify-new` が
> 機密を個別再生成し、複製先 `.env` を `chmod 600` にします。
>
> データ分離は「フォルダ複製」で担保 (Dify は `./volumes` への bind mount のため、同一フォルダからの
> 複数起動は衝突する)。`dify/instances/` は生成物として `.gitignore` 済み。

### LiteLLM 接続は「統一」・キーだけ「分離」

- 接続先は全インスタンス共通: Dify 管理画面 > OpenAI-API-compatible の
  **API Base = `http://host.docker.internal:4000/v1`**（どのインスタンスでも同一文字列）。
- **仮想キーはインスタンス別**に発行して分離する (下記 C)。team ごとに月次予算・RPM・許可モデルを
  分けられる。発行は LiteLLM 管理UI (`http://localhost:4000/ui`) が最も簡単。

### インスタンスの追加・運用

作成だけ `make dify-new`、あとは**各フォルダで素の docker compose**（公式のまま）。

```bash
# 作成 (複製 + .env編集 + 機密再生成)
make dify-new NAME=teamC PORT=8083

# 起動 / 停止 / ログ / 状態 — すべて公式 docker compose
cd dify/instances/teamC
docker compose up -d          # → http://localhost:8083
docker compose ps
docker compose logs -f
docker compose down           # 停止 (データ保持)
docker compose down -v        # 破棄 (ボリュームも削除)
cd - && rm -rf dify/instances/teamC   # 複製フォルダごと完全削除
```

`make up` は LiteLLM のみを起動する。Dify は上記のとおり各フォルダで操作する。

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
   | API endpoint URL | **`http://host.docker.internal:4000/v1`** |
   | Completion mode | **Chat** |

4. 同様に `claude-opus-4-8` / `claude-haiku-4-5` / `local-llama` を追加 (Model Name のみ変更)

> **重要**: エンドポイントは `http://host.docker.internal:4000/v1`。Dify はコンテナ内から
> ホスト上の LiteLLM を呼ぶため `localhost` では届きません。override が
> `host.docker.internal → host-gateway(既定 172.17.0.1)` を解決し、LiteLLM もそのIPに
> バインドしているのでこの URL のまま動きます。docker0 のサブネットを変更している場合のみ
> `.env` の `LITELLM_HOST` をそのゲートウェイIPに合わせてください (トラブルシュート参照)。

### B. 埋め込み (Vertex AI Gemini + ADC) ★APIキー不要

埋め込みモデル `gemini-embedding` は **Vertex AI + ADC** で動作します。静的キーを使わず、
ホストの gcloud ADC をコンテナにマウントして認証します。

**仕組み (設定済み):**
- `compose.litellm.yaml`: `~/.config/gcloud` を `/gcloud` に読み取り専用マウントし、
  `GOOGLE_APPLICATION_CREDENTIALS=/gcloud/application_default_credentials.json` を設定
- `litellm/config.yaml`: `model: vertex_ai/gemini-embedding-001` /
  `vertex_project: os.environ/VERTEX_PROJECT` / `vertex_location: os.environ/VERTEX_LOCATION`
- `.env`: `VERTEX_PROJECT` / `VERTEX_LOCATION`

**ホスト側の前提:**
```bash
gcloud auth application-default login                       # ADC 作成 (済みなら不要)
gcloud services enable aiplatform.googleapis.com --project <PROJECT>   # Vertex AI 有効化
```

**動作確認:**
```bash
make embed-test        # gemini-embedding を実呼び出しして次元数を表示
```

**Dify への追加 (Text Embedding):** Model Type=**Text Embedding** / Model Name=**`gemini-embedding`** /
API Key=仮想キー / API endpoint URL=**`http://host.docker.internal:4000/v1`**

> 次元数は既定 **3072**。軽量化したい場合は `config.yaml` の `gemini-embedding` に
> `dimensions: 1536` を追加して LiteLLM を再作成 (縮小時は正規化推奨)。
>
> ⚠️ セキュリティ: 現状は**個人ユーザーの ADC 一式**をマウントしています。本番では
> `aiplatform.user` のみを持つ**専用サービスアカウント**の鍵を1枚だけマウントするか、
> Workload Identity を使ってください (「ハードニング」参照)。

### C. LiteLLM で統制 (仮想キー・予算・モデル制限・MCP)

統制は LiteLLM 側で「キー」に対して設定します。管理UI (`/ui`) でも API でも可能。
**インスタンスごとに別キー**を発行して、予算・レート・モデル可否を分離してください。

```bash
# 例: teamA 用キー — 許可モデル / 月$50 / 120 RPM
curl -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer <LITELLM_MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
        "key_alias": "dify-teamA",
        "models": ["claude-sonnet-4-6","claude-haiku-4-5","gemini-embedding"],
        "max_budget": 50, "budget_duration": "30d",
        "rpm_limit": 120,
        "metadata": {"dify_instance": "teamA"}
      }'
```

発行したキーを Dify の各モデルプロバイダの **API Key** に設定すれば、そのインスタンスは
「許可モデルのみ・予算/レート上限付き・許可MCPのみ」という統制下で動きます。
発行済みキーの確認・予算編集・失効は **LiteLLM 管理UI** から可能。

> 仮想キーの実値はシークレットのため本 README には記載しません (LiteLLM UI / 発行レスポンスで確認)。
> `general_settings.upperbound_key_generate_params` で発行時の上限 (max_budget $100 / 30d) をガード済み。

### D. MCP 統制 (LiteLLM MCP ゲートウェイ)

`litellm/config.yaml` の `mcp_servers:` に MCP サーバを登録すると、LiteLLM が
単一エンドポイント `http://localhost:4000/mcp` として束ね、**キー単位でどのサーバ・
どのツールに到達できるか** を `object_permission` で制御します。

- MCP クライアント接続: `http://localhost:4000/mcp` に `Authorization: Bearer <仮想キー>`
- 接続を特定サーバに絞る: ヘッダ `x-mcp-servers: <alias or access-group>`
- 権限は キー / チーム / 組織 で交差 (最も厳しい設定が勝つ)

> `config.yaml` の `example_http_mcp` は雛形です。実際の MCP サーバ URL / 認証に置き換えてください。

---

## 統制状況の確認

- **LiteLLM 管理UI** (http://localhost:4000/ui): キー別のスペンド、レート、モデル使用状況、
  MCP 権限の管理。どのインスタンス(キー)が何をどれだけ使ったかを一覧できる。

> 外部 Observability (Langfuse 等) は本構成では無効です。必要になったら
> `litellm/config.yaml` の `litellm_settings` に `success_callback` を追加し、対応する
> バックエンドを別 compose で建てて連携してください。

---

## 本番ハードニング チェックリスト

- [ ] **ネットワーク分離 (実装済)**: Dify は共有網を持たず host-gateway 経由で LiteLLM に到達。
      インスタンス間は相互到達不可。LiteLLM は `172.17.0.1:4000` (bridge gateway) のみ公開 = LAN非公開。
- [ ] **インスタンス機密の個別化 (実装済)**: `dify-new` が DB/Redis/Sandbox/Plugin/SECRET/INIT を
      再生成し `.env` を `chmod 600`。既知デフォルト(`difyai123456`/`dify-sandbox`)は残らない。
- [ ] **TLS / リバースプロキシ + EntraID 認証 (実装あり)**: `compose.gateway.yaml` + `gateway/` に
      **front-nginx + Keycloak + oauth2-proxy** の前段を用意 (A' 構成)。EntraID を Keycloak でブローカーし、
      **サブドメイン(=インスタンス)ごとに EntraID グループで公開範囲を制御**する。操作は素の
      `docker compose`。手順は [gateway/README.md](gateway/README.md)
      (`scripts/gateway-difyenv.sh` で Dify の `CONSOLE_API_URL` 等も公開URL化)。
- [ ] **シークレット管理**: `.env` は自動生成 + `chmod 600`。本番では Secrets Manager / Vault へ移行。
- [ ] **ADC / Vertex を最小権限に**: 個人 ADC 全体ではなく、`aiplatform.user` のみの
      **サービスアカウント鍵**または **Workload Identity** を使う。マウントは必要な鍵1枚に限定。
- [ ] **仮想キーでテナント分離**: インスタンスごとに別キー + `models` allowlist + 予算/RPM を設定。
      マスターキー (`LITELLM_MASTER_KEY`) は運用者のみが保持し、Dify には渡さない。
- [ ] **データ at rest**: `dify/instances/<name>/volumes/` はホスト平文。ディレクトリ権限の厳格化・
      ディスク暗号化・バックアップを行う。
- [ ] **リソース制限**: マルチテナント同居のノイジーネイバー対策に、各 compose で `cpus`/`mem` 制限を付与。
- [ ] **イメージのピン留め**: Dify は `DIFY_VERSION` で固定 (デフォルト 1.14.2)。LiteLLM も固定タグ推奨。
- [ ] **ガードレール**: 必要に応じて `litellm/config.yaml` の `guardrails:` (PIIマスク等) を有効化。

---

## よく使うコマンド

```bash
# LiteLLM ゲートウェイ
make up                          # 起動
make down                        # 停止 (データ保持)
make ps                          # 状態確認
make logs                        # ログ追従
make pull                        # イメージ更新
make urls                        # アクセスURL (Dify のポート一覧も表示)
make embed-test                  # gemini-embedding の動作確認 (Vertex/ADC)

# Dify — 作成だけ make、起動/停止は素の docker compose
make dify-new NAME=teamA PORT=8081                     # 作成 (複製 + .env編集 + 機密再生成)
cd dify/instances/teamA && docker compose up -d        # 起動
cd dify/instances/teamA && docker compose down         # 停止
```

LiteLLM 設定 (`config.yaml`) を変更したら反映:
```bash
docker compose -p aiop-litellm --env-file .env -f compose.litellm.yaml up -d
```

---

## トラブルシュート

- **Dify が起動直後に "Internal Server Error"**: 起動タイミング問題。web が api/DB の準備前に
  リクエストを受けると一時的に 500 になる。api が healthy になれば解消 (ブラウザをハードリフレッシュ)。
  本構成では override で **web を api の health 完了後に起動**するよう対策済み。
- **Dify からモデル接続が失敗する (host.docker.internal に届かない)**:
  - まず `docker exec <api container> getent hosts host.docker.internal` で解決先IPを確認
    (ネイティブ Linux docker では通常 `172.17.0.1`)。
  - LiteLLM のバインド先 (`.env` の `LITELLM_HOST`, 既定 `172.17.0.1`) と一致しているか確認。
    docker0 サブネットを変更している場合は
    `docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'` で実際のゲートウェイIPを調べ、
    `LITELLM_HOST` をそれに合わせて `make up` を再実行、Dify 側 API Base も同IPにする。
  - Docker Desktop / WSL2 backend の場合は `LITELLM_HOST=127.0.0.1` でも到達する。
  - LiteLLM 自体の稼働は `curl http://localhost:4000/health/liveliness` で確認。
- **埋め込み (Vertex/ADC) が失敗する**:
  - `docker exec aiop-litellm-litellm-1 ls -l /gcloud/application_default_credentials.json` で
    ADC がマウントされているか確認
  - `VERTEX_PROJECT` の Vertex AI API が有効か / アカウントに `aiplatform.user` 権限があるか
  - quota project 関連エラーなら `gcloud auth application-default set-quota-project <PROJECT>`
- **ポート競合**: `.env` の `LITELLM_PORT`、Dify は複製先 `dify/instances/<name>/.env` の
  `EXPOSE_NGINX_PORT` で変更 (インスタンスごとに一意)。作成時に決めるなら `make dify-new NAME=<name> PORT=<port>`。

---

## 主要な環境変数 (.env)

| 変数 | 用途 |
|---|---|
| `ANTHROPIC_API_KEY` | Claude 系モデル |
| `VERTEX_PROJECT` / `VERTEX_LOCATION` | Vertex AI (Gemini埋め込み) の対象プロジェクト/リージョン |
| `OLLAMA_API_BASE` | ローカル Ollama のエンドポイント |
| `LITELLM_MASTER_KEY` | LiteLLM 管理API のマスターキー |
| `LITELLM_SALT_KEY` | DB 保存のプロバイダキーを暗号化する鍵 |
| `LITELLM_UI_USERNAME` / `LITELLM_UI_PASSWORD` | LiteLLM 管理UI ログイン |
| `LITELLM_DB_PASSWORD` | LiteLLM 用 Postgres パスワード |
| `LITELLM_PORT` / `LITELLM_HOST` | LiteLLM の公開ポート / バインドするホストIF (既定 172.17.0.1 = docker bridge gw) |

> 認証情報は `gen-env.sh` で自動生成。`ANTHROPIC_API_KEY` と `VERTEX_PROJECT` のみ手動設定。
> 埋め込みは ADC のため Google 用の静的キーは `.env` に持ちません。
> Dify 各インスタンスの機密は複製先 `dify/instances/<name>/.env` に個別生成されます。

---

## ディレクトリ構成

```
aiop/
├── README.md
├── Makefile                  # LiteLLM 管理 + dify-new
├── .env.example              # 中央スタックのシークレット雛形 (→ .env, chmod 600)
├── compose.litellm.yaml      # LiteLLM ゲートウェイ + Postgres (172.17.0.1公開 / ADCマウント)
├── compose.gateway.yaml      # 前段: front-nginx + Keycloak + oauth2-proxy (EntraID認証/公開範囲制御)
├── litellm/
│   └── config.yaml           # モデル(LLM/埋め込み) / MCP / ガードレール
├── gateway/                  # 前段の設定 (nginx/certs/instances) + README。詳細は gateway/README.md
├── dify/
│   ├── compose.override.yaml  # host-gateway 接続 + web起動順 override (全インスタンス共通)
│   ├── docker/               # 公式 Dify 一式 = 複製元テンプレ (追跡。ただし .env は除外)
│   └── instances/            # ← make dify-new が作る複製 (各インスタンス, gitignore)
│       ├── teamA/            #     公式 docker/ の複製 + .env (port 8081, 機密個別)
│       └── teamB/            #     公式 docker/ の複製 + .env (port 8082, 機密個別)
├── docs/
│   └── agent-governance.md   # エージェント・ガバナンス設計 (A2A非使用パターン)
└── scripts/
    ├── bootstrap.sh
    ├── gen-env.sh
    └── dify-new.sh           # Dify インスタンスを1つ作る (複製 + .env編集 + 機密再生成)
```

> エージェント乱立(agent sprawl)への統制方針・台帳・プラットフォーム別の扱い(Dify/LangGraph/Copilot)は
> [docs/agent-governance.md](docs/agent-governance.md) を参照。

# GCP Workload Identity Federation (Vertex AI 埋め込み用)

LiteLLM の Vertex AI 埋め込み (`vertex_ai/gemini-embedding-001`) 認証を、個人 ADC 全体マウント
(README 本文 B節) から、**最小権限サービスアカウント + Keycloak を外部OIDC IdPにした
Workload Identity Federation (WIF)** へ移行する手順。README の本番ハードニングチェックリスト
「ADC / Vertex を最小権限に」に対応する。

## 全体設計

LiteLLM ホスト → (client_credentials) → Keycloak → JWTアクセストークン
→ ローカルファイルに保存 → gcloud生成のcredential config → GCP STSでトークン交換
→ 短命GCPトークンでVertex AI呼び出し

- GCPに長命の鍵は置かない。ホストに残る秘密は Keycloak client secret のみ
  (Keycloak側でいつでも失効・ローテーション可能。GCPリソースへの直接アクセス権は持たない)。
- issuer (`https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}`) は
  **JWKS を GCP 側に静的登録することで、GCP から到達可能である必要がなくなる**
  (詳細は下記「issuer 非公開運用」)。

## 前提: Keycloak側 client を作成

```bash
bash scripts/gateway-wif-client.sh litellm-vertex-wif \
  https://gcp-wif.dify-security.internal/litellm-vertex-wif
```

`gateway/wif/litellm-vertex-wif.env` に issuer/audience/client secret が出力される
(chmod 600, .gitignore済み)。以降のGCP側手順の変数はここから取る。

実行後に印字される案内文の通り、Keycloakイメージ (`quay.io/keycloak/keycloak`) には
**curl/wget/python3 が無く bash のみ**なので、JWKS取得・トークン疎通確認は
`docker compose exec keycloak bash` 内で bash 組込みの `/dev/tcp` を使う
(スクリプト実行時の出力にコピペ可能なコマンドが出る)。

## GCP側手順

コンソール操作は日本語UI前提。値は `POOL_ID=dify-litellm-pool` / `PROVIDER_ID=keycloak-oidc` /
`SA_NAME=dify-litellm-vertex` / `KC_CLIENT_ID=litellm-vertex-wif` を使用。

### Step 1. API有効化

**APIs & Services > Library** で有効化:
- `Vertex AI API` (aiplatform.googleapis.com)
- `IAM Service Account Credentials API` (iamcredentials.googleapis.com) ※WIFのSAなりすましに必須

### Step 2. サービスアカウント作成

**☰ > IAM と管理 > サービス アカウント > ＋ サービス アカウントを作成**

1. サービス アカウント名: `dify-litellm-vertex`
2. 「このサービス アカウントにプロジェクトへのアクセス権を付与する」のロールで
   **Agent Platform ユーザー** (`roles/aiplatform.user`) を選択
   > コンソール表示名が Vertex AI User → **Agent Platform ユーザー** に変更されている
   > (Vertex AI が Gemini Enterprise Agent Platform としてリブランドされたため)。
   > ロールID自体は `roles/aiplatform.user` のまま変わらない。
3. 「ユーザーにこのサービス アカウントへのアクセスを許可する」はスキップして完了

→ `dify-litellm-vertex@<PROJECT_ID>.iam.gserviceaccount.com`

### Step 3+4. Workload Identity プール + プロバイダ

**Console(GUI)で完結できる**(JWKS静的登録もConsoleのフォームから可能。CLIは不要)。

まず、JWKSファイルをローカルに用意する(Keycloakイメージに curl/wget/python3 が無いため
`/dev/tcp` 経由):

```bash
mkdir -p gateway/wif
docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml \
  exec -T keycloak bash -c '
  exec 3<>/dev/tcp/localhost/8080
  printf "GET /realms/aiop/protocol/openid-connect/certs HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
  cat <&3
  ' | tr -d '\r' | awk 'BEGIN{body=0} /^$/ && body==0 {body=1; next} body{print}' \
    > gateway/wif/litellm-vertex-wif-jwks.json
```

**☰ > IAM と管理 > Workload Identity 連携 > プールを作成**

1. プール名: `dify-litellm-pool`
2. 同じウィザード内で「プロバイダを追加」(プール作成はプロバイダ追加とセットになっている):
   - プロバイダの形式: **OpenID Connect (OIDC)**
   - プロバイダ名: `keycloak-oidc`
   - 発行元 (Issuer) URL: `https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}`
   - オーディエンス: デフォルトではなくカスタム値を指定
     (`gateway-wif-client.sh` が出力した `WIF_AUDIENCE`)
   - **JSON Web Key Set**: 上で生成した `gateway/wif/litellm-vertex-wif-jwks.json` をアップロード
     → これにより issuer への動的フェッチが不要になり、GCPからKeycloakへ到達できなくてもよい
   - 属性マッピング: `google.subject` = `assertion.sub`、`attribute.client_id` = `assertion.azp`
   - 属性条件: `assertion.azp=='litellm-vertex-wif'`

CLIでも同等のことができる(自動化したい場合):

```bash
export PROJECT_ID="<PROJECT_ID>"

gcloud iam workload-identity-pools create dify-litellm-pool \
  --project="${PROJECT_ID}" --location="global" \
  --display-name="Dify LiteLLM (self-hosted, Keycloak federated)"

gcloud iam workload-identity-pools providers create-oidc keycloak-oidc \
  --project="${PROJECT_ID}" --location="global" \
  --workload-identity-pool="dify-litellm-pool" \
  --issuer-uri="https://auth.${GATEWAY_DOMAIN}/realms/${KEYCLOAK_REALM}" \
  --allowed-audiences="https://gcp-wif.dify-security.internal/litellm-vertex-wif" \
  --attribute-mapping="google.subject=assertion.sub,attribute.client_id=assertion.azp" \
  --attribute-condition="assertion.azp=='litellm-vertex-wif'" \
  --jwk-json-path="gateway/wif/litellm-vertex-wif-jwks.json"
```

> ⚠️ issuer-uri は **GCPが接続しにいくアドレスではなく、トークンの `iss` クレームとの
> 文字列一致にのみ使う識別子**。`compose.gateway.yaml` の `KC_HOSTNAME` により、内部
> `docker compose exec` 経由で取得したトークンでも `iss` は常にこの外部URLになる。
> ローカルURL (`http://localhost:8080/...`) を入れると一致せず検証が失敗する。
>
> ⚠️ Keycloakの署名鍵がローテーションしたら、上のJWKS取得を再実行し
> `providers update-oidc --jwk-json-path=...` で再登録が必要 (自動フェッチ方式ならこの手間は不要)。

### Step 5. Keycloakクライアントへのなりすまし権限付与

**IAM と管理 > サービス アカウント > `dify-litellm-vertex` をクリック > 「権限」タブ**

このタブに直接「アクセス権を付与」ボタンは無い。「このサービス アカウントに
アクセスできるプリンシパル」の説明文にある **「アクセス権を持つプリンシパル」** リンクを
クリックして遷移した先で「アクセスを許可」する:

- プリンシパル:
  ```
  principalSet://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/dify-litellm-pool/attribute.client_id/litellm-vertex-wif
  ```
- ロール: **Workload Identity ユーザー** (`roles/iam.workloadIdentityUser`)

(別ルート: **IAM と管理 > IAM** のプロジェクト全体一覧からでも同じプリンシパル/ロールを追加可能)

または CLI:
```bash
export PROJECT_ID="<PROJECT_ID>"
export PROJECT_NUMBER="<PROJECT_NUMBER>"   # ダッシュボードの「プロジェクト情報」カード

gcloud iam service-accounts add-iam-policy-binding \
  dify-litellm-vertex@${PROJECT_ID}.iam.gserviceaccount.com \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/dify-litellm-pool/attribute.client_id/litellm-vertex-wif"
```

### Step 6. ホスト用 credential config

`/gcloud-wif/credentials.json` (LiteLLM ホストに配置。秘密は含まない):

```json
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/dify-litellm-pool/providers/keycloak-oidc",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "/gcloud-wif/keycloak-token.jwt"
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/dify-litellm-vertex@<PROJECT_ID>.iam.gserviceaccount.com:generateAccessToken"
}
```

`/gcloud-wif/keycloak-token.jwt` は、ホスト側の定期スクリプトが Keycloak から取得した
JWT (`gateway/wif/litellm-vertex-wif.env` の `KEYCLOAK_TOKEN_URL_INTERNAL` を
`docker compose exec keycloak bash` の `/dev/tcp` 経由で叩いて取得) を書き込む先。

## 落とし穴 / 注意点

- Keycloakイメージに curl/wget/python3 が無い → `bash` の `/dev/tcp` で代替。
  `gateway-wif-client.sh` の出力コマンドはこれに対応済み。
- `gateway/wif/` ディレクトリは `gateway-wif-client.sh` 実行時に自動作成される。
  スクリプトを介さず単独でJWKS取得コマンドを打つ場合は先に `mkdir -p gateway/wif` が要る。
- ロール表示名は Vertex AI User → **Agent Platform ユーザー** (roles/aiplatform.user は不変)。
- Pool作成ウィザード(Console)はProvider追加とセットで、単独でPoolだけ作ることはできない。
  JWKS静的登録もConsoleのプロバイダ作成フォームの「JSON Web Key Set」欄からアップロード可能
  (CLIの`--jwk-json-path`は必須ではなく、単なる同等の代替手段)。
- issuer-uri は到達可能なURLである必要はなく、`iss` クレームとの文字列一致にのみ使われる
  (JWKS静的登録時)。ローカルURLに変える必要はない。
- サービスアカウント詳細画面の「権限」タブに直接の付与ボタンは無く、
  「アクセス権を持つプリンシパル」リンク経由で遷移してから付与する。
- LiteLLM UIから「Add Model」する場合、**「Vertex Credentials」欄は空欄にしない**。
  空欄でもUIは`{}`を送信するため、LiteLLMの`load_auth()`が`{}`をサービスアカウント鍵として
  パースしようとして `missing fields client_email, token_uri` で失敗する。
  `gateway/wif/credentials.json` の中身をそのまま貼り付けること(`type: external_account`が
  正しく検出され `identity_pool.Credentials` 経由の処理に入る)。
  ※ `litellm/config.yaml` に静的定義する場合は `vertex_credentials` キー自体を書かなければ
  `credentials=None` となり ADC (`google.auth.default()`) に正しくフォールバックする
  (このリポジトリの `gemini-embedding` エントリはこちらの方式)。
- 同様にUI追加時は「Vertex Project」欄も必須。WIF資格情報にはサービスアカウント鍵と違い
  `project_id` が含まれないため、明示しないと `Could not resolve project_id` で失敗する。

## 運用: compose切り替え + トークン定期更新

`compose.litellm.yaml` の `GOOGLE_APPLICATION_CREDENTIALS` を `/gcloud-wif/credentials.json`
に向け、個人ADC (`~/.config/gcloud`) マウントの代わりに以下2ファイルをマウントする:
- `./gateway/wif/credentials.json`(Step 6 の内容。秘密は含まない)
- `./gateway/wif/keycloak-token.jwt`(下記スクリプトが定期更新)

> ⚠️ 両方とも `docker compose up` する**前に実ファイルとして存在させておく**こと。
> 無い状態でマウントすると Docker がその場所をディレクトリとして誤作成する。

`scripts/gateway-wif-refresh-token.sh <client-id>` が Keycloakからトークンを取得して
`gateway/wif/keycloak-token.jwt` に書き込む(curl不在のため `/dev/tcp` 経由)。
realm の `accessTokenLifespan`(既定300s)より短い間隔で cron 登録する:

```cron
*/2 * * * * cd /path/to/dify-security && bash scripts/gateway-wif-refresh-token.sh litellm-vertex-wif \
  >> /var/log/gateway-wif-refresh.log 2>&1
```

トークン更新が止まった場合のアラート/監視は現状スコープ外。更新が止まると
Vertex 呼び出しが認証エラーになる点に注意。

疎通確認: `make embed-test`(`gemini-embedding` を実呼び出しして次元数を表示)。

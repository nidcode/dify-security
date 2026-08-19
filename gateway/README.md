# Gateway — nginx + Keycloak で EntraID 認証 / 公開範囲制御 (A' 構成)

各 Dify インスタンスの「前段」に **front-nginx + Keycloak + oauth2-proxy** を置き、
**EntraID 認証**を強制したうえで **「誰がどのサブドメイン(=インスタンス)に到達できるか」**
= 公開範囲を制御する。既存の Dify / LiteLLM には手を入れない**疎結合な追加**。

```
   ブラウザ
     │ https://teamA.example.com
     ▼
 ┌───────────────── front-nginx (唯一の LAN 公開面 / TLS 終端) ─────────────────┐
 │  auth.example.com  ─────────────────────────────► Keycloak (IdP, 1個)        │
 │  teamA.example.com ─ auth_request ─► oauth2-proxy-teamA ─(/aiop-teamA 判定)  │
 │        │ 認可OK                         ▲ OIDC                                │
 │        ▼                                └────────── Keycloak ── EntraID       │
 │  http://host.docker.internal:8081 (teamA の Dify nginx)                       │
 └──────────────────────────────────────────────────────────────────────────────┘
   ※ /v1 /triggers /e/ /mcp は対話 SSO を課さず素通し (Dify 内の APIキー/署名で認証)
```

## 役割 (A' = 認可を Keycloak に寄せる)

| 部品 | 数 | 役割 |
|---|---|---|
| **Keycloak** | 1 (全チーム共有) | 認証/認可の頭脳。EntraID を OIDC ブローカーし、**EntraID グループ/App ロール → Keycloak グループ `/aiop-<team>`** にマッピング。「誰がどのチームか」を一元管理 |
| **oauth2-proxy** | チームごと | リクエスト経路上の門番。Keycloak の該当 client でログインさせ `--allowed-group=/aiop-<team>` で存在検査 |
| **front-nginx** | 1 | 唯一の LAN 公開面。TLS 終端 + `auth_request` ルーティング |

- **「誰が入れるか」の割当は Keycloak 側 (グループ + EntraID マッパー) で管理** = 管理画面で live 変更でき、再デプロイ不要。組織再編に強い。
- oauth2-proxy の `--allowed-group=/aiop-<team>` は**インスタンス固有の定数**で、組織変更では触らない。
- ユーザーの日常異動は **EntraID グループ (または App ロール) の割当変更だけ**で完結。

## 動作モード (.env)

既定は EntraID SSO + 自前 TLS 終端 (従来どおり)。用途に応じて 2 軸で切り替える。

| 変数 | 値 | 意味 |
|---|---|---|
| `GATEWAY_AUTH` | `sso` (既定) | oauth2-proxy + Keycloak で認証/認可 |
| | `none` | **認証なしで Dify へ素通し**。Keycloak / oauth2-proxy は起動しない |
| `GATEWAY_TLS` | `terminate` (既定) | front-nginx が 443 で TLS 終端 (`gateway/certs/tls.crt|key` が必要) |
| | `none` | TLS は前段 (別 nginx / ALB / Cloudflare 等) で終端済み。80 で平文待ち受け、443 は公開しない |

`GATEWAY_AUTH=none` では front-nginx は「サブドメイン → Dify ポート」の振り分けだけを行う。

```bash
# .env: GATEWAY_AUTH=none / GATEWAY_TLS=none (前段で TLS 終端する場合)
bash scripts/gateway-add.sh teamA 8081      # nginx の vhost だけ生成 (Keycloak 不使用)
make gateway-up                              # front-nginx だけ起動
```

- **⚠ 認証は一切かからない。** front-nginx に到達できる人は全員その Dify を開ける。
  閉じた網に置くか、前段で認証すること。
- `GATEWAY_TLS=none` では `X-Forwarded-Proto` / `-Port` は前段の値をそのまま引き継ぐ
  (= 前段を信頼する)。前段を経由せず直接 80 に届く経路が無いことが前提。
- 生成物は `gateway/nginx/passthrough/` (SSO 用の `gateway/nginx/templates/` とは別)。
  混在させると同じ `server_name` が二重定義になるためディレクトリを分けている。
- **現状 `GATEWAY_AUTH=sso` と `GATEWAY_TLS=none` の組み合わせは未対応**
  (oauth2-proxy / Keycloak が https 前提のため)。指定すると起動時に落とす。

EntraID の設定 (`ENTRA_*`) が雛形値のままなら、`gateway-keycloak-init.sh` は
IdP 登録をスキップして realm だけ作る。Keycloak ローカルユーザーでログインする
構成としてそのまま使え、後から `ENTRA_*` を実値にして再実行すれば移行できる。

## 前提

- 公開ドメイン (例 `example.com`) と DNS。`auth.<domain>` と各 `<team>.<domain>` を gateway ホストへ。
- ワイルドカード TLS 証明書 → `gateway/certs/tls.crt` / `gateway/certs/tls.key` に配置。
- EntraID (Azure AD) のアプリ登録 (client id / secret / tenant id)。

## セットアップ手順

操作は **素の `docker compose`** で行う (LiteLLM/Dify と同じ流儀)。プロジェクト名は
`-p aiop-gateway`、環境は `--env-file .env` で統一。チーム追加後は
`-f gateway/oauth2-proxies.gateway.yaml` を足す。

```bash
# 0) .env にシークレット生成 (Keycloak/oauth2-proxy 分も含む)。ANTHROPIC 等は別途。
make bootstrap        # or: bash scripts/gen-env.sh   (既存 .env は不足キーのみ補完)
#    .env を編集: GATEWAY_DOMAIN, ENTRA_TENANT_ID/CLIENT_ID/CLIENT_SECRET を実値に。

# 1) TLS 証明書を配置 (ワイルドカード *.<GATEWAY_DOMAIN>)
cp /path/to/fullchain.pem gateway/certs/tls.crt
cp /path/to/privkey.pem   gateway/certs/tls.key

# 2) Gateway 起動 (front-nginx + Keycloak + DB)。初回はチーム未作成なのでベースのみ:
docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml up -d

# 3) Keycloak realm + EntraID ブローカーを初期化 (一度だけ)
bash scripts/gateway-keycloak-init.sh
#    → 表示される リダイレクト URI を EntraID アプリ登録に追加:
#      https://auth.<domain>/realms/aiop/broker/entraid/endpoint
#    → EntraID で App ロール (例 aiop-teamA) を定義し、対象グループ/ユーザーに割当

# 4) チーム(=Dify インスタンス)を公開範囲に追加 (Dify 側は先に make dify-new NAME=teamA PORT=8081)
bash scripts/gateway-add.sh teamA 8081 teamA aiop-teamA
#    引数: <team> <dify-port> [subdomain] [entra_group/approle] [entra_claim=roles]

# 5) 反映 (oauth2-proxy-teamA 起動 + front-nginx リロード)
docker compose -p aiop-gateway --env-file .env \
  -f compose.gateway.yaml -f gateway/oauth2-proxies.gateway.yaml up -d

# 6) Dify インスタンスの絶対 URL を公開ドメイン用に調整 (任意だが推奨)
bash scripts/gateway-difyenv.sh teamA teamA
cd dify/instances/teamA && docker compose up -d && cd -
```

チームを増やすときは 4→6 を繰り返す (`gateway-add.sh` → `docker compose ... up -d` → `gateway-difyenv.sh`)。

## 公開範囲 (アクセス制御) の考え方

- **サブドメイン単位 (推奨・堅牢)**: `teamA.<domain>` = teamA の Dify。到達可否は
  EntraID グループ/App ロール → `/aiop-teamA` 所属で決まる。チーム分離はこの単位で行う。
- **URL/パス単位 (限定的)**:
  - 機械系 `/v1` `/triggers` `/e/` `/mcp` は SSO を課さず素通し (Dify 内認証)。生成された
    `gateway/nginx/templates/team-<sub>.conf.template` で調整可能 (例 `/files` の扱い)。
  - ⚠ **パスで「チーム別」には分けられない** (Dify の公開アプリ URL はトークンのみでチーム接頭辞なし)。
  - ⚠ **同一インスタンスで console と公開 Web アプリを綺麗に分離できない** (同じ Next.js が `/` 配下で
    静的資産を共有)。公開ボットは専用インスタンス+専用サブドメインに分けるのが堅い。

## 部署 → インスタンスの割当 (2パターン / 環境の licensing で選択)

「どの部署がどの Dify に入れるか」は Keycloak グループ `/aiop-<team>` への所属で決まる。
その所属を **EntraID 側の割当から自動導出**する方法が licensing で2通りある。どちらも
`scripts/gateway-grant.sh` に集約され、`syncMode=FORCE` によりログイン毎に自動付与/剥奪
される (人事異動は EntraID 側の変更だけで完結)。

### B. Entra ID P1 以上 → App ロール (claim=roles) 【推奨】

割当を EntraID の1画面 (Enterprise App) に集約でき、アクセスレビュー/監査が効く。

1. アプリ登録 > アプリ ロール で ロール (例 `aiop-sales`) を定義。
2. エンタープライズ アプリケーション > ユーザーとグループ で **部署グループを App ロールに割当**
   (グループ割当は P1 必須)。→ トークンの `roles` クレームに載る。
3. gateway 側 (claim 既定=roles):
   ```bash
   bash scripts/gateway-grant.sh sales aiop-sales
   ```

### A. Free / P1 なし → セキュリティグループ (claim=groups)

App ロールへのグループ割当が使えない場合。グループ所属を `groups` クレームで判定する。

1. Azure アプリ登録 > トークン構成 で **groups クレームを発行** (種類=セキュリティ グループ)。
   → トークンの `groups` に **グループ Object ID (GUID)** が載る (グループ名ではない)。
2. 対象部署グループの **Object ID** を控える (Entra > グループ > 概要)。
3. gateway 側 (claim=groups):
   ```bash
   bash scripts/gateway-grant.sh sales 11111111-2222-3333-4444-555555555555 groups
   ```

> `gateway-add.sh` の第4/第5引数でも同じことができる (`<entra_value> [roles|groups]`)。
> 内部的に `gateway-grant.sh` を呼ぶだけなので挙動は同一。

### 多対多・剥奪

```bash
# 同一インスタンスに複数部署を許可 → 部署ごとに grant (マッパーは値ごとに一意)
bash scripts/gateway-grant.sh sharedbot aiop-sales
bash scripts/gateway-grant.sh sharedbot aiop-dev
# 剥奪 (マッパー削除。既存所属は次回ログインで外れる)
bash scripts/gateway-grant.sh --remove sales aiop-sales
```

### 暫定/個別: マッパーを使わず特定ユーザーだけ通す

検証や例外運用。Keycloak 管理画面: **Users > 対象 > Groups > Join > /aiop-\<team\>**。
CLI なら:

```bash
GW="docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml"
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
KC config credentials --server http://localhost:8080 --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
U=$(KC get users -r aiop -q email=<addr> --fields id --format csv | tr -d '"')
G=$(KC get groups -r aiop --fields id,name --format csv | grep '"aiop-<team>"' | cut -d, -f1 | tr -d '"')
KC update users/$U/groups/$G -r aiop -s realm=aiop -s userId=$U -s groupId=$G -n
```

## 二重ログインについて (重要)

Dify **Community 版はネイティブ SSO 非対応**。front-nginx の EntraID 認証は「到達可否の関所」であり、
その後に **Dify 自身のログイン**が別途残る (= 二重ログイン)。単一ログインが必須なら Dify Enterprise SSO を検討。

## 運用コマンド (素の docker compose)

チーム追加後は 2 ファイル指定が定形。エイリアスにしておくと楽:

```bash
alias gw='docker compose -p aiop-gateway --env-file .env \
  -f compose.gateway.yaml -f gateway/oauth2-proxies.gateway.yaml'

gw up -d            # 起動 / 設定変更の反映 (oauth2-proxy 追加もこれで取り込む)
gw down             # 停止 (Keycloak DB は保持)
gw ps               # 状態
gw logs -f          # ログ追従

# スクリプト (docker compose 以外の処理を含む)
bash scripts/gateway-keycloak-init.sh          # Keycloak realm + EntraID 初期化 (一度だけ)
bash scripts/gateway-add.sh <team> <port> ...  # チーム公開を追加
bash scripts/gateway-difyenv.sh <team> [sub]   # 既存 Dify の .env を公開ドメイン用に調整
```

> チーム未作成の間は `gateway/oauth2-proxies.gateway.yaml` が無いので、`-f` はベースのみ
> (`docker compose -p aiop-gateway --env-file .env -f compose.gateway.yaml ...`)。

## 生成物 (gitignore 済み)

- `gateway/oauth2-proxies.gateway.yaml` — 全チームの oauth2-proxy サービス群 (**client secret を含む** / chmod 600)
- `gateway/nginx/templates/team-<sub>.conf.template` — チーム別 server ブロック
- `gateway/certs/tls.*` — TLS 証明書

## 検証 (疎通確認)

```bash
curl -I https://teamA.example.com/            # → 302 https://auth.example.com/... (Keycloak)
# ブラウザ: EntraID ログイン → Keycloak → Dify ログイン画面 (二重ログインの実挙動)
# 認可: aiop-teamB のみのユーザーで teamA は 403 / teamB は到達
# 機械系: curl -H "Authorization: Bearer <dify-api-key>" https://teamA.example.com/v1/... → 200 (リダイレクトなし)
```

## トラブルシュート

- **Keycloak に接続できない/ログインループ**: `gw logs -f keycloak` で確認。`.env` の
  `KC_HOSTNAME`(=`auth.<GATEWAY_DOMAIN>`) と DNS/証明書が一致しているか。
- **oauth2-proxy が issuer 不一致で失敗**: トークンの `iss` は `https://auth.<domain>/realms/aiop`。
  `--oidc-issuer-url` と一致必須。バックチャネル (token/jwks) は内部 `http://keycloak:8080` を使う設定。
- **nginx が 502 (upstream)**: 対象 oauth2-proxy が未起動の可能性。`gw up -d` で起動を確認。
  upstream は変数+resolver で遅延解決するため起動順では落ちない (未起動時のみ 502)。
- **Dify の共有リンクが localhost になる**: `bash scripts/gateway-difyenv.sh <team>` 実施 + インスタンス再作成。

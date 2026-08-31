# 1. Difyインスタンスの追加・削除・バージョンアップ

新しい Dify インスタンス(チーム)の追加、不要になったインスタンスの削除(廃止)、
既存インスタンスのバージョンアップの手順。

置き換え: `<TEAM>` `<SUB>` `<DIFY_PORT>` `<DIFY_HOST>` `<GATEWAY_HOST>` `<GATEWAY_DOMAIN>`
`<REPO_DIR>` `<BACKUP_DIR>` (`<SUB>` は公開サブドメイン。通常は `<TEAM>` と同じ値)。

---

## 追加

### ① [Dify VM] インスタンスを作成して起動

```bash
ssh <DIFY_HOST>
cd <REPO_DIR>
make dify-new NAME=<TEAM> PORT=<DIFY_PORT>
cd dify/instances/<TEAM>
docker compose up -d
```

起動確認 (数分かかる場合あり。全サービスが `running` か `healthy` になっていればOK):

```bash
docker compose ps
```

`Exit` や `Restarting` のサービスがあれば手順を止めて `docker compose logs <サービス名>` を控え、
ベンダーに連絡してください。

### ② [Dify VM] 初期管理者登録用パスワードを控える

```bash
grep '^INIT_PASSWORD=' <REPO_DIR>/dify/instances/<TEAM>/.env
```

### ③ [Gateway VM] 前段に公開登録

```bash
ssh <GATEWAY_HOST>
cd <REPO_DIR>
bash scripts/gateway-add.sh <TEAM> <DIFY_HOST>:<DIFY_PORT> <TEAM>
make gateway-up
```

> Dify が別VM (=別ホスト) にあるため、第2引数は `<DIFY_HOST>:<DIFY_PORT>` の形式で指定します
> (ポートだけだと Gateway VM 自身を指してしまいます)。
>
> EntraID の App ロール/グループが既に決まっているなら第4引数で同時付与できます:
> `bash scripts/gateway-add.sh <TEAM> <DIFY_HOST>:<DIFY_PORT> <TEAM> <entra_group_or_approle>`
> 未指定なら後で: `bash scripts/gateway-grant.sh <TEAM> <entra値> [roles|groups]`

### ④ DNSを追加

`<TEAM>.<GATEWAY_DOMAIN>` を Gateway VM (`<GATEWAY_HOST>`) の IP に向ける (Aレコード)。

### ⑤ [Dify VM] 公開ドメイン用にURLを調整して再起動

事前確認 (`gateway-difyenv.sh` はこの値を使う。空なら追記してから次に進む):

```bash
ssh <DIFY_HOST>
grep '^GATEWAY_DOMAIN=' <REPO_DIR>/.env
```

反映:

```bash
cd <REPO_DIR>
bash scripts/gateway-difyenv.sh <TEAM> <TEAM>
cd dify/instances/<TEAM> && docker compose up -d
docker compose ps   # 全サービスが running/healthy か確認
```

### 確認

```bash
curl -I https://<TEAM>.<GATEWAY_DOMAIN>/
# → 302 で https://auth.<GATEWAY_DOMAIN>/... (Keycloak) にリダイレクトされればOK
```

許可されたアカウントでブラウザからアクセスし、`https://<TEAM>.<GATEWAY_DOMAIN>/install` から
管理者を作成 (②のパスワードを使用)。

> Dify Community 版は SSO 非対応のため、Gateway (EntraID/Keycloak) ログインの後に
> **Dify 自身のログインが別途必要**です (二重ログイン、想定どおりの挙動)。

モデルを使えるようにする設定は「モデルの追加・削除(LiteLLMとDify)」の手順書を参照。

### 参考: 公式ドキュメント (Dify標準機能)

このインスタンス自体の使い方 (このリポジトリ固有ではない部分) は公式ドキュメントを参照:

- [ユーザー(メンバー)の追加](https://docs.dify.ai/en/use-dify/workspace/team-members-management) — ワークスペースへのメンバー招待・権限
- [プラグインの追加](https://docs.dify.ai/en/use-dify/workspace/plugins) — Marketplace / GitHub / ローカルファイルからのインストール

### トラブルシュート

- `make gateway-up` が失敗する: `nginx -t` の検証で落ちている可能性。`<DIFY_HOST>` が
  front-nginx コンテナから到達できるか確認 (IP直指定なら通常問題なし)。
- ブラウザで 403: EntraID 側の割当 (App ロール/グループ) が対象ユーザーに付与されているか確認。
- ポート衝突: `<DIFY_PORT>` が他インスタンスと重複していないか
  `grep EXPOSE_NGINX_PORT <REPO_DIR>/dify/instances/*/.env` で確認。

チームを廃止する場合は下記「削除」を参照。

---

## 削除

> ⚠️ **この作業はデータを完全に削除します。** ①を必ず先に実施し、本当に削除してよいか
> (誤って稼働中の別チームを指定していないか) を確認してから進めてください。

チーム解散・プロジェクト終了などで、既存の Dify インスタンスを廃止する手順。「追加」の逆の操作。

### ① [Dify VM] 最終バックアップを取る (必須)

「バックアップとリストア」の手順書(①Dify VM)の手順で、このインスタンスのDB・ファイル資産を
`<BACKUP_DIR>` に退避しておく。誤削除や後からの「あのデータを確認したい」に備える。

### ② [Gateway VM] 公開を停止する

まず、まだ設定ファイルに残っている状態でコンテナだけ停止・削除する:

```bash
ssh <GATEWAY_HOST>
cd <REPO_DIR>
docker compose -p aiop-gateway --env-file .env \
  -f compose.gateway.yaml -f gateway/oauth2-proxies.gateway.yaml \
  rm -sf oauth2-proxy-<TEAM>
```

次に `gateway/oauth2-proxies.gateway.yaml` をエディタで開き、`<TEAM>` のブロックを削除する
(`# team=<TEAM>` のコメント行から、次の `# team=` 行の直前、またはファイル末尾までが対象。
ポート番号等の具体的な値は環境によって異なる):

```yaml
  # team=<TEAM> / sub=<SUB> / port=8081     ← この行から
  oauth2-proxy-<TEAM>:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
    ...
    networks:
      - gateway-internal                    ← この行まで(次のteamの行の直前)を削除
```

nginx の vhost 定義を削除:

```bash
rm gateway/nginx/templates/team-<SUB>.conf.template
```

反映 (front-nginx を再読込):

```bash
make gateway-up
```

> `make gateway-up` は反映前に設定を検証するため、編集を誤って壊れたYAML/nginx設定になった
> 場合は**エラーで中止し既存の稼働中の構成は変更されません**。エラーが出たら編集し直してください。

### ③ [LiteLLM UI] 仮想キーを失効させる

`http://<LITELLM_HOST>:<LITELLM_PORT>/ui` → **Virtual Keys** → `dify-<TEAM>` を探して **Delete**。

### ④ [Dify VM] インスタンスを削除する

```bash
ssh <DIFY_HOST>
cd <REPO_DIR>/dify/instances/<TEAM>
docker compose down -v
cd ..
rm -rf <TEAM>
```

### ⑤ DNSレコードを削除

`<SUB>.<GATEWAY_DOMAIN>` のAレコードを削除する。

### ⑥ (任意) Keycloakのグループ・クライアントを削除

残しておいても実害はないが、監査上きれいにしたい場合:

`https://auth.<GATEWAY_DOMAIN>/admin/` にログイン → 対象realm →

- **Groups** → `/aiop-<TEAM>` (接頭辞は`.env`の`KEYCLOAK_GROUP_PREFIX`) → 削除
- **Clients** → `oauth2-proxy-<TEAM>` → 削除

### 確認

```bash
curl -I https://<SUB>.<GATEWAY_DOMAIN>/
# → 接続できない、または 444/404 になっていればOK
```

---

## バージョンアップ

> ⚠️ **必ず事前にバックアップを取ってから実施すること**(「バックアップとリストア」の手順書)。
> アップグレード時にDBマイグレーションが走るため、失敗すると手戻りが大きい。

Difyは`dify/docker/`(テンプレート)を複製して各インスタンスを作る方式のため、**新しい
テンプレートを取得したうえで、インスタンスごとに個別ファイルだけ更新**する。
LiteLLM/Gatewayのバージョンアップは別の手順書(「バージョンアップ(LiteLLM・Gateway)」)を参照。

```bash
ssh <DIFY_HOST>
cd <REPO_DIR>
git pull   # ベンダーが更新したテンプレート(dify/docker/)を取得
```

以降を **インスタンスごとに1つずつ**実施 (複数ある場合、1つ確認できてから次に進む):

```bash
cd <REPO_DIR>/dify/instances/<TEAM>
docker compose down

# テンプレートの更新分を反映 (.env と volumes/ とアップロードしたデータは保持)
rsync -a --exclude='.env' --exclude='volumes/' --exclude='docker-compose.override.yaml' \
  <REPO_DIR>/dify/docker/ ./
cp <REPO_DIR>/dify/compose.override.yaml ./docker-compose.override.yaml
rsync -a <REPO_DIR>/dify/model-egress-guard/ ./model-egress-guard/

docker compose pull
docker compose up -d
docker compose ps   # 全サービスが running/healthy か確認 (マイグレーションが動くため数分かかる場合あり)
```

### 確認

```bash
curl -I https://<TEAM>.<GATEWAY_DOMAIN>/
```

ブラウザでログインし、既存のアプリ・ナレッジベースが問題なく開けるか確認する。

### トラブルシュート

- Difyの起動後に動作がおかしい: `docker compose logs api` でマイグレーションエラーが出ていないか確認。
  改善しない場合は上記「削除」①と同じ要領で、「バックアップとリストア」の手順書(①Dify VM)の
  リストア手順でバックアップ時点に戻し、ベンダーに連絡する。

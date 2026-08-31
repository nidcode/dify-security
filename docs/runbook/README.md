# 運用手順書 (dify-security / AIOP)

front-nginx+Keycloak(Gateway) / Dify / LiteLLM をそれぞれ別VMで運用する環境向けの、
**日常運用の手順書**です。初回構築や設計思想はリポジトリ直下の `README.md` /
`gateway/README.md` を参照してください。ここでは**すでに動いている
環境に対する定型作業**だけを扱います。

各手順書は他のファイルへのリンクを含まない、単独で読める構成にしています
(関連する手順は「〇〇の手順書を参照」のように名称のみで案内します)。

**最初に `00_設定書.xlsx` を開き、この環境の実際の値(ドメイン・IP・命名規則等)を
記入してください。** 各手順書中の `<...>` はこの設定書の値に読み替えて実行します
(手順書自体を書き換える場合は下記のsedも使えます)。設定書はVMが失われても参照できる
よう、オフサイトの保管場所にも複製しておくこと(詳細は設定書内の注意書きを参照)。

## 前提 (共通)

- 3台のVM: Gateway VM (front-nginx+Keycloak) / Dify VM / LiteLLM VM。各VMに本リポジトリが
  `<REPO_DIR>` に clone済み、`.env` 配置済み (`make bootstrap` 済み)。
- 各VM間はネットワーク到達可能 (IPアドレス直指定で到達する運用)。

## 置き換えキーワード一覧

手順中の `<...>` は環境に合わせて置き換えてください。エディタの一括置換、または `sed` でも可:

```bash
sed -i \
  -e 's#<REPO_DIR>#/opt/dify-security#g' \
  -e 's/<GATEWAY_DOMAIN>/example.com/g' \
  -e 's/<GATEWAY_HOST>/203.0.113.10/g' \
  -e 's/<DIFY_HOST>/10.0.1.11/g' \
  -e 's/<LITELLM_HOST>/10.0.1.12/g' \
  -e 's/<LITELLM_PORT>/4000/g' \
  docs/runbook/*.md
```

| プレースホルダ | 意味 | 例 |
|---|---|---|
| `<REPO_DIR>` | 各VM上の本リポジトリの clone 先パス | `/opt/dify-security` |
| `<GATEWAY_DOMAIN>` | 公開ドメイン (`.env` の `GATEWAY_DOMAIN`) | `example.com` |
| `<GATEWAY_HOST>` | Gateway VM の SSH接続先 | `203.0.113.10` |
| `<DIFY_HOST>` | Dify VM の SSH接続先 / ネットワーク到達先IP | `10.0.1.11` |
| `<LITELLM_HOST>` | LiteLLM VM の SSH接続先 / 到達先IP (`.env` の `LITELLM_HOST` と同じ値) | `10.0.1.12` |
| `<LITELLM_PORT>` | LiteLLM の公開ポート (`.env` の `LITELLM_PORT`, 既定 4000) | `4000` |
| `<TEAM>` | Dify インスタンス名 (=サブドメイン) | `teamA` |
| `<SUB>` | Dify インスタンスの公開サブドメイン (通常 `<TEAM>` と同じ値) | `teamA` |
| `<DIFY_PORT>` | Dify インスタンスの公開ポート | `8081` |
| `<MODEL_NAME>` | LiteLLM/Dify 双方で使うモデル名 | `claude-sonnet-4-6` |
| `<BACKUP_DIR>` | バックアップ保存先ディレクトリ (各VMローカル) | `/opt/backup` |
| `<REPO_URL>` | 本リポジトリのclone元URL (VM完全復旧後、運用コマンドを使うために任意でclone) | `git@github.com:example/dify-security.git` |
| `<OFFSITE_REMOTE>` | バックアップのオフサイト複製先 (`rclone config` で設定するリモート名) | `gcs` |

> `<LITELLM_MASTER_KEY>` 等のシークレット系プレースホルダは上記の一括置換の対象外です。
> ドキュメントに値を書き残さず、実行のたびに対象VMで `grep <KEY名>= .env` して確認してください。

### パフォーマンステスト (08〜10) 専用のプレースホルダ

vLLMで自前ホストするモデルの性能テストを実施する場合のみ使用:

| プレースホルダ | 意味 | 例 |
|---|---|---|
| `<SYSTEM_NAME>` | 対象システムの呼称 | `SAIF` |
| `<VLLM_HOST>` | vLLMを稼働させるGPUホストのSSH接続先 | `10.0.2.10` |
| `<VLLM_PORT>` | vLLMのAPI/メトリクス公開ポート | `8001` |
| `<VLLM_MODEL_ID>` | vLLMで配信するモデルのHugging Face ID/パス | `RedHatAI/gemma-4-31B-it-FP8-block` |
| `<VLLM_SERVED_MODEL_NAME>` | vLLM起動時の `--served-model-name` | `gemma4-31b` |
| `<VLLM_TOKENIZER_PATH>` | トークナイザのローカルパス | `/opt/models/hub/models--RedHatAI--gemma-4-31B-it-FP8-block` |
| `<VLLM_MODELS_DIR>` | モデルファイルのキャッシュ先ディレクトリ | `/opt/models` |
| `<VLLM_BENCH_IMAGE>` | ベンチマーク用Dockerイメージ (事前ビルド) | `litellm-vllm/vllm-bench:local` |
| `<VLLM_CONTAINER_NAME>` | vLLMサーバのコンテナ名 | `vllm-gemma-31b` |
| `<BENCH_REPO_DIR>` | `bench/*.py` 一式が置かれているリポジトリのルート (本リポジトリとは別) | `/opt/vllm-bench` |
| `<LOCUST_DIR>` | Locust実行ホスト上の `locustfile.py`/`docker-compose.yml` の場所 | `/data/locust` |
| `<PERF_APP_RAG>` / `<PERF_APP_NORAG>` / `<PERF_APP_MAXTOKEN>` | 測定用に作成するDifyアプリ名 | `perftest_rag` 等 |
| `<CREATED_BY>` / `<CREATED_DATE>` | 計画書の作成者・作成日 | 実施者名 / `2026-08-30` |

## 実行時の注意

- コマンドがエラーで止まったら、そこで**作業を中断**し、エラーメッセージを記録して
  ベンダー(弊社)に連絡してください。自己判断で同じコマンドを繰り返したり、
  次の手順に進んだりしないこと。
- 特に「バックアップとリストア」の**リストアは既存データを上書きする**操作です。
  実行前の確認事項を必ず読んでから実行してください。

## 目次

以下のファイルが `docs/runbook/` にあります (フォルダから直接開いてください):

0. `00_設定書.xlsx` (環境固有の値を記入する台帳。他の手順の前に記入)
1. `01_Difyインスタンスの追加・削除・バージョンアップ.md`
2. `02_モデルの追加・削除(LiteLLMとDify).md`
3. `03_バックアップとリストア.md`
4. `04_ユーザーアクセスの管理.md`
5. `05_TLS証明書の更新.md`
6. `06_バージョンアップ.md` (LiteLLM・Gateway)
7. `07_日常点検.md`
8. `08_パフォーマンステスト計画書.md` (vLLM自前ホスト構成向け)
9. `09_パフォーマンステスト手順書.md`
10. `10_パフォーマンステスト結果記録.xlsx`

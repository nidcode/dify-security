# 2. モデルの追加・削除 (LiteLLMとDify)

新しいLLM/埋め込みモデルを使えるようにする手順。**①LiteLLMへの登録**と
**②Difyでの設定**の2段階から成る。不要になったモデルの削除・使用量確認は**③**。

置き換え: `<TEAM>` `<GATEWAY_DOMAIN>` `<LITELLM_HOST>` `<LITELLM_PORT>` `<MODEL_NAME>` `<REPO_DIR>`。

**最初に確認してください**: 使いたいモデル (`<MODEL_NAME>`) は、LiteLLMの管理画面
(`http://<LITELLM_HOST>:<LITELLM_PORT>/ui` の **Models** 一覧) に**すでに登録済みですか？**

- **登録済みの場合** → 下記「② Difyへのモデル設定」から始めてください。
- **未登録の場合** → 下記「① LiteLLMにモデルを追加」から順に進めてください。

---

## ① LiteLLMにモデルを追加

`litellm/config.yaml` を編集せず、管理UIからモデルを追加する(即時反映・再起動不要)。

### 管理UIにログイン

ブラウザで以下を開く:

```
http://<LITELLM_HOST>:<LITELLM_PORT>/ui
```

ログイン情報 (LiteLLM VM上で確認):

```bash
ssh <LITELLM_HOST>
grep -E '^LITELLM_UI_(USERNAME|PASSWORD)=' <REPO_DIR>/.env
```

### モデルを追加

左メニュー **Models** → **+ Add New Model** →

| 項目 | 入力内容 |
|---|---|
| Provider | 実際のプロバイダ (Anthropic / Vertex AI / Ollama 等) |
| Public Model Name | Dify側でも使う呼び名 = `<MODEL_NAME>` |
| LiteLLM Model Name | プロバイダ側の実モデルID (例 `anthropic/claude-...`) |
| API Key / Credential | 既存の credential を選択、または新規入力 |
| API Base | Ollama等セルフホストの場合のみ入力 |

**Add Model** で保存。画面表示・項目名は LiteLLM のバージョンにより多少異なります。

### 動作確認

**Models** の一覧に `<MODEL_NAME>` が表示されていればOK。UIで追加したモデルはDBに保存されるため
`config.yaml` の編集・LiteLLMの再起動は不要。

より詳しく確認したい場合(任意・ターミナルが使える場合のみ):

```bash
ssh <LITELLM_HOST>
grep '^LITELLM_MASTER_KEY=' <REPO_DIR>/.env   # キーを控える

curl -s http://<LITELLM_HOST>:<LITELLM_PORT>/v1/chat/completions \
  -H "Authorization: Bearer <控えたキー>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<MODEL_NAME>","messages":[{"role":"user","content":"hello"}]}'
```

`choices[].message` を含むレスポンスが返れば成功。続けて下記「② Difyへのモデル設定」に進みます。

---

## ② Difyへのモデル設定

①でLiteLLMに追加したモデルを、各 Dify インスタンスから使えるようにする。

### [LiteLLM UI] このインスタンス用の仮想キーを発行 (未発行の場合のみ)

`http://<LITELLM_HOST>:<LITELLM_PORT>/ui` → **Virtual Keys** → **+ Create New Key**

| 項目 | 入力内容 |
|---|---|
| Key Alias | `dify-<TEAM>` |
| Models | 許可するモデルのみ選択 (`<MODEL_NAME>` など、allowlist方式) |
| Max Budget / RPM | 必要に応じて設定 |

発行されたキー (`sk-...`) を控える (再表示されないため紛失時は再発行)。

### [Dify UI] モデルプロバイダー設定を開く

`https://<TEAM>.<GATEWAY_DOMAIN>` にログイン → 右上アイコン → **設定** → **モデルプロバイダー**

初回のみ: Marketplace から **OpenAI-API-compatible** プラグインをインストール
(手順は[プラグインの追加(公式ドキュメント)](https://docs.dify.ai/en/use-dify/workspace/plugins)参照)。

### モデルを追加

**モデルを追加** →

| フィールド | 値 |
|---|---|
| Model Type | LLM (埋め込みモデルの場合は Text Embedding) |
| Model Name | `<MODEL_NAME>` (①でLiteLLMに登録した名前と完全一致させる) |
| API Key | 上で発行した仮想キー |
| API endpoint URL | `http://<LITELLM_HOST>:<LITELLM_PORT>/v1` |
| Completion mode | Chat |

保存 → モデル一覧に表示されればOK。複数モデルを追加する場合は本節を繰り返す (Model Nameのみ変更)。

### 確認

アプリ(チャットボット等)の設定でこのモデルを選択し、簡単なメッセージを送って応答が返るか確認する。

> 主要プロバイダ (OpenAI/Anthropic/Google/Azure/Bedrock等) への直接到達は既定で遮断されている
> ため、ここに直接プロバイダの生キーを入れても統制を迂回できません。必ず上記の
> LiteLLM 経由 (endpoint / 仮想キー) を使ってください。

---

## ③ LiteLLMのモデル削除・使用量確認

不要になったモデルの削除と、チーム別の利用状況・予算超過の確認手順。

### モデルの削除・無効化

`http://<LITELLM_HOST>:<LITELLM_PORT>/ui` → **Models** → 対象モデルを選択 →
**Delete** (完全に削除) または編集画面で無効化。

> ⚠️ このモデルを使っている Dify インスタンスがあると、そのモデルを選択しているアプリが
> エラーになる。削除前に上記「② Difyへのモデル設定」を行った各インスタンスで
> 使用中でないか確認すること。

### 使用状況・予算の確認

`http://<LITELLM_HOST>:<LITELLM_PORT>/ui` → **Usage** (または **Virtual Keys** の一覧画面) で:

- チーム(仮想キー)別のリクエスト数・トークン数・コストが確認できる
- **Virtual Keys** の一覧で `Spend` が `Max Budget` に近づいている/超えているキーを確認

予算超過したキーはリクエストが自動的に拒否される(429エラー)。対応:

- 一時的に上限を上げる: 該当キーの編集画面で **Max Budget** を変更
- 予算期間をリセットする: **Reset Budget** (画面がある場合) または新しいキーを再発行

### 確認

対象チームのDifyアプリで簡単なメッセージを送り、モデルが正常に応答するか確認する。

# エージェント・ガバナンス設計(A2A を使わないパターン)

社内のエージェント乱立(agent sprawl)に対する統制方針をまとめる。
対象基盤: **Dify / LangGraph / Copilot(Microsoft)** などの混在環境。
既存スタック: **LiteLLM(ゲートウェイ)+ Langfuse(可観測性)+ Anthropic / Vertex(ADC)**。

---

## 1. 大原則(no-A2A)

統制は **プロトコル(A2A)ではなく、運用設計**で行う:

> **関所(ゲートウェイ)+ 台帳(レジストリ)+ 可観測性 + ID**

- 各エージェントは **自分の ID(仮想キー)で LiteLLM を通す**のが基本。
- A2A(Agent2Agent)は「エージェント同士の発見・通信プロトコル」であり、**乱立対策の本体ではない**。エージェント同士を呼び合わせる/組織横断で標準フォーマット発見をしたい場合にのみ検討する。
- **重要な現実**: 全基盤を1つの関所に通せるとは限らない。SaaS 型(Copilot)は自前ゲートウェイにLLM呼び出しを通せないため、別プレーン(Microsoft 側)で統制し、台帳にメタデータだけ載せる。

---

## 2. 全体アーキテクチャ

```
 ┌─────────┐     ┌───────────┐     ┌──────────────────┐
 │  Dify   │     │ LangGraph │     │ Copilot (Studio) │
 │ no-code │     │   SDK     │     │  Microsoft 管理   │
 └────┬────┘     └─────┬─────┘     └────────┬─────────┘
  ws単位キー       agent単位キー        LLMは外部GWに通せない
      │ OpenAI互換     │ OpenAI互換          │ ツール/MCP/API呼びだけ統制可
      └───────┬────────┘                     │
              ▼                              ▼
   ┌────────────────────────────────────────────────┐
   │   LiteLLM Gateway = 関所(登録キーのみ/予算/制限)  │  ← Anthropic/Vertex の実キーはここだけが保持
   └───────┬──────────────────────────┬──────────────┘
           ▼                          ▼
     Anthropic / Vertex(ADC)     Langfuse(監査・per-agentトレース)

   ┌──────────────────────────────────────────────────┐
   │ 横断カタログ(任意): Backstage / Nacos = 社内台帳   │ ← 3基盤+Copilotを1覧に federate
   └──────────────────────────────────────────────────┘
```

---

## 3. 4層モデル

| 層 | 役割 | 実装 |
|---|---|---|
| **関所(強制)** | 登録済みしか LLM を呼べない・予算・モデル制限 | **LiteLLM 仮想キー** |
| **台帳(在庫)** | 何があるか・誰の所有・状態 | LiteLLM Keys/Teams +(横断なら)Backstage/Nacos |
| **可観測性** | 個別エージェントの挙動・コスト | **Langfuse** |
| **ID** | エージェント=固有資格情報 | 仮想キー(`key_alias`=エージェント名)/ Team |

> 検証済み: LiteLLM は既定で **キー無し・未登録キーを 401 で拒否**(登録キーとマスターキーのみ通過)。
> 許可外モデルの呼び出しは **403**。

---

## 4. プラットフォーム別:接続方法と“粒度”

| 基盤 | LiteLLM への通し方 | 個別エージェント識別 | 強制「登録のみ」 |
|---|---|---|---|
| **LangGraph** | `ChatOpenAI(base_url=<litellm>/v1, api_key=<agent鍵>, model="claude-sonnet-4-6")`。**エージェントごとに別キー** | **◎ 完全に個別**(キー=エージェント) | ◎ キー単位で完全強制 |
| **Dify** | モデルプロバイダ=OpenAI互換→`http://litellm:4000/v1`。**キーはワークスペース単位** | △ 個別は Langfuse のアプリ単位トレースで補完(LiteLLM では束ねられる) | ○ ワークスペース単位(個別不可)。分けたいなら**ワークスペース分割** |
| **Copilot (Studio)** | **コアの LLM 呼び出しは外部GWに通せない**(MS が管理) | ✗ LiteLLM では見えない | **MS 側で統制**(Power Platform 管理 / 環境 / DLP / Purview)。あなたの**ツール/MCP/API を呼ぶ部分だけ** LiteLLM(MCP/API ゲートウェイ)で統制 |

**要点**: LangGraph が最も統制しやすく(個別キー)、Dify はワークスペース粒度、Copilot は別プレーン(Microsoft)。

> Dify の制約は仕様: モデルプロバイダ認証情報は**ワークスペース単位**で、per-app 化要望
> ([Dify #32167](https://github.com/langgenius/dify/issues/32167))は "not planned" でクローズ済み。
> → 同一ワークスペース内の全アプリは同じ LiteLLM キーを共有する。

---

## 5. 台帳(registry)の作り方 — A2A 不要

A2A の Agent Card は不要。**ただのメタデータ目録**でよい。

- **最小構成**: LiteLLM の **Virtual Keys / Teams を台帳**にする。
  - `key_alias` = エージェント名(命名規約)
  - `GET /key/list` = 在庫一覧、`spend` = 稼働状況
- **横断カタログが欲しい場合**: Backstage(Component として)または Nacos に各エージェントを1エントリで登録。スキーマ例:

  | フィールド | 例 |
  |---|---|
  | name / platform | `sales-bot` / `Dify` \| `LangGraph` \| `Copilot` |
  | owner / status | `marketing` / `prod` |
  | litellm_key_alias / team | `sales-bot` / `marketing-team`(Copilot は空) |
  | allowed_models / budget | `claude-sonnet-4-6` / `$50/30d` |
  | observability | Langfuse project/tag(Copilot は App Insights/Purview) |

  → Dify・LangGraph・Copilot を**同じ1枚の台帳**に並べられる(プロトコル非依存)。

---

## 6. 「登録したものしか使えない」の担保(現実解)

完全な単一強制点は作れないため、**2つの強制面 + 1つのポリシー**で担保する:

1. **LiteLLM 経由のもの(LangGraph/Dify)**: 登録キー必須 → 自動で強制(成立済み)
2. **Copilot 等の非経由**: Microsoft 側(環境/DLP/承認/Purview)で「許可された Copilot エージェントしか存在しない」を担保
3. **横断ポリシー(最重要)**: **プロバイダ実キー(Anthropic / Vertex)は LiteLLM だけが保持し、チームに配らない**。これで「LiteLLM を迂回した直叩き」が物理的にできなくなり、LiteLLM 経由=登録必須 が事実上の唯一経路になる。

---

## 7. 運用ルール(最低限これだけ)

- プロバイダ実キーは **LiteLLM に集約**(直接配布禁止)。**マスターキーは管理専用**(エージェントには配らない)。
- **エージェント=1キー**(LangGraph)。Dify は重要なものは**ワークスペース分割**、それ以外は Langfuse アプリ単位で可視化。
- **全部 Langfuse に送る**(LiteLLM の `success/failure_callback` + Dify の per-app tracing)。
- Copilot は **MS 管理プレーンで統制 + メタデータだけ横断台帳に登録**。
- 仮想キーは **エージェント単位で発行/失効**。漏洩時は該当キーのみ失効。

---

## 8. 既存スタックへの適用

| 必要なもの | 状態 |
|---|---|
| 関所(LiteLLM) | ✅ 稼働中(登録キーのみ・予算・モデル制限・Langfuse連携) |
| 可観測性(Langfuse) | ✅ 稼働中(自己ホスト・外部送信なし) |
| プロバイダ集約(Anthropic/Vertex ADC) | ✅ LiteLLM のみが実キー/ADC を保持 |
| 横断カタログ(Backstage/Nacos) | ⬜ 任意。複数基盤を1台帳にしたい場合に追加 |
| Copilot 統制(MS プレーン) | ⬜ 利用時に Power Platform 管理/Purview で対応 |

---

## 9. 参考:A2A を使うべきか / OSS Agent Registry

- **A2A は乱立対策の本体ではない**。発見・記述の共通フォーマット(Agent Card)として有用だが、強制・予算・監査はゲートウェイの仕事。エージェント同士の呼び出しや組織横断の標準発見が要件のときのみ採用検討。
- 業界の収斂形は **コントロールプレーン(レジストリ)+ データプレーン(ゲートウェイ)** の2層(AWS Agent Registry / Nacos / AGNTCY が同型)。
- 自己ホスト一貫で横断台帳が欲しい場合の OSS 候補:
  - **Nacos** — 成熟・Apache-2.0・Dify 連携プラグインあり(ただし A2A 前提)
  - **AGNTCY dir** — Linux Foundation の標準志向・OASF スキーマ・署名来歴
  - **Backstage** — 人間向けカタログ/所有者管理(強制はしない)
  - **AWS Agent Registry** — マネージド版。AWS 中心ならば

---

## 参考リンク

- LiteLLM 仮想キー: https://docs.litellm.ai/docs/proxy/virtual_keys
- LiteLLM ロギング(Langfuse): https://docs.litellm.ai/docs/proxy/logging
- Dify モデルプロバイダ(ワークスペース単位): https://docs.dify.ai/en/use-dify/workspace/model-providers
- Dify #32167(per-app credential / not planned): https://github.com/langgenius/dify/issues/32167
- AWS Agent Registry: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html
- Nacos Agent Registry: https://nacos.io/en/docs/latest/manual/user/ai/agent-registry/
- AGNTCY dir: https://github.com/agntcy/dir

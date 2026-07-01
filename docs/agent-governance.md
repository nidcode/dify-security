# エージェント・ガバナンス設計(A2A を使わないパターン)

社内のエージェント乱立(agent sprawl)に対する統制方針をまとめる。
対象基盤: **Dify / LangGraph / Copilot(Microsoft)** などの混在環境。
既存スタック: **LiteLLM(ゲートウェイ)+ Anthropic / Vertex(ADC)**。
可観測性(Langfuse 等)は本リポジトリでは無効化しており、必要時に別途追加する。

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
     Anthropic / Vertex(ADC)     (任意) Langfuse等 監査・per-agentトレース

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
| **可観測性** | 個別エージェントの挙動・コスト | LiteLLM のスペンド/使用状況(詳細トレースは Langfuse 等を任意で追加) |
| **ID** | エージェント=固有資格情報 | 仮想キー(`key_alias`=エージェント名)/ Team |

> 検証済み: LiteLLM は既定で **キー無し・未登録キーを 401 で拒否**(登録キーとマスターキーのみ通過)。
> 許可外モデルの呼び出しは **403**。

---

## 4. プラットフォーム別:接続方法と“粒度”

| 基盤 | LiteLLM への通し方 | 個別エージェント識別 | 強制「登録のみ」 |
|---|---|---|---|
| **LangGraph** | `ChatOpenAI(base_url=<litellm>/v1, api_key=<agent鍵>, model="claude-sonnet-4-6")`。**エージェントごとに別キー** | **◎ 完全に個別**(キー=エージェント) | ◎ キー単位で完全強制 |
| **Dify** | モデルプロバイダ=OpenAI互換→`http://host.docker.internal:4000/v1`。**キーはワークスペース単位** | ○ **インスタンス別キー**で分離(1インスタンス=1デプロイ=1キー) | ◎ インスタンス分割が既定(マルチインスタンス構成) |
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
- **エージェント=1キー**(LangGraph)。Dify は**インスタンス別キー**で分離(1インスタンス=1デプロイ=1キー)。
- 可観測性が必要なら **LiteLLM の `success/failure_callback`** に Langfuse 等を追加(現状は無効)。
- Copilot は **MS 管理プレーンで統制 + メタデータだけ横断台帳に登録**。
- 仮想キーは **エージェント単位で発行/失効**。漏洩時は該当キーのみ失効。

---

## 8. 既存スタックへの適用

| 必要なもの | 状態 |
|---|---|
| 関所(LiteLLM) | ✅ 稼働中(登録キーのみ・予算・モデル制限) |
| 可観測性 | ⬜ 未導入(LiteLLM のスペンド表示のみ。詳細トレースは Langfuse 等を任意で追加) |
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

## 10. クラウド版(AWS / Azure)とコスト構造

OSS 自己ホストの代わりに、AWS / Azure のマネージドで台帳+ガバナンスを組むこともできる。
両クラウドとも本質は同じ型(**コントロールプレーン=台帳/承認 + データプレーン=ゲートウェイ強制 + ID + 可観測性**)で、
**台帳は強制しない / 強制はゲートウェイ**という関係も共通。違いは「単一製品か、サービスの束か」と「Copilot をネイティブに飲めるか」、そして**課金モデル**。

### 10.1 AWS 構成 — Amazon Bedrock AgentCore

```
[Dify / LangGraph / Copilot / 自作]
  ├─ 登録(A2A Card/MCP/URL発見)→ AWS Agent Registry ★Preview  … 台帳/承認/監査(CloudTrail/EventBridge)
  ├─ ツール呼び出し ───────────→ AgentCore Gateway (GA)        … 強制(Cedar+Lambda interceptor)←関所
  ├─ 認証 ────────────────────→ AgentCore Identity (GA)       … エージェントID/トークン保管
  └─ LLM ─────────────────────→ LiteLLM(維持)→ Bedrock/Anthropic/Vertex
  観測: AgentCore→CloudWatch/X-Ray、LiteLLM→Langfuse(維持)
```
- 台帳=Agent Registry(**Preview**)。他クラウド/オンプレ製も登録可。カタログであり実行は止めない。
- 強制=AgentCore Gateway(**GA**)。「承認済みのみ実行」の関所。
- **LiteLLM / Langfuse はそのまま残せる**(AgentCore は LLMルーティングGWを持たない)。

### 10.2 Azure 構成 — 単一製品でなくサービスの束

```
[Dify / LangGraph / Copilot / 自作]
  ├─ ID ───────→ Microsoft Entra Agent ID (GA)     … 各エージェントにEntra ID + Conditional Access
  ├─ 台帳 ─────→ Microsoft Agent 365 (GA)          … 全エージェント在庫(旧Entra Agent Registryは2026/5/1廃止→後継)
  │              + Foundry Control Plane            … 外部エージェント "Register asset"(HTTP/A2A)
  ├─ 関所 ─────→ Azure API Management AI Gateway(GA)… トークン制限/OAuth/Block ←関所
  ├─ データ統制→ Microsoft Purview (DSPM for AI/監査/DLP)
  └─ LLM ──────→ APIMの背後に LiteLLM(維持)→ providers
  観測: App Insights + Langfuse(維持) / Copilotは Power Platform管理→Agent365・Purviewへ自動federate
```
- 台帳=**Agent 365(GA)**。外部実行物は Foundry Control Plane で登録(APIM プロキシ+新URL+Block/Unblock、公式例は LangGraph)。
- **Copilot がネイティブ**(Power Platform→Entra Agent ID→Agent 365/Purview)。
- ⚠️ 旧 Entra Agent Registry(preview)は **2026/5/1 廃止**。台帳は Agent 365 前提。Foundry Hosted agents 等は一部 preview。

### 10.3 AWS vs Azure(機能)

| 観点 | AWS (AgentCore) | Azure(束) |
|---|---|---|
| 台帳 | Agent Registry ★Preview | Agent 365(GA)+ Foundry Control Plane |
| 強制(関所) | AgentCore Gateway / Cedar(GA) | APIM AI Gateway(GA) |
| エージェントID | AgentCore Identity(GA) | Entra Agent ID(GA) |
| **Copilot 統合** | △ 外部扱い(メタ登録) | **◎ ネイティブ** |
| LiteLLM 併存 | ◎ | ◎(APIM背後) |
| Langfuse 併存 | ◎ | ◎(App Insights併用) |
| ロックイン | 中(AWS) | 高(M365/Entra) |

### 10.4 コスト構造の比較(ここが選択の決め手)

> モデル利用料(Anthropic/Vertex/Bedrock のトークン課金)はどの方式でもほぼ同じ。**差が出るのは“ガバナンス層”の課金モデル**。

| | **OSS 自己ホスト(現行)** | **AWS AgentCore** | **Azure Agent 365** |
|---|---|---|---|
| ライセンス費 | **$0**(Apache/MIT) | $0(従量のみ) | **per-user 課金** |
| 課金モデル | インフラ費 + 運用工数 | **従量(使用量)**: Runtime $0.0895/vCPU時・$0.00945/GB時、Gateway=ツール呼び出し単位、Identity/Memory/Policy=各使用単位 | **per-seat(人数)**: Agent365 **$15/user/月**(or M365 E7 **$99/user/月** に同梱)+ ガバナンスに Entra **P1/P2** |
| スケール軸 | **インフラ規模** | **使用量(エージェント稼働)** | **ユーザー数(席)** |
| 前提条件 | サーバ用意のみ | AWSアカウント | **実質 M365 E5 が前提**(重い) |
| 運用負荷 | 高(自前運用) | 中(マネージド) | 中〜低(M365管理に統合) |
| ロックイン | 低 | 中 | 高 |

**要点:**
- **OSS = 固定費(インフラ+人件費)。台数・人数に依存しない**。最小コストだが運用は自前。
- **AWS = 使った分だけ(エージェントの稼働量に比例)。席課金なし**。AWS/Bedrock 中心や実行基盤ごと寄せたい場合に向く。
- **Azure = 人数(席)に比例 + M365 E5 前提**。大人数ほど高額、かつ Microsoft エコシステムへのロックインが強い。Copilot/M365 を全社導入済みなら自然。

### 10.5 選択ガイド

- **コスト最小・自己ホスト一貫** → **OSS**(現行の Dify+LiteLLM+Langfuse、必要なら Nacos)
- **エージェント稼働量で課金したい / AWS 中心** → **AWS AgentCore**(LiteLLM/Langfuse は併存)
- **全社 M365 E5 + Copilot 前提 / 人事的ガバナンス(sponsor・ライフサイクル)重視** → **Azure Agent 365**(ただし席課金が重い)
- 共通の限界: **Dify のワークスペース共有キー問題はクラウドでも解消しない**(登録レベルのガバナンスは付与可)。

> 注意: クラウドのライセンス/価格は GA 直後で改定中。実購入前に各社へ最終確認を推奨。

---

## 参考リンク

- LiteLLM 仮想キー: https://docs.litellm.ai/docs/proxy/virtual_keys
- LiteLLM ロギング(Langfuse): https://docs.litellm.ai/docs/proxy/logging
- Dify モデルプロバイダ(ワークスペース単位): https://docs.dify.ai/en/use-dify/workspace/model-providers
- Dify #32167(per-app credential / not planned): https://github.com/langgenius/dify/issues/32167
- AWS Agent Registry: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html
- Nacos Agent Registry: https://nacos.io/en/docs/latest/manual/user/ai/agent-registry/
- AGNTCY dir: https://github.com/agntcy/dir
- AWS Agent Registry: https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/registry.html
- AgentCore Gateway interceptors(強制): https://aws.amazon.com/blogs/machine-learning/secure-ai-agents-with-policy-and-lambda-interceptors-in-amazon-bedrock-agentcore-gateway/
- AgentCore 料金: https://aws.amazon.com/bedrock/agentcore/pricing/
- Microsoft Entra Agent ID: https://learn.microsoft.com/en-us/entra/agent-id/what-is-microsoft-entra-agent-id
- Entra Agent Registry→Agent 365 移行: https://learn.microsoft.com/en-us/entra/agent-id/agent-registry-convergence
- APIM GenAI Gateway: https://learn.microsoft.com/en-us/azure/api-management/genai-gateway-capabilities
- Agent 365 概要/ライセンス: https://learn.microsoft.com/en-us/microsoft-agent-365/overview
- Conditional Access for Agents(P1/P2+Agent365要件): https://learn.microsoft.com/en-us/entra/identity/conditional-access/agent-id

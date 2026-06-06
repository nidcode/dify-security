#!/usr/bin/env bash
# =============================================================================
# .env をシークレット自動生成付きで作成する。
#   - .env が既に存在する場合は何もしない (--force で再生成)
#   - ANTHROPIC_API_KEY だけは手動で埋める必要がある
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE="${1:-}"
if [[ -f .env && "$FORCE" != "--force" ]]; then
  echo ".env は既に存在します。再生成するには: make gen-env-force"
  exit 0
fi

cp .env.example .env

# .env 内の KEY=... 行を生成値に置換 (| を区切りに、& と \ をエスケープ)
set_kv() {
  local key="$1" val="$2" esc
  esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${esc}|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}

b64()  { openssl rand -base64 32 | tr -d '\n'; }            # NEXTAUTH_SECRET / SALT
hex()  { openssl rand -hex 32 | tr -d '\n'; }               # ENCRYPTION_KEY (64 hex = 256bit)
hexn() { openssl rand -hex "${1:-16}" | tr -d '\n'; }       # 汎用パスワード
uuid() { if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else openssl rand -hex 16; fi; }

# --- LiteLLM ---
set_kv LITELLM_MASTER_KEY  "sk-$(hexn 24)"
set_kv LITELLM_SALT_KEY    "$(hexn 24)"
set_kv LITELLM_UI_PASSWORD "$(hexn 12)"
set_kv LITELLM_DB_PASSWORD "$(hexn 16)"

# --- Langfuse: 事前プロビジョンするプロジェクトキー (LiteLLM/Dify が共用) ---
set_kv LANGFUSE_INIT_PROJECT_PUBLIC_KEY "pk-lf-$(uuid)"
set_kv LANGFUSE_INIT_PROJECT_SECRET_KEY "sk-lf-$(uuid)"
set_kv LANGFUSE_INIT_USER_PASSWORD      "$(hexn 12)"

# --- Langfuse 内部シークレット ---
set_kv LANGFUSE_NEXTAUTH_SECRET     "$(b64)"
set_kv LANGFUSE_SALT                "$(b64)"
set_kv LANGFUSE_ENCRYPTION_KEY      "$(hex)"
set_kv LANGFUSE_POSTGRES_PASSWORD   "$(hexn 16)"
set_kv LANGFUSE_CLICKHOUSE_PASSWORD "$(hexn 16)"
set_kv LANGFUSE_REDIS_AUTH          "$(hexn 16)"
set_kv LANGFUSE_MINIO_ROOT_PASSWORD "$(hexn 16)"

echo "✅ .env を生成しました (シークレットは自動生成済み)。"
echo "⚠️  必須: .env の ANTHROPIC_API_KEY を実際のキーに書き換えてください。"

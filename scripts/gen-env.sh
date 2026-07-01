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

hexn() { openssl rand -hex "${1:-16}" | tr -d '\n'; }       # 汎用パスワード/キー

# --- LiteLLM ---
set_kv LITELLM_MASTER_KEY  "sk-$(hexn 24)"
set_kv LITELLM_SALT_KEY    "$(hexn 24)"
set_kv LITELLM_UI_PASSWORD "$(hexn 12)"
set_kv LITELLM_DB_PASSWORD "$(hexn 16)"

# .env は機密 (マスターキー/DBパスワード等) → 権限を絞る
chmod 600 .env

echo "✅ .env を生成しました (シークレットは自動生成済み / chmod 600)。"
echo "⚠️  必須: .env の ANTHROPIC_API_KEY を実際のキーに書き換えてください。"

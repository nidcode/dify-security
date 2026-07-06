#!/usr/bin/env bash
# =============================================================================
# .env をシークレット自動生成付きで作成/補完する。
#   - .env が無い          → .env.example から新規作成し全シークレットを生成
#   - .env が既にある      → 不足しているキーのみ補完 (既存の値は保持)
#   - --force              → .env.example から作り直し (全シークレット再生成)
#   ANTHROPIC_API_KEY / GATEWAY_DOMAIN / ENTRA_* は手動で埋める必要がある。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

FORCE="${1:-}"

hexn() { openssl rand -hex "${1:-16}" | tr -d '\n'; }
b64()  { openssl rand -base64 "${1:-32}" | tr -d '\n'; }

# .env 内の KEY=... を生成値に置換 (| を区切りに、& と \ をエスケープ)
set_kv() {
  local key="$1" val="$2" esc
  esc=${val//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
  if grep -q "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${esc}|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$key" "$val" >> .env
  fi
}
# 不足しているキーだけ追記 (既存値は触らない)
ensure_kv() { grep -q "^${1}=" .env || printf '%s=%s\n' "$1" "$2" >> .env; }

# --- 既存 .env への「不足キー補完」モード ---
if [[ -f .env && "$FORCE" != "--force" ]]; then
  echo ".env は既存 → 不足キーのみ補完します (既存値は保持)。全再生成は: make gen-env-force"
  # Gateway 用キー (新規追加分)。シークレットは生成、非機密は雛形値。
  ensure_kv GATEWAY_DOMAIN            "example.com"
  ensure_kv KEYCLOAK_REALM           "aiop"
  ensure_kv KEYCLOAK_ADMIN           "admin"
  ensure_kv KEYCLOAK_ADMIN_PASSWORD  "$(hexn 16)"
  ensure_kv KEYCLOAK_DB_PASSWORD     "$(hexn 16)"
  ensure_kv OAUTH2_PROXY_COOKIE_SECRET "$(b64 32)"
  ensure_kv ENTRA_TENANT_ID          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  ensure_kv ENTRA_CLIENT_ID          "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  ensure_kv ENTRA_CLIENT_SECRET      "CHANGE-ME-entra-client-secret"
  chmod 600 .env
  echo "✅ 不足キーを補完しました。Gateway 利用時は GATEWAY_DOMAIN / ENTRA_* を実値に。"
  exit 0
fi

# --- 新規作成 / --force 再生成モード ---
# --force で既存 .env を作り直す際、シークレットは再生成してよいが「再生成できない
# 運用者入力値」(外部発行キー / 識別子) まで雛形へ巻き戻すのは事故なので引き継ぐ。
declare -A carry=()
if [[ -f .env && "$FORCE" == "--force" ]]; then
  for k in ANTHROPIC_API_KEY GATEWAY_DOMAIN ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET; do
    line="$(grep -m1 "^${k}=" .env || true)"
    [[ -n "$line" ]] && carry["$k"]="${line#*=}"
  done
fi

cp .env.example .env

# --- LiteLLM ---
set_kv LITELLM_MASTER_KEY  "sk-$(hexn 24)"
set_kv LITELLM_SALT_KEY    "$(hexn 24)"
set_kv LITELLM_UI_PASSWORD "$(hexn 12)"
set_kv LITELLM_DB_PASSWORD "$(hexn 16)"

# --- Gateway (nginx + Keycloak + oauth2-proxy) ---
set_kv KEYCLOAK_ADMIN_PASSWORD     "$(hexn 16)"
set_kv KEYCLOAK_DB_PASSWORD        "$(hexn 16)"
set_kv OAUTH2_PROXY_COOKIE_SECRET  "$(b64 32)"

# 運用者入力値を引き継ぐ (再生成対象外 = 雛形値へ戻さない)
if ((${#carry[@]})); then
  for k in "${!carry[@]}"; do set_kv "$k" "${carry[$k]}"; done
fi

# .env は機密 (マスターキー/DBパスワード等) → 権限を絞る
chmod 600 .env

echo "✅ .env を生成しました (シークレットは自動生成済み / chmod 600)。"
echo "⚠️  必須: ANTHROPIC_API_KEY を実際のキーに。Gateway 利用時は GATEWAY_DOMAIN / ENTRA_* も。"
if [[ "$FORCE" == "--force" ]]; then
  echo "⚠️  --force で DB パスワード (LITELLM_DB_PASSWORD / KEYCLOAK_DB_PASSWORD) を再生成しました。"
  echo "    初期化済みの Postgres ボリュームがあると認証不整合で起動失敗します。"
  echo "    既存データが不要なら該当ボリュームを破棄してから up してください (例: docker volume ls)。"
fi

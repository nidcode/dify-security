#!/usr/bin/env bash
# =============================================================================
# Dify インスタンスを1つ作る = 公式 docker/ を複製して .env を編集するだけ。
#   以後は素の docker compose で操作する (公式の使い方そのまま)。
#
#   使い方:  scripts/dify-new.sh <name> <port>
#   例:      scripts/dify-new.sh teamA 8081
#            → dify/instances/teamA/ を作成 → cd して docker compose up -d
#
# セキュリティ: 公式 .env は既知のデフォルト認証情報 (difyai123456 等) を同梱するため、
#   インスタンスごとに DB/Redis/サンドボックス/プラグインの鍵をすべて再生成する。
#   (再生成しないと全インスタンスが同一の既知パスワードを共有してしまう)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${1:?usage: dify-new.sh <name> <port>}"
PORT="${2:?usage: dify-new.sh <name> <port>}"
# NAME は英数字と - _ のみ許容 (compose プロジェクト名/ボリューム名の制約)。
# ディレクトリ名は元の大小文字を保持し、COMPOSE_PROJECT_NAME だけ小文字化する
# (compose のプロジェクト名は小文字必須。teamA を素通しすると docker compose up が失敗)。
[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || { echo "❌ NAME は英数字と - _ のみ (先頭は英数字): '$NAME'"; exit 1; }
SRC="dify/docker"
DST="dify/instances/$NAME"
ENV="$DST/.env"

[[ -f "$SRC/docker-compose.yaml" ]] || { echo "❌ Dify テンプレ未取得。先に 'make bootstrap'"; exit 1; }
[[ -e "$DST" ]] && { echo "❌ $DST は既に存在します"; exit 1; }

mkdir -p dify/instances
cp -R "$SRC" "$DST"
# host-gateway 経由で LiteLLM に到達するための override (全インスタンス共通)
cp dify/compose.override.yaml "$DST/docker-compose.override.yaml"

# .env は機密のため追跡されない (テンプレには .env.example のみ)。
# 複製後に .env が無ければ .env.example から用意する。
[[ -f "$ENV" ]] || cp "$DST/.env.example" "$ENV"

# .env の KEY=... を書き換え。無い KEY はスキップ (バージョン差異に強い)。
# 値は hex/base64 のみ → sed 区切り | と競合しない。
set_env() {   # 既存行のみ置換 (無ければスキップ)
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV"
  fi
}
upsert_env() { # 置換 or 追記
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV"; then sed -i "s|^${key}=.*|${key}=${val}|" "$ENV";
  else printf '%s=%s\n' "$key" "$val" >> "$ENV"; fi
}
rand() { openssl rand -hex 24; }

# --- インスタンス識別 / 公開ポート ---
# nginx HTTP のみ指定ポートで公開する。テンプレは SSL(443) とプラグインデバッグ(5003) も
# 固定ホストポートで公開するため、2台目以降が port-in-use で起動失敗していた。
# TLS は前段 gateway で終端し、プラグインリモートデバッグも通常運用では不要なので、
# この2つは loopback のランダムポートへ退避 = 衝突と LAN 露出の双方を回避する。
set_env EXPOSE_NGINX_PORT "$PORT"
set_env EXPOSE_NGINX_SSL_PORT "127.0.0.1:"        # → "127.0.0.1::443"  (ランダムなloopbackポート)
set_env EXPOSE_PLUGIN_DEBUGGING_PORT "127.0.0.1:" # → "127.0.0.1::5003" (同上)
upsert_env COMPOSE_PROJECT_NAME "dify-${NAME,,}"

# --- 機密値をインスタンス固有に再生成 ---
set_env SECRET_KEY "$(openssl rand -base64 42 | tr -d '\n=' )"
# INIT_PASSWORD は Dify の /console/api/init が最大30文字を課すため hex 12(=24文字) で生成。
#   rand()=hex24=48文字 だと正しい値でも 422 validation error で入力不能になる。
set_env INIT_PASSWORD "$(openssl rand -hex 12)"   # 管理者登録ページのゲート (30文字以内必須)
set_env DB_PASSWORD "$(rand)"            # Postgres (URL は各パーツから構築される)

# Redis: パスワード本体 + それをインライン埋め込みする URL(CELERY_BROKER_URL 等) を同値に揃える
redis_pw="$(rand)"
set_env REDIS_PASSWORD "$redis_pw"
sed -i "s#\(redis://[^:@/]*:\)[^@]*@#\1${redis_pw}@#g" "$ENV"

# サンドボックス鍵は sandbox 側と api 側 (CODE_EXECUTION_API_KEY) で一致必須 → 同値を投入
sandbox_key="$(rand)"
set_env SANDBOX_API_KEY "$sandbox_key"
set_env CODE_EXECUTION_API_KEY "$sandbox_key"

# プラグイン基盤の相互認証鍵 (存在すれば)。
#   compose は PLUGIN_DIFY_INNER_API_KEY を api(INNER_API_KEY_FOR_PLUGIN) と
#   plugin_daemon(DIFY_INNER_API_KEY) の双方へ供給する = これがテンプレ側の実キー。
#   .env に INNER_API_KEY_FOR_PLUGIN は存在しない (set_env が無音スキップし既定鍵が残る) ため、
#   PLUGIN_DIFY_INNER_API_KEY を再生成する。
set_env PLUGIN_DAEMON_KEY "$(rand)"
set_env PLUGIN_DIFY_INNER_API_KEY "$(rand)"

# 既定ベクタDB (weaviate) の共有既定APIキーを個別化。client(api) と server(weaviate) で一致必須。
if grep -q '^WEAVIATE_API_KEY=' "$ENV"; then
  wv_key="$(rand)"
  set_env WEAVIATE_API_KEY "$wv_key"
  upsert_env WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS "$wv_key"
fi

# .env は機密 (生成した全パスワードを含む) → 権限を絞る
chmod 600 "$ENV"

echo "✅ 作成: $DST  (project=dify-$NAME / port=$PORT)"
echo "   機密再生成: SECRET_KEY / INIT_PASSWORD / DB / Redis / Sandbox / Plugin 鍵"
echo "   INIT_PASSWORD (管理者登録用) は控えておく:"
echo "     grep '^INIT_PASSWORD=' $ENV"
echo "   起動: cd $DST && docker compose up -d      → http://localhost:$PORT"

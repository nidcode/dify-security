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
. scripts/lib/dify-instance.sh

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
dify_install_shared_files "$DST"   # override / model-egress-guard (全インスタンス共通)

# .env は機密のため追跡されない (テンプレには .env.example のみ)。
# 複製後に .env が無ければ .env.example から用意する。
[[ -f "$ENV" ]] || cp "$DST/.env.example" "$ENV"

# .env の KEY=... を書き換え (実体は lib/dify-instance.sh)。
set_env()    { dify_env_set    "$ENV" "$@"; }   # 既存行のみ置換 (無ければスキップ)
upsert_env() { dify_env_upsert "$ENV" "$@"; }   # 置換 or 追記

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
#   対象キーと生成規則 (桁数・形式の制約) は lib/dify-instance.sh の DIFY_SECRET_GEN に集約。
#   .env に存在するものだけ再生成し、その後に同値必須のペアと Redis 埋め込み URL を揃える。
for key in "${!DIFY_SECRET_GEN[@]}"; do
  set_env "$key" "$(dify_secret_gen "$key")"
done
dify_env_sync_derived "$ENV"

# --- メール送信 (SMTP) : ルート .env の共通設定を転記 (MAIL_TYPE 未設定なら何もしない) ---
#   テンプレの .env.example には MAIL_*/SMTP_* が無いが、compose の env_file は ./.env を
#   最後に読む (= 最優先) ため、インスタンス .env へ書けば api/worker に届く。
. scripts/lib/dify-mail.sh
if [[ -f .env ]] && dify_mail_copy .env "$ENV"; then
  mail_msg="メール送信設定をルート .env から転記"
else
  mail_msg="メール送信は未設定 (ルート .env の MAIL_TYPE が空)"
fi

# --- ログをインスタンスの logs/ に保存 (compose ファイル生成 + .env の COMPOSE_FILE) ---
dify_install_log_config "$DST"

# .env は機密 (生成した全パスワードを含む) → 権限を絞る
chmod 600 "$ENV"

echo "✅ 作成: $DST  (project=dify-$NAME / port=$PORT)"
echo "   機密再生成: SECRET_KEY / INIT_PASSWORD / DB / Redis / Sandbox / Plugin / Agent 鍵"
echo "   ${mail_msg}"
echo "   INIT_PASSWORD (管理者登録用) は控えておく:"
echo "     grep '^INIT_PASSWORD=' $ENV"
echo "   起動: cd $DST && docker compose up -d      → http://localhost:$PORT"

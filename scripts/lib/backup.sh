# =============================================================================
# バックアップ共通ライブラリ (source 専用・実行不可)
#
#   バックアップの取り方 (DB ダンプ / ファイル一式の tar / 取得物の検証) をここ一箇所に
#   集約する (DRY)。scripts/backup.sh (日常のバックアップ) と scripts/dify-upgrade.sh
#   (更新前のバックアップ) が参照する。リストアは手順書03に手順として持つ
#   (完全復旧はリポジトリなしで、バックアップの展開だけで行うため)。
#
#   使い方 (リポジトリルートへ cd した後):
#     . scripts/lib/dify-instance.sh
#     . scripts/lib/backup.sh
# =============================================================================

# ルート .env の値 (クォートを外す。未設定なら空)。
root_env() { local v; v="$(dify_env_get .env "$1" 2>/dev/null || true)"; printf '%s' "${v//[\'\"]/}"; }

# 保存先 = ルート .env の BACKUP_DIR (相対パスはリポジトリ直下基準)。未設定なら空。
backup_dir() {
  local d
  d="$(root_env BACKUP_DIR)"
  [[ -z "$d" ]] || realpath -m "$d"
}

# <src_dir> 配下を tar.gz にして標準出力へ書く。残りの引数は tar に渡す。
#   tar はコンテナ内の root で実行する: Weaviate 等はコンテナ内の root でファイルを作るため、
#   運用ユーザーの tar では読めずに抜け落ちる。出力はリダイレクト先 = 運用ユーザーの所有になる。
#   busybox は Dify のログ設定 (log_permissions) でも使っているイメージ。
backup_tar() {  # usage: backup_tar <src_dir> <tar の引数...>
  local src
  src="$(realpath "$1")"; shift
  docker run --rm -v "$src":/src:ro -w /src busybox tar czf - "$@"
}

# バックアップファイルが戻すのに使える状態か。問題があれば理由を出力して 0 を返す。
#   取得直後の失敗に加え、再開時 (dify-upgrade.sh) は世代管理での削除・移動・切り詰めも検出する。
backup_invalid() {  # usage: backup_invalid <file...>
  local f
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then echo "見つかりません: $f"; return 0; fi
    if (( $(stat -c %s "$f") <= 1024 )); then echo "小さすぎます: $f"; return 0; fi
    if ! gzip -t "$f" 2>/dev/null; then echo "壊れています (gzip -t 失敗): $f"; return 0; fi
  done
  return 1
}

# <cmd...> の標準出力を <out> に保存し、検証する。失敗したら <out> を作らない
#   (書きかけのファイルが最新のバックアップに見えないよう、一時ファイルに書いてから移す)。
#   DB 内容と .env (全機密) を含むため、本人のみ読める権限で作る。
backup_save() {  # usage: backup_save <out> <cmd...>
  local out="$1" reason
  shift
  if ! ( umask 077; set -o pipefail; "$@" > "$out.part" ); then
    rm -f "$out.part"; echo "❌ 取得に失敗しました: $out" >&2; return 1
  fi
  if reason="$(backup_invalid "$out.part")"; then
    rm -f "$out.part"; echo "❌ バックアップが不正です: $reason" >&2; return 1
  fi
  mv "$out.part" "$out"
}

# --- Dify インスタンス --------------------------------------------------------
# ファイル一式から除外するもの: DB は pg_dump で取得済み、残りは再構築できる一時データ。
DIFY_BACKUP_EXCLUDES=(--exclude=./volumes/db --exclude=./volumes/redis --exclude=./volumes/sandbox)

dify_dc() { local dir="$1"; shift; (cd "$dir" && docker compose "$@"); }  # usage: dify_dc <dir> <compose の引数...>

# 手順書03の方式 (同梱 db_postgres で pg_dump + Weaviate を止めて tar) で整合が取れる構成か。
#   他の DB / ベクトルDB は稼働中のファイルを tar するか、named volume で tar に含まれず、
#   外部 DB (DB_HOST) は Dify が実際に使う DB ではなくローカルの db_postgres を保存してしまい、
#   いずれも戻せないバックアップになるため対象外とする。未対応なら理由を出力して 0 を返す。
dify_backup_unsupported() {  # usage: dify_backup_unsupported <instance_dir>
  local env="$1/.env" db host vs
  db="$(dify_env_get "$env" DB_TYPE || true)"
  host="$(dify_env_get "$env" DB_HOST || true)"
  vs="$(dify_env_get "$env" VECTOR_STORE || true)"
  if [[ "${db:-postgresql}" != "postgresql" ]]; then echo "DB_TYPE=$db"; return 0; fi
  if [[ "${host:-db_postgres}" != "db_postgres" ]]; then echo "DB_HOST=$host"; return 0; fi
  if [[ "${vs:-weaviate}" != "weaviate" ]]; then echo "VECTOR_STORE=$vs"; return 0; fi
  return 1
}

# DB ダンプ (gzip) を標準出力へ書く。
#   接続ユーザー/DB 名は compose と同じく .env の値 (未設定なら compose の既定)。
#   パスワードは環境変数で渡す (コマンド引数に書くと ps で他ユーザーから見えるため)。
dify_backup_db() {  # usage: dify_backup_db <instance_dir>
  local dir="$1" env="$1/.env" user name
  dify_dc "$dir" ps --status running --services | grep -qx db_postgres || {
    echo "❌ db_postgres が起動していません: cd $dir && docker compose up -d" >&2; return 1
  }
  user="$(dify_env_get "$env" DB_USERNAME || true)"
  name="$(dify_env_get "$env" DB_DATABASE || true)"
  PGPASSWORD="$(dify_env_get "$env" DB_PASSWORD)" dify_dc "$dir" exec -T -e PGPASSWORD db_postgres \
    pg_dump -U "${user:-postgres}" --clean --if-exists "${name:-dify}" | gzip
}

# インスタンスフォルダ一式 (tar.gz) を標準出力へ書く。
#   Weaviate は稼働中のファイルを直接コピーすると不整合になり得るため、コピー中だけ一時停止する
#   (ナレッジベース検索のみ止まる。通常のチャット応答は継続する)。
dify_backup_files() {  # usage: dify_backup_files <instance_dir>
  local dir="$1" stopped=0 rc=0
  if dify_dc "$dir" ps --status running --services | grep -qx weaviate; then
    dify_dc "$dir" stop weaviate >&2 || { echo "❌ weaviate を停止できません" >&2; return 1; }
    stopped=1
  fi
  backup_tar "$dir" "${DIFY_BACKUP_EXCLUDES[@]}" . || rc=$?
  if (( stopped )); then dify_dc "$dir" start weaviate >&2 || rc=1; fi
  return "$rc"
}

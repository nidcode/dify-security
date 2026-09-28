#!/usr/bin/env bash
# =============================================================================
# 既存 Dify インスタンスを、テンプレート (dify/docker/) のバージョンへ更新する。
#   既定は計画の表示のみ (何も変更しない)。--apply で実行する。
#   1回の実行で1インスタンス (1つ確認できてから次へ進むため)。
#
#   使い方: bash scripts/dify-upgrade.sh <name> [--apply]
#
#   --apply の実行内容:
#     1. バックアップ: DB (pg_dump) + インスタンスフォルダ (tar) をルート .env の BACKUP_DIR へ。
#        形式・ファイル名は手順書03と同じ = 失敗時は03の「リストア」手順でそのまま戻せる。
#     2. .env を3方向マージ (旧テンプレの .env.example / 新テンプレの .env.example / 現在の .env)
#     3. テンプレートの更新分を反映 (.env / volumes / override は保持) + 共通ファイルを再配置
#     4. 前段公開済み (NGINX_SERVER_NAME 設定済み) なら gateway-difyenv.sh を再実行
#        (CONSOLE_API_URL の扱いが compose のバージョンで変わるため)
#     5. docker compose pull → up -d → 全サービスが起動完了するまで待機
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/dify-instance.sh

USAGE="usage: dify-upgrade.sh <name> [--apply]"
NAME="${1:?$USAGE}"
APPLY=0
case "${2:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "❌ 不明な引数: $2 ($USAGE)"; exit 1 ;;
esac
SRC="dify/docker"
DST="dify/instances/$NAME"
ENV="$DST/.env"
WAIT_TIMEOUT=900   # 起動完了待ちの上限 (秒)。マイグレーションで数分かかる場合がある

[[ -f "$SRC/docker-compose.yaml" ]] || { echo "❌ テンプレート $SRC がありません"; exit 1; }
[[ -f "$ENV" ]] || { echo "❌ $ENV がありません"; exit 1; }
command -v rsync >/dev/null || { echo "❌ rsync が必要です"; exit 1; }

dc() { (cd "$DST" && docker compose "$@"); }
root_env() { local v; v="$(dify_env_get .env "$1" 2>/dev/null || true)"; printf '%s' "${v//[\'\"]/}"; }

# テンプレ → インスタンスの rsync オプション。
#   --checksum: サイズ・更新時刻が偶然一致しても内容で比較する (例: タグ 1.15.0 → 1.16.1 は同じ長さ)
#   --exclude : インスタンス固有の設定・データ (override は後で共通ファイルとして再配置)
RSYNC_OPTS=(--checksum --exclude='.env' --exclude='*.env' --exclude='/volumes/' --exclude='/docker-compose.override.yaml')

# --- 0. バージョン判定 (compose の dify-api イメージタグ) ---
ver_of() { grep -m1 -oE 'langgenius/dify-api:[^"[:space:]]+' "$1/docker-compose.yaml" | cut -d: -f2; }
FROM="$(ver_of "$DST" || true)"
TO="$(ver_of "$SRC" || true)"
[[ -n "$FROM" && -n "$TO" ]] || { echo "❌ バージョンを判定できません (docker-compose.yaml の dify-api イメージ)"; exit 1; }

# 更新中の目印 (--apply のバックアップ直後に作成し、完了時に削除)。
#   テンプレ反映後に失敗すると compose のタグは既に新版のため、タグだけでは完了と区別できない。
#   目印があれば前回の続きから再開する (バックアップは取り直さない = 更新前の状態を保持するため)。
PENDING="$DST/.dify-upgrade-pending"
RESUME=0
if [[ -f "$PENDING" ]]; then
  RESUME=1
  FROM="$(dify_env_get "$PENDING" FROM)"
  pending_to="$(dify_env_get "$PENDING" TO)"
  DB_BAK="$(dify_env_get "$PENDING" DB_BAK)"
  FILES_BAK="$(dify_env_get "$PENDING" FILES_BAK)"
  echo "==> $NAME: 前回の更新 (Dify $FROM → $pending_to) が完了していません。--apply で続きから再開します。"
  if [[ "$pending_to" != "$TO" ]]; then
    echo "❌ テンプレートの版 ($TO) が前回の更新先 ($pending_to) と異なります。"
    echo "   手順書03のリストアで更新前に戻し、$PENDING を削除してから実行し直すこと。"
    exit 1
  fi
else
  echo "==> $NAME: Dify $FROM → $TO"
  if [[ "$FROM" == "$TO" ]]; then
    echo "  テンプレートと同じバージョンです。何もしません。"
    exit 0
  fi
  if [[ "$(printf '%s\n%s\n' "$FROM" "$TO" | sort -V | tail -n1)" != "$TO" ]]; then
    echo "❌ ダウングレードはできません (Dify の DB マイグレーションは戻せない)。"
    exit 1
  fi
fi

# --- 1. .env の3方向マージ (結果は一時ファイルに作り、--apply 時だけ反映) ---
#   旧 = インスタンスの .env.example (作成時/前回更新時のテンプレ。rsync で上書きされる前に読む)
#   新 = テンプレの .env.example
#   ① 新にだけある         → 追記 (機密キーは生成)
#   ② 旧→新で既定値が変化 → 現在値が旧既定値のままなら新既定値へ。変えていれば保持して表示
#   ③ 旧にだけある (削除/改名) → 保持して表示
#   ④ どちらにも無い (COMPOSE_PROJECT_NAME / SMTP / 公開URL 等) → 触らない
#   既存の機密値は作り直さない (DB_PASSWORD や SECRET_KEY を変えると既存データが読めなくなるため)。
declare -A OLD=() NEW=() CUR=() MRG=()
load_env() {   # <file> <連想配列名>  KEY=値 を読む (重複は後勝ち)
  local -n _m="$2"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _m["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < "$1"
}
env_keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | tr -d = | awk '!seen[$0]++'; }

load_env "$DST/.env.example" OLD
load_env "$SRC/.env.example" NEW
load_env "$ENV" CUR

MERGED="$(mktemp)"
trap 'rm -f "$MERGED"' EXIT
cat "$ENV" > "$MERGED"

kept=() removed=() weak=()
header_done=0
while IFS= read -r k; do
  if [[ -z "${CUR[$k]+x}" ]]; then                                        # ①
    if (( ! header_done )); then
      printf '\n# --- dify-upgrade: %s → %s で追加 (%s) ---\n' "$FROM" "$TO" "$(date +%F)" >> "$MERGED"
      header_done=1
    fi
    if dify_is_secret "$k"; then v="$(dify_secret_gen "$k")"; else v="${NEW[$k]}"; fi
    dify_env_upsert "$MERGED" "$k" "$v"
  elif [[ -n "${OLD[$k]+x}" && "${OLD[$k]}" != "${NEW[$k]}" ]] && ! dify_is_secret "$k"; then  # ②
    if [[ "${CUR[$k]}" == "${OLD[$k]}" ]]; then
      dify_env_upsert "$MERGED" "$k" "${NEW[$k]}"
    elif [[ "${CUR[$k]}" != "${NEW[$k]}" ]]; then
      kept+=("$k")
    fi
  fi
done < <(env_keys "$SRC/.env.example")
for k in "${!OLD[@]}"; do                                                  # ③
  if [[ -z "${NEW[$k]+x}" && -n "${CUR[$k]+x}" ]]; then removed+=("$k"); fi
done
dify_env_sync_derived "$MERGED"   # 追加したペアの従を既存の正に揃える / Redis 埋め込み URL
load_env "$MERGED" MRG

# 既知の値 (テンプレの既定値) や空のままの機密キー = 公開リポジトリで既知の認証情報
for k in "${!DIFY_SECRET_GEN[@]}"; do
  [[ -n "${MRG[$k]+x}" ]] || continue
  v="${MRG[$k]}"
  if [[ -z "$v" || "$v" == "${OLD[$k]:-}" || "$v" == "${NEW[$k]:-}" ]]; then weak+=("$k"); fi
done

# ペアの従 <key> に対し、既存 .env にある正のキー名を出力 (無ければ 1)
pair_main_of() {
  local pair main sub
  for pair in "${DIFY_SECRET_PAIRS[@]}"; do
    read -r main sub <<< "$pair"
    if [[ "$sub" == "$1" && -n "${CUR[$main]+x}" ]]; then echo "$main"; return 0; fi
  done
  return 1
}
# 表示用: 機密は伏せる。URL に埋め込まれた Redis パスワードも伏せる。
show() { if dify_is_secret "$1"; then echo "(機密)"; else sed -E 's#(redis://[^:@/]*:)[^@]*@#\1***@#' <<< "$2"; fi; }

echo ""
echo "--- .env の変更 ---"
n=0
while IFS= read -r k; do
  if [[ -z "${CUR[$k]+x}" ]]; then
    if ! dify_is_secret "$k"; then echo "  + $k=$(show "$k" "${MRG[$k]}")"
    elif main="$(pair_main_of "$k")"; then echo "  + $k=(機密・既存の $main と同値)"
    else echo "  + $k=(機密・新規生成)"; fi
    n=$((n + 1))
  elif [[ "${CUR[$k]}" != "${MRG[$k]}" ]]; then
    echo "  ~ $k: $(show "$k" "${CUR[$k]}") → $(show "$k" "${MRG[$k]}")"
    n=$((n + 1))
  fi
done < <(env_keys "$MERGED")
(( n )) || echo "  (なし)"
if (( ${#kept[@]} )); then
  echo "  既定値が変わったが、現在値を変更済みのため保持 (新しい既定値を確認):"
  for k in "${kept[@]}"; do echo "    $k: 現在 $(show "$k" "${CUR[$k]}") / 新既定 $(show "$k" "${NEW[$k]}")"; done
fi
if (( ${#removed[@]} )); then
  echo "  新バージョンの .env.example に無いキー (改名/廃止の可能性。値は保持):"
  printf '    %s\n' "${removed[@]}"
fi
if (( ${#weak[@]} )); then
  echo "  ⚠ 機密キーがテンプレ既定値または空のまま (既存データへの影響を確認のうえ個別に対処):"
  printf '    %s\n' "${weak[@]}"
fi

echo ""
echo "--- テンプレートから反映されるファイル ---"
mapfile -t files < <(rsync -ani "${RSYNC_OPTS[@]}" "$SRC/" "$DST/" | awk '$1 ~ /^>f/ { print $2 }')
echo "  ${#files[@]} 件"
for f in "${files[@]:0:30}"; do echo "    $f"; done
(( ${#files[@]} <= 30 )) || echo "    ... 他 $(( ${#files[@]} - 30 )) 件"

echo ""
echo "--- 前段公開用の設定 ---"
fqdn="$(dify_env_get "$ENV" NGINX_SERVER_NAME || true)"
gw_sub=""
if [[ -z "$fqdn" || "$fqdn" == "_" ]]; then
  echo "  前段公開の設定なし (gateway-difyenv.sh は実行しない)"
else
  gd="$(root_env GATEWAY_DOMAIN)"
  if [[ -z "$gd" ]]; then gw_sub="$fqdn"                   # 共通ドメイン無し (フラットなホスト名) 構成
  elif [[ "$fqdn" == *".$gd" ]]; then gw_sub="${fqdn%.$gd}"
  fi
  if [[ -n "$gw_sub" ]]; then
    echo "  gateway-difyenv.sh $NAME $gw_sub を再実行 ($fqdn)"
  else
    echo "  ⚠ $fqdn がルート .env の GATEWAY_DOMAIN ($gd) 配下ではないため自動再実行しない。"
    echo "    更新後に手動で: bash scripts/gateway-difyenv.sh $NAME <subdomain>"
  fi
fi

echo ""
echo "--- バックアップ ---"
# 手順書03のバックアップ方式 (同梱 db_postgres で pg_dump + Weaviate を止めて tar) で整合が取れる構成か。
#   他の DB / ベクトルDB は稼働中のファイルを tar するか、named volume で tar に含まれず、
#   外部 DB (DB_HOST) は Dify が実際に使う DB ではなくローカルの db_postgres を保存してしまい、
#   いずれも戻せないバックアップになるため対象外とする。未対応なら理由を出力。
backup_unsupported() {
  local db host vs
  db="$(dify_env_get "$ENV" DB_TYPE || true)"
  host="$(dify_env_get "$ENV" DB_HOST || true)"
  vs="$(dify_env_get "$ENV" VECTOR_STORE || true)"
  if [[ "${db:-postgresql}" != "postgresql" ]]; then echo "DB_TYPE=$db"; return 0; fi
  if [[ "${host:-db_postgres}" != "db_postgres" ]]; then echo "DB_HOST=$host"; return 0; fi
  if [[ "${vs:-weaviate}" != "weaviate" ]]; then echo "VECTOR_STORE=$vs"; return 0; fi
  return 1
}
# バックアップ2点 ($DB_BAK / $FILES_BAK) が戻すのに使える状態か。
#   取得直後の失敗に加え、再開時は世代管理での削除・移動・切り詰めも検出する。問題があれば理由を出力。
backup_invalid() {
  local f
  for f in "$DB_BAK" "$FILES_BAK"; do
    if [[ ! -f "$f" ]]; then echo "見つかりません: $f"; return 0; fi
    if (( $(stat -c %s "$f") <= 1024 )); then echo "小さすぎます: $f"; return 0; fi
    if ! gzip -t "$f" 2>/dev/null; then echo "壊れています (gzip -t 失敗): $f"; return 0; fi
  done
  return 1
}
BACKUP_DIR="$(root_env BACKUP_DIR)"
[[ -z "$BACKUP_DIR" ]] || BACKUP_DIR="$(realpath -m "$BACKUP_DIR")"
# 構成の確認は再開時も行う (中断後に DB_HOST 等が変わった場合や、この確認より前の版の
# スクリプトが作った目印では、前回のバックアップが Dify の実際の DB ではない可能性があるため)
if reason="$(backup_unsupported)"; then
  echo "  ❌ $reason は未対応 (手順書03のバックアップは同梱 Postgres + Weaviate 前提)"
elif (( RESUME )); then
  echo "  前回取得したものを使う (取り直さない)"
  echo "    DB:       $DB_BAK"
  echo "    ファイル: $FILES_BAK"
  if reason="$(backup_invalid)"; then echo "  ❌ 前回のバックアップが使えません: $reason"; fi
elif [[ -z "$BACKUP_DIR" ]]; then
  echo "  ❌ ルート .env の BACKUP_DIR が未設定 (--apply には必須)"
else
  echo "  $BACKUP_DIR/dify-$NAME-{db,files}-<日付>-pre-upgrade-<時刻>.*  (手順書03と同形式)"
fi

if (( ! APPLY )); then
  echo ""
  echo "計画の表示のみ (何も変更していません)。実行するには:"
  echo "  bash scripts/dify-upgrade.sh $NAME --apply"
  exit 0
fi

# =============================================================================
# ここから --apply
# =============================================================================
echo ""
if backup_unsupported >/dev/null; then exit 1; fi   # 新規・再開とも (理由は計画表示に出力済み)
if (( RESUME )); then
  echo "==> 1/5 バックアップ (前回のものを使う)"
  # 切り戻せない状態で更新 (マイグレーション) を続けないよう、再開前に必ず検証する。
  #   目印があるのでインスタンスは更新前か途中か分からず、ここで取り直しても更新前の状態は得られない。
  if reason="$(backup_invalid)"; then
    echo "❌ 前回のバックアップが使えないため再開しません: $reason"
    echo "   インスタンスが更新途中の可能性があり、自動では判断できません。この表示を控えてベンダーに連絡すること。"
    exit 1
  fi
else
  [[ -n "$BACKUP_DIR" ]] || exit 1
  running="$(dc ps --status running --services)"
  grep -qx db_postgres <<< "$running" || {
    echo "❌ db_postgres が起動していません (バックアップに必要)。起動してから再実行: cd $DST && docker compose up -d"
    exit 1
  }

  echo "==> 1/5 バックアップ"
  mkdir -p "$BACKUP_DIR"
  umask 077   # バックアップは DB 内容と .env (全機密) を含む → 本人のみ読める権限で作る
  stamp="$(date +%F)-pre-upgrade-$(date +%H%M%S)"
  DB_BAK="$BACKUP_DIR/dify-$NAME-db-$stamp.sql.gz"
  FILES_BAK="$BACKUP_DIR/dify-$NAME-files-$stamp.tar.gz"
  # 接続ユーザー/DB 名は compose と同じく .env の値 (未設定なら compose の既定)。
  # パスワードは環境変数で渡す (コマンド引数に書くと ps で他ユーザーから見えるため)。
  db_user="$(dify_env_get "$ENV" DB_USERNAME || true)"
  db_name="$(dify_env_get "$ENV" DB_DATABASE || true)"
  PGPASSWORD="$(dify_env_get "$ENV" DB_PASSWORD)" dc exec -T -e PGPASSWORD db_postgres \
    pg_dump -U "${db_user:-postgres}" --clean --if-exists "${db_name:-dify}" | gzip > "$DB_BAK"
  # Weaviate は稼働中のファイルを直接コピーすると不整合になり得るため、コピー中だけ一時停止 (手順書03と同じ)
  weaviate_running=0
  if grep -qx weaviate <<< "$running"; then weaviate_running=1; dc stop weaviate; fi
  rc=0
  (cd "$DST" && tar czf "$FILES_BAK" --ignore-failed-read \
    --exclude='volumes/db' --exclude='volumes/redis' --exclude='volumes/sandbox' .) || rc=$?
  if (( weaviate_running )); then dc start weaviate; fi
  (( rc <= 1 )) || { echo "❌ tar が失敗しました (rc=$rc)"; exit 1; }   # 1 = 読み取り中に変化したファイルあり (警告)
  if reason="$(backup_invalid)"; then echo "❌ バックアップに失敗しました: $reason"; exit 1; fi
  ls -lh "$DB_BAK" "$FILES_BAK"
  printf 'FROM=%s\nTO=%s\nDB_BAK=%s\nFILES_BAK=%s\n' "$FROM" "$TO" "$DB_BAK" "$FILES_BAK" > "$PENDING"
fi

# 以降で失敗したら、切り戻しに使うファイルを案内する
set -E
trap 'echo ""; echo "❌ 失敗しました (上のエラーを確認)。"; echo "   原因を取り除いて同じコマンドを再実行すると、続きから再開する (バックアップは取り直さない)。"; echo "   切り戻す場合は手順書03「① Dify VM > リストア (同一VM上)」で次の2ファイルを使い、$PENDING を削除する:"; echo "   DB:       $DB_BAK"; echo "   ファイル: $FILES_BAK"' ERR

echo "==> 2/5 .env を更新"
cat "$MERGED" > "$ENV"

echo "==> 3/5 テンプレートの更新分を反映"
rsync -a "${RSYNC_OPTS[@]}" "$SRC/" "$DST/"
dify_install_shared_files "$DST"

echo "==> 4/5 前段公開用の設定を再調整"
if [[ -n "$gw_sub" ]]; then bash scripts/gateway-difyenv.sh "$NAME" "$gw_sub"; else echo "  (対象外)"; fi

echo "==> 5/5 新バージョンで起動 (DB マイグレーションが走るため数分かかる場合あり)"
dc pull
started="$(date +%s)"
dc up -d --remove-orphans

# 全サービスが running (healthcheck があれば healthy) になるまで待つ。
# 初期化用の一回きりのサービス (init_permissions 等) は exit 0 で終了していれば完了扱い。
deadline=$((SECONDS + WAIT_TIMEOUT))
while :; do
  pending="$(dc ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' | awk -F'|' '
    !(($2 == "running" && ($3 == "" || $3 == "healthy")) || ($2 == "exited" && $4 == 0)) { print "    " $1 " (" $2 (($3 != "") ? "/" $3 : "") ")" }')"
  [[ -n "$pending" ]] || break
  if (( SECONDS >= deadline )); then
    echo "❌ ${WAIT_TIMEOUT}秒待っても起動が完了しないサービスがあります:"
    echo "$pending"
    echo "   ログ確認: cd $DST && docker compose logs <サービス名>"
    false   # ERR トラップで切り戻し手順を表示
  fi
  sleep 10
done
dc ps

if dc logs --since "$started" api 2>&1 | grep -qE 'Traceback|ERROR'; then
  echo "⚠ api のログにエラーがあります (マイグレーション失敗の可能性)。内容を確認すること:"
  dc logs --since "$started" api 2>&1 | grep -E -A3 'Traceback|ERROR' | tail -n 20
fi

rm -f "$PENDING"
echo ""
echo "✅ $NAME を Dify $TO に更新しました。"
echo "   確認: ブラウザでログインし、既存のアプリ・ナレッジベースが開けること"
[[ -z "$fqdn" || "$fqdn" == "_" ]] || echo "         curl -I https://$fqdn/"
echo "   問題があれば手順書03「① Dify VM > リストア (同一VM上)」で戻す:"
echo "     DB:       $DB_BAK"
echo "     ファイル: $FILES_BAK"

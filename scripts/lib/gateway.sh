# =============================================================================
# Gateway スタック共通ライブラリ (source 専用・実行不可)
#
#   compose プロジェクト名 / compose ファイル構成 / kcadm 呼び出し / 起動前チェック を
#   ここ一箇所に集約する (DRY)。scripts/gateway-*.sh と Makefile の gateway-* 系は
#   すべてこれを参照するので、構成変更はこのファイルだけで済む。
#
#   使い方 (各スクリプトで「リポジトリルートへ cd」した後):
#     . scripts/lib/gateway.sh
#     gateway_require_up          # 未起動なら理由と復旧コマンドを出して exit 1
#     kc_login                    # kcadm ログイン (起動直後の未 ready を待つ)
#     KC get realms ...           # 以降 kcadm を KC で呼ぶ
# =============================================================================

GATEWAY_PROJECT="aiop-gateway"
GATEWAY_COMPOSE_FILE="compose.gateway.yaml"
# 素通し (認証なし) モードで重ねる overlay。front-nginx を Keycloak 非依存にし、
# templates を素通し用の生成ディレクトリへ差し替える。
GATEWAY_PASSTHRU_FILE="compose.gateway-passthrough.yaml"
# 素通し + 自前 TLS 終端のときだけ 443 と証明書を足す overlay。
GATEWAY_PASSTHRU_TLS_FILE="compose.gateway-passthrough-tls.yaml"
# チーム追加時に scripts/gateway-add.sh が生成する oauth2-proxy 群 (無い場合もある)。
GATEWAY_PROXIES_FILE="gateway/oauth2-proxies.gateway.yaml"
# front-nginx が参照する TLS 証明書 (compose の ./gateway/certs マウント配下)。
GATEWAY_CERT_FILES=(gateway/certs/tls.crt gateway/certs/tls.key)

# --- 動作モード (.env の GATEWAY_AUTH / GATEWAY_TLS) ---------------------------
# 既定は従来どおり sso + terminate。値の検証もここに集約し、各スクリプトは
# gateway_mode_init を呼んだ後 $GATEWAY_AUTH / $GATEWAY_TLS を読むだけにする。
#
#   sso       : oauth2-proxy + Keycloak で認証/認可 (front-nginx は auth_request)
#   none      : 認証なしで Dify へ素通し。Keycloak/oauth2-proxy は起動しない。
#   terminate : front-nginx が 443 で TLS 終端 (gateway/certs/tls.crt|key が必要)
#   none(TLS) : TLS は前段 (別 nginx / ALB 等) で終端済み。80 で平文待ち受け。
gateway_mode_init() {
  GATEWAY_AUTH="${GATEWAY_AUTH:-sso}"
  GATEWAY_TLS="${GATEWAY_TLS:-terminate}"
  case "$GATEWAY_AUTH" in sso|none) ;; *)
    echo "❌ GATEWAY_AUTH は sso か none (現在: '$GATEWAY_AUTH')"; exit 1 ;; esac
  case "$GATEWAY_TLS" in terminate|none) ;; *)
    echo "❌ GATEWAY_TLS は terminate か none (現在: '$GATEWAY_TLS')"; exit 1 ;; esac
  # SSO は Keycloak/oauth2-proxy が https 前提 (cookie-secure・redirect URL) のため、
  # 前段終端との組み合わせは未対応。誤設定のまま起動して原因不明の 302 ループになるより、
  # ここで明示的に落とす。
  if [[ "$GATEWAY_AUTH" == "sso" && "$GATEWAY_TLS" == "none" ]]; then
    echo "❌ GATEWAY_AUTH=sso と GATEWAY_TLS=none の組み合わせは未対応です。"
    echo "   前段で TLS 終端する場合は現状 GATEWAY_AUTH=none (素通し) のみ対応。"
    exit 1
  fi
}

# 素通しモードかどうか (呼ぶ前に gateway_mode_init が必要)。
gateway_is_passthrough() { [[ "${GATEWAY_AUTH:-sso}" == "none" ]]; }

# front-nginx が読む server ブロック置き場。モードで別ディレクトリに分ける
# (同じ場所に両モードの vhost が混在すると server_name が衝突するため)。
#   sso  : リポジトリ管理のテンプレート (従来どおり)
#   none : 生成物 (.gitignore 済み)。scripts/gateway-render.sh が土台を書き出す。
gateway_templates_dir() {
  gateway_is_passthrough && echo "gateway/nginx/passthrough" || echo "gateway/nginx/templates"
}

# 既存コンテナへの exec 用。exec は対象サービスの定義さえあれば良いので overlay は重ねない。
GW="docker compose -p ${GATEWAY_PROJECT} --env-file .env -f ${GATEWAY_COMPOSE_FILE}"

# up/down/ps/logs 用: oauth2-proxy 群があれば重ねた「完全な構成」で操作する。
# (overlay を付けずに up すると、既存の oauth2-proxy-* が orphan 扱いになる)
gw_compose() {
  local files=(-f "$GATEWAY_COMPOSE_FILE")
  if gateway_is_passthrough; then
    # 素通し: Keycloak 依存を外し templates を差し替える。oauth2-proxy 群は載せない。
    files+=(-f "$GATEWAY_PASSTHRU_FILE")
    [[ "${GATEWAY_TLS:-terminate}" == "terminate" ]] && files+=(-f "$GATEWAY_PASSTHRU_TLS_FILE")
  elif [[ -f "$GATEWAY_PROXIES_FILE" ]]; then
    files+=(-f "$GATEWAY_PROXIES_FILE")
  fi
  docker compose -p "$GATEWAY_PROJECT" --env-file .env "${files[@]}" "$@"
}

# kcadm.sh の呼び出し (Keycloak コンテナ内で実行)。
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# --- 起動前チェック -----------------------------------------------------------
# docker compose exec は未起動時に `service "keycloak" is not running` としか言わず、
# 何をすれば復旧するのか分からない。原因を切り分けて復旧コマンドまで案内する。
gateway_require_up() {
  [[ -f .env ]] || { echo "❌ .env がありません。'make bootstrap' を実行してください"; exit 1; }
  gateway_mode_init

  if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker デーモンに接続できません。"
    echo "   Docker Desktop / dockerd が動作しているか確認してください (docker info)。"
    exit 1
  fi

  # compose 設定自体の不備 (ファイル欠落・.env の変数未設定) を「未起動」と混同しない。
  local err
  if ! err="$($GW config -q 2>&1)"; then
    echo "❌ compose 設定を読めません (${GATEWAY_COMPOSE_FILE} / .env を確認):"
    printf '   %s\n' "$err"
    exit 1
  fi

  # 監視対象サービス: SSO なら Keycloak、素通しなら front-nginx (Keycloak は起動しない)。
  local svc="keycloak"
  gateway_is_passthrough && svc="front-nginx"

  local cid
  cid="$(gw_compose ps -q "$svc" 2>/dev/null || true)"
  if [[ -z "$cid" ]]; then
    echo "❌ Gateway スタック (compose project '${GATEWAY_PROJECT}') の ${svc} が起動していません。"
    echo "   起動: make gateway-up        # nginx + Keycloak + oauth2-proxy"
    echo "   状態: make gateway-ps        ログ: make gateway-logs"
    exit 1
  fi

  # 起動直後は healthcheck が starting のまま。kc_login 側で待つのでここでは知らせるだけ。
  local health
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
  case "$health" in
    starting)   echo "ℹ ${svc} は起動処理中 (healthcheck=starting) です。応答を待ちます ..." ;;
    unhealthy)  echo "⚠ ${svc} が unhealthy です。失敗する場合は 'make gateway-logs' を確認してください" ;;
  esac
}

# front-nginx は tls.crt/tls.key が無いと起動できずクラッシュループする。
# up の前に気付けるよう警告する (Keycloak だけ使う検証もあるので中断はしない)。
gateway_warn_missing_certs() {
  # 前段で TLS 終端する構成 (GATEWAY_TLS=none) では front-nginx は 443 を持たない。
  [[ "${GATEWAY_TLS:-terminate}" == "terminate" ]] || return 0
  local f missing=()
  for f in "${GATEWAY_CERT_FILES[@]}"; do [[ -f "$f" ]] || missing+=("$f"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  echo "⚠ TLS 証明書がありません: ${missing[*]}"
  echo "   front-nginx は起動に失敗します (Keycloak 等は起動します)。"
  echo "   ワイルドカード証明書を上記の名前で配置してから 'make gateway-up' を再実行してください。"
}

# --- kcadm ログイン -----------------------------------------------------------
# 起動直後は管理APIがまだ応答しないため既定でリトライする。
#   kc_login [max_tries=20] [sleep_sec=3]
kc_login() {
  local tries="${1:-20}" wait="${2:-3}" i
  : "${KEYCLOAK_ADMIN:?}"; : "${KEYCLOAK_ADMIN_PASSWORD:?}"
  for ((i = 1; i <= tries; i++)); do
    if KC config credentials --server http://localhost:8080 \
         --realm master --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null 2>&1; then
      [[ $i -gt 1 ]] && echo "✅ Keycloak 管理APIに接続"
      return 0
    fi
    [[ $i -eq tries ]] && break
    [[ $i -eq 1 ]] && echo "⏳ Keycloak の応答を待機中 (最大 $(( tries * wait ))s) ..."
    sleep "$wait"
  done
  echo "❌ Keycloak 管理APIにログインできませんでした。"
  echo "   ログ: make gateway-logs"
  echo "   認証情報: .env の KEYCLOAK_ADMIN / KEYCLOAK_ADMIN_PASSWORD"
  exit 1
}

# --- 生成物の書き出しヘルパ ----------------------------------------------------
# 内容が変わったときだけファイルを置き換える (stdin から受け取る)。
# gateway_reload_nginx_if_stale が mtime で再起動要否を判定するため、無変更の
# 再生成で mtime だけ進むと up のたびに front-nginx が再起動されてしまう。
_gateway_write_if_changed() {  # usage: _gateway_write_if_changed <dst> <<EOF ... EOF
  local dst="$1" tmp="$1.tmp"
  cat > "$tmp"
  if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"; else mv "$tmp" "$dst"; fi
}

# --- 素通しモードの team vhost -------------------------------------------------
# gateway-add.sh (新規作成) と gateway-render.sh (TLS モード変更時の再生成) で共用する
# 唯一の生成箇所。listen/ssl は GATEWAY_TLS に依存して焼き込まれるため、モード変更時は
# gateway-render.sh が先頭コメントの sub=/port= を読み戻して本関数で作り直す。
gateway_render_passthrough_vhost() {  # usage: <sub> <port> <outfile>
  local sub="$1" port="$2" outfile="$3"
  if [[ "${GATEWAY_TLS:-terminate}" == "terminate" ]]; then
    # 自前終端: 実体は FQDN の 443 に置く。短縮名 (単一ラベル) は公的 CA が証明書を
    # 発行できず、ワイルドカード *.<domain> にも含まれないため https では張れない。
    # そこで短縮名は 80 で受けて FQDN の https へ寄せる (canonical redirect)。
    # これをせずに短縮名を 443 に載せると、既定の redirect (00-redirect.conf) が
    # http://<sub>/ → https://<sub>/ へ飛ばした先で証明書エラーになり到達できない。
    _gateway_write_if_changed "$outfile" <<NGINX
# 生成物 (GATEWAY_AUTH=none / GATEWAY_TLS=terminate) sub=${sub} → Dify port=${port}
# 認証なしの素通し。到達できる人は全員この Dify を開ける。
# 共通プロキシヘッダ (Host / X-Forwarded-* / WebSocket) は nginx.conf の http{} で設定済み。
# TLS モード (.env の GATEWAY_TLS) を変えたら make gateway-up で自動再生成される。

# 短縮名 http://<sub>/ を FQDN の https へ寄せる。証明書が単一ラベル名を張れないため、
# https://<sub>/ に飛ばすと証明書エラーになる。FQDN に正規化してから TLS を張らせる。
# (301 先を解決するには <sub>.\${GATEWAY_DOMAIN} が DNS で引ける必要がある)
server {
    listen 80;
    server_name ${sub};
    return 301 https://${sub}.\${GATEWAY_DOMAIN}\$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${sub}.\${GATEWAY_DOMAIN};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;

    location / {
        proxy_pass http://host.docker.internal:${port};
    }
}
NGINX
  else
    # 前段終端: ここは平文 80 で受けるだけで証明書を提示しないため、単一ラベル名でも
    # 問題にならない。閉域 LAN で多い短縮名アクセスをそのまま処理する。
    _gateway_write_if_changed "$outfile" <<NGINX
# 生成物 (GATEWAY_AUTH=none / GATEWAY_TLS=none) sub=${sub} → Dify port=${port}
# 認証なしの素通し。到達できる人は全員この Dify を開ける。
# 共通プロキシヘッダ (Host / X-Forwarded-* / WebSocket) は nginx.conf の http{} で設定済み。
# TLS モード (.env の GATEWAY_TLS) を変えたら make gateway-up で自動再生成される。
server {
    listen 80;
    # FQDN に加えて短縮ホスト名も受ける (未知の Host は引き続き 444)。
    server_name ${sub}.\${GATEWAY_DOMAIN} ${sub};

    location / {
        proxy_pass http://host.docker.internal:${port};
    }
}
NGINX
  fi
}

# --- 素通しモードで残った認証系コンテナの撤去 -----------------------------------
# SSO → 素通しへ切り替えた場合、keycloak/keycloak-db は profiles で、oauth2-proxy-* は
# overlay 非読込で compose の管理対象から外れ、restart: always のまま走り続ける。
# compose の up/down では触れないため、project ラベルで直接探して撤去する
# (コンテナのみ削除。keycloak-pgdata ボリュームは残る = データは保持)。
gateway_stop_stale_auth() {
  gateway_is_passthrough || return 0
  local stale
  stale="$(docker ps -a \
      --filter "label=com.docker.compose.project=${GATEWAY_PROJECT}" \
      --format '{{.ID}} {{.Label "com.docker.compose.service"}}' 2>/dev/null \
    | awk '$2 != "front-nginx" {print $1}')"
  [[ -n "$stale" ]] || return 0
  echo "♻ 素通しモードでは使わない認証系コンテナ (Keycloak / oauth2-proxy) を撤去します (DB データは保持)"
  # shellcheck disable=SC2086
  docker rm -f $stale >/dev/null
}

# --- front-nginx のテンプレート反映 -------------------------------------------
# 公式 nginx イメージの templates 機能は「コンテナ起動時に一度だけ」envsubst する。
# そのため gateway-add.sh でチームを足しても、既に動いている front-nginx には
# 反映されず、その vhost だけ既定拒否 (444) に落ちる。
# テンプレートがコンテナ起動時刻より新しければ再起動して読み直させる。
gateway_reload_nginx_if_stale() {
  local cid started newest
  cid="$(gw_compose ps -q front-nginx 2>/dev/null || true)"
  [[ -n "$cid" ]] || return 0                      # 未起動なら次の up で読まれる
  started="$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null || true)"
  [[ -n "$started" ]] || return 0
  local dir; dir="$(gateway_templates_dir)"
  [[ -d "$dir" ]] || return 0
  # 起動時刻より新しい *.template があるか (find -newermt は ISO8601 を解釈できる)
  newest="$(find "$dir" -name '*.conf.template' -newermt "$started" -print -quit 2>/dev/null || true)"
  [[ -n "$newest" ]] || return 0
  echo "♻ テンプレート更新を検出 → front-nginx を再起動して反映します"
  docker restart "$cid" >/dev/null
}

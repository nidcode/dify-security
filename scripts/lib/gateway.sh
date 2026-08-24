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
# PROXY protocol 用の実接続元IP設定 (compose の ./gateway/nginx/realip マウント配下)。
# 生成物 (.gitignore 済み)。中身は gateway_render_realip が GATEWAY_TRUSTED_PROXY_IP から作る。
GATEWAY_REALIP_DIR="gateway/nginx/realip"
# Dify インスタンスへの既定の到達先。gateway と同一ホストで Dify が動く構成では、
# compose.gateway.yaml の extra_hosts (host.docker.internal:host-gateway) 経由で
# ホストの publish ポートに届く。別ホストの Dify は gateway-add.sh に <host>:<port> を渡す。
GATEWAY_DEFAULT_UPSTREAM_HOST="host.docker.internal"

# upstream ホストが front-nginx コンテナから引けるかを確認する。
# proxy_pass はリテラル = nginx 起動時に解決されるため、引けないと front-nginx が
# 起動できず「全チームが落ちる」。追加時点で気付けるよう警告する (中断はしない:
# これから DNS を用意する / まだ相手が居ない、という順序もあるため)。
gateway_warn_unresolvable_upstream() {  # usage: <host>
  local host="$1" cid
  [[ "$host" == "$GATEWAY_DEFAULT_UPSTREAM_HOST" ]] && return 0   # extra_hosts で常に解決可
  # IP リテラルは解決不要
  [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && return 0
  cid="$(gw_compose ps -q front-nginx 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    # 実際に front-nginx の中から引けるかを見る (ホスト側で引けてもコンテナで引けるとは限らない)
    docker exec "$cid" getent hosts "$host" >/dev/null 2>&1 && return 0
    echo "⚠ front-nginx コンテナから '${host}' を解決できません。"
  else
    getent hosts "$host" >/dev/null 2>&1 && return 0
    echo "⚠ このホストから '${host}' を解決できません (front-nginx 未起動のため代わりに確認)。"
  fi
  echo "   proxy_pass はリテラル指定 = nginx 起動時に解決されるため、このままだと"
  echo "   front-nginx が起動できず全チームが落ちます。次のいずれかで解決可能にしてください:"
  echo "     - 社内 DNS に ${host} を登録する (コンテナはホストの DNS を引きます)"
  echo "     - compose.gateway.yaml の front-nginx に extra_hosts: \"${host}:<IP>\" を追加"
  echo "     - ホスト名ではなく IP を指定する (例: gateway-add.sh <team> 192.168.x.y:<port>)"
}

# "<port>" または "<host>:<port>" を解析して UPSTREAM_HOST / UPSTREAM_PORT に入れる。
# ホスト省略時は従来どおり gateway ホスト自身を指す (既存の呼び出しは挙動不変)。
gateway_parse_upstream() {  # usage: gateway_parse_upstream <port|host:port>
  local arg="${1:?}"
  if [[ "$arg" == *:* ]]; then
    UPSTREAM_HOST="${arg%:*}"
    UPSTREAM_PORT="${arg##*:}"
  else
    UPSTREAM_HOST="$GATEWAY_DEFAULT_UPSTREAM_HOST"
    UPSTREAM_PORT="$arg"
  fi
  [[ -n "$UPSTREAM_HOST" ]] || { echo "❌ upstream ホストが空です (指定: '$arg')"; exit 1; }
  [[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] || {
    echo "❌ ポートが数値ではありません: '${UPSTREAM_PORT}' (指定: '$arg')"
    echo "   指定は <port> または <host>:<port> (例: 8081 / dify01:8001)"; exit 1; }
}

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
  # ここでは値の検証のみ (副作用なし)。実際の nginx 向け生成物を書くのは
  # front-nginx の設定に触るスクリプト (gateway-compose.sh 等) が明示的に呼ぶ
  # gateway_render_realip の役目 (関心の分離: Keycloak 操作系スクリプトの実行が
  # 意図せず nginx の生成物へ副作用を及ぼさないようにする)。
}

# --- PROXY protocol (前段が TLS を終端せず TCP/SNI のまま転送する場合の実接続元IP復元) ---
#   GATEWAY_TRUSTED_PROXY_IP (.env・カンマ区切りでIP/CIDR複数可) が空なら何もしない
#   (= 使わないパターンが既定。ssl な listen も従来どおり proxy_protocol 無しのまま)。
#   front-nginx の設定/生成物に触るスクリプト (gateway-compose.sh / gateway-render.sh /
#   gateway-add.sh) が gateway_mode_init の直後に明示的に呼ぶ。Keycloak 操作専用の
#   スクリプト (gateway-grant.sh 等) からは呼ばない (関心外・.env 未読込での誤動作を防ぐ)。
gateway_render_realip() {
  mkdir -p "$GATEWAY_REALIP_DIR"
  local raw="${GATEWAY_TRUSTED_PROXY_IP:-}" ip
  # listen 行に埋め込む断片。空 (既定) なら listen は変化しない = 従来どおり。
  export GATEWAY_PROXY_PROTOCOL=""
  local enabled=0
  if [[ -n "$raw" && "${GATEWAY_TLS:-terminate}" == "terminate" ]]; then
    local ips=() entry
    IFS=',' read -ra entry <<<"$raw"
    for ip in "${entry[@]}"; do
      ip="${ip// /}"
      [[ -n "$ip" ]] || continue
      # 妥当性チェック: 各オクテット 0-255・CIDR プレフィックス 0-32 まで (IPv4 のみ対応)。
      [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] || {
        echo "❌ GATEWAY_TRUSTED_PROXY_IP の値が IPv4/CIDR に見えません: '${ip}'"; exit 1; }
      local o
      for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        ((o <= 255)) || { echo "❌ GATEWAY_TRUSTED_PROXY_IP のオクテットが範囲外です: '${ip}'"; exit 1; }
      done
      ips+=("$ip")
    done
    if ((${#ips[@]} == 0)); then
      echo "❌ GATEWAY_TRUSTED_PROXY_IP が値を含みません (カンマ/空白のみ): '${raw}'"
      echo "   使わない場合は空文字列にしてください。"
      exit 1
    fi
    enabled=1
    export GATEWAY_PROXY_PROTOCOL=" proxy_protocol"
    _gateway_write_if_changed "$GATEWAY_REALIP_DIR/00-realip.conf" <<EOF
# 生成物 (scripts/lib/gateway.sh: gateway_render_realip) / .env の GATEWAY_TRUSTED_PROXY_IP から生成
# 前段プロキシ (TCP/SNI パススルー) が付ける PROXY protocol ヘッダを、この IP からのみ信頼して
# \$remote_addr を実接続元IPへ復元する。前段プロキシ側でも PROXY protocol の送出が必要。
$(for ip in "${ips[@]}"; do echo "set_real_ip_from ${ip};"; done)
real_ip_header proxy_protocol;
EOF
  elif [[ -n "$raw" ]]; then
    echo "⚠ GATEWAY_TRUSTED_PROXY_IP は GATEWAY_TLS=terminate のときだけ意味を持ちます"
    echo "   (現在 GATEWAY_TLS=${GATEWAY_TLS:-terminate})。無視します。"
  fi
  ((enabled)) || rm -f "$GATEWAY_REALIP_DIR/00-realip.conf"

  # 既存の SSO team vhost (gateway/nginx/templates/team-*.conf.template) は
  # gateway-add.sh が作成時に1回だけ書く生成物で、TLS モード変更時のような自動再生成が
  # 無い (素通しモードの gateway_render_passthrough_vhost と異なる)。この機能を導入する
  # 前に作られたチームは listen 行に ${GATEWAY_PROXY_PROTOCOL} の置き場が無いままなので、
  # 無ければ足す (冪等: 既に置き場があるファイルにはマッチしない)。
  if ! gateway_is_passthrough; then
    local f
    for f in gateway/nginx/templates/team-*.conf.template; do
      [[ -e "$f" ]] || continue
      grep -q 'listen 443 ssl;' "$f" && sed -i 's/listen 443 ssl;/listen 443 ssl${GATEWAY_PROXY_PROTOCOL};/' "$f"
    done
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

# up の引数から「front-nginx が起動対象か」を判定する。
#   compose は サービス無指定 = 全サービス、指定あり = そのサービスのみ。
#   front-nginx を狙っていない up (例: up -d keycloak) で front-nginx の設定検証や
#   再作成まで走らせると、証明書欠落や upstream 未解決で Keycloak だけの起動・保守が
#   できなくなる (証明書欠落時に Keycloak は起動させる、という既存の方針とも矛盾する)。
gateway_up_targets_front_nginx() {  # usage: <compose の引数...> (先頭は up)
  local a skip=0 services=()
  shift || true   # "up" を捨てる
  for a in "$@"; do
    if [[ $skip == 1 ]]; then skip=0; continue; fi
    case "$a" in
      # 値を伴うオプション: 次の引数はサービス名ではない
      --scale|--timeout|-t|--exit-code-from|--attach|--no-attach|--pull|--wait-timeout)
        skip=1; continue ;;
      -*) continue ;;
    esac
    services+=("$a")
  done
  [[ ${#services[@]} -eq 0 ]] && return 0        # 無指定 = 全部 = front-nginx を含む
  local s; for s in "${services[@]}"; do [[ "$s" == "front-nginx" ]] && return 0; done
  return 1
}

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
# front-nginx が必要とする証明書が揃っているか。前段終端 (GATEWAY_TLS=none) では
# 443 を持たないので常に「揃っている」扱い。警告と設定検証のゲートで共用する。
gateway_certs_ready() {
  [[ "${GATEWAY_TLS:-terminate}" == "terminate" ]] || return 0
  local f
  for f in "${GATEWAY_CERT_FILES[@]}"; do [[ -f "$f" ]] || return 1; done
  return 0
}

gateway_warn_missing_certs() {
  gateway_certs_ready && return 0
  local f missing=()
  for f in "${GATEWAY_CERT_FILES[@]}"; do [[ -f "$f" ]] || missing+=("$f"); done
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
gateway_render_passthrough_vhost() {  # usage: <sub> <port> <outfile> [upstream_host]
  local sub="$1" port="$2" outfile="$3" up="${4:-$GATEWAY_DEFAULT_UPSTREAM_HOST}"
  # proxy_pass は upstream ホストをリテラルで書く (変数 + resolver にはしない)。
  # 変数方式は nginx 独自の resolver を使うため /etc/hosts を参照せず、docker の
  # 埋め込み DNS (127.0.0.11) はユーザー定義ネットワークでは extra_hosts のエントリを
  # NXDOMAIN で返す = 既定の host.docker.internal が引けなくなる (実測)。
  # リテラルなら libc 解決になり /etc/hosts と DNS の両方が効く。代償として、
  # 名前を引けないと nginx が起動できないため、gateway-add.sh が事前に警告する。
  if [[ "${GATEWAY_TLS:-terminate}" == "terminate" ]]; then
    # 自前終端: 実体は FQDN の 443 に置く。短縮名 (単一ラベル) は公的 CA が証明書を
    # 発行できず、ワイルドカード *.<domain> にも含まれないため https では張れない。
    # そこで短縮名は 80 で受けて FQDN の https へ寄せる (canonical redirect)。
    # これをせずに短縮名を 443 に載せると、既定の redirect (00-redirect.conf) が
    # http://<sub>/ → https://<sub>/ へ飛ばした先で証明書エラーになり到達できない。
    _gateway_write_if_changed "$outfile" <<NGINX
# 生成物 (GATEWAY_AUTH=none / GATEWAY_TLS=terminate) sub=${sub} → Dify upstream=${up}:${port}
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
    listen 443 ssl\${GATEWAY_PROXY_PROTOCOL};
    http2 on;
    server_name ${sub}.\${GATEWAY_DOMAIN};

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;

    location / {
        proxy_pass http://${up}:${port};
    }
}
NGINX
  else
    # 前段終端: ここは平文 80 で受けるだけで証明書を提示しないため、単一ラベル名でも
    # 問題にならない。閉域 LAN で多い短縮名アクセスをそのまま処理する。
    _gateway_write_if_changed "$outfile" <<NGINX
# 生成物 (GATEWAY_AUTH=none / GATEWAY_TLS=none) sub=${sub} → Dify upstream=${up}:${port}
# 認証なしの素通し。到達できる人は全員この Dify を開ける。
# 共通プロキシヘッダ (Host / X-Forwarded-* / WebSocket) は nginx.conf の http{} で設定済み。
# TLS モード (.env の GATEWAY_TLS) を変えたら make gateway-up で自動再生成される。
server {
    listen 80;
    # FQDN に加えて短縮ホスト名も受ける (未知の Host は引き続き 444)。
    server_name ${sub}.\${GATEWAY_DOMAIN} ${sub};

    location / {
        proxy_pass http://${up}:${port};
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
  # 起動時刻より新しい *.template があるか (find -newermt は ISO8601 を解釈できる)。
  # realip.d (PROXY protocol の実接続元IP設定) は別ディレクトリなので合わせて見る。
  # ここが変わっただけでは compose 側の環境変数 (GATEWAY_PROXY_PROTOCOL の文字列自体) は
  # 変化しないことがあるため (信頼IPの差し替えなど)、mtime で検出しないと反映漏れになる。
  newest="$(find "$dir" "$GATEWAY_REALIP_DIR" \( -name '*.conf.template' -o -name '*.conf' \) \
    -newermt "$started" -print -quit 2>/dev/null || true)"
  [[ -n "$newest" ]] || return 0
  echo "♻ テンプレート更新を検出 → front-nginx を作り直して反映します"
  # restart ではなく作り直す。envsubst は起動時に conf.d へ書き出すだけで、削除された
  # テンプレートに対応する古い .conf を消さない (conf.d はマウントではなくコンテナ内)。
  # restart だとチームを削除しても その vhost が残り続ける【実測】。
  gw_compose up -d --force-recreate --no-deps front-nginx >/dev/null 2>&1
}

# --- 起動後の設定エラー検出 -----------------------------------------------------
# proxy_pass のホストを引けないと nginx は [emerg] で起動できず、restart: always の
# ためクラッシュループになる。この時 front-nginx 全体 = 全チームが落ちるので、
# 「up は成功したのにアクセスできない」を黙って通さず、原因行を出して知らせる。
# 反映前に front-nginx の設定を検証する。使い捨てコンテナで nginx -t を回すので、
# 稼働中の front-nginx には触れない = 設定ミスで動いているゲートウェイを落とさない。
# (状態サンプリングでの事後検出は不可: nginx イメージは entrypoint の envsubst 中も
#  status=running のため、クラッシュループでも running に見える時間が長い【実測】)
# proxy_pass のホストはリテラル = 起動時解決なので、名前を引けないかもここで分かる。
gateway_check_nginx_config() {
  local out
  out="$(gw_compose run --rm --no-deps -T front-nginx nginx -t 2>&1)" && return 0
  local emerg; emerg="$(grep -m1 '\[emerg\]' <<<"$out" || true)"
  if [[ -z "$emerg" ]]; then
    # nginx -t まで到達できなかった (イメージ取得失敗・network 不整合など)。
    # 「検証できないこと」を理由に up を止めると、設定は正しいのに何も反映できなくなる。
    # 検証はあくまで安全網なので、実行不能なら警告に留めて続行する。
    echo "⚠ 設定検証を実行できませんでした (検証をスキップして続行します):"
    printf '   %s\n' "$(tail -2 <<<"$out")"
    return 0
  fi
  echo "❌ front-nginx の設定にエラーがあります (反映を中止しました / 現在の稼働構成は維持):"
  # [emerg] はパターンでは文字クラス扱いになるためエスケープする
  # (${emerg#*[emerg] } と書くと理由部分まで削れる)。
  echo "   ${emerg#*\[emerg\] }"
  if [[ "$emerg" == *"host not found in upstream"* ]]; then
    local badhost; badhost="$(sed -n 's/.*host not found in upstream "\([^"]*\)".*/\1/p' <<<"$emerg")"
    echo "   → '${badhost}' を front-nginx コンテナから解決できません。次のいずれかで対処:"
    echo "     - 社内 DNS に ${badhost} を登録する (コンテナはホストの DNS を引きます)"
    echo "     - compose.gateway.yaml の front-nginx に extra_hosts: \"${badhost}:<IP>\" を追加"
    echo "     - 該当チームを IP 指定で作り直す (gateway-add.sh <team> <IP>:<port>)"
  fi
  return 1
}

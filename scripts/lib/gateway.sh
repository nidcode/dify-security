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
# チーム追加時に scripts/gateway-add.sh が生成する oauth2-proxy 群 (無い場合もある)。
GATEWAY_PROXIES_FILE="gateway/oauth2-proxies.gateway.yaml"
# front-nginx が参照する TLS 証明書 (compose の ./gateway/certs マウント配下)。
GATEWAY_CERT_FILES=(gateway/certs/tls.crt gateway/certs/tls.key)

# 既存コンテナへの exec 用。exec は対象サービスの定義さえあれば良いので overlay は重ねない。
GW="docker compose -p ${GATEWAY_PROJECT} --env-file .env -f ${GATEWAY_COMPOSE_FILE}"

# up/down/ps/logs 用: oauth2-proxy 群があれば重ねた「完全な構成」で操作する。
# (overlay を付けずに up すると、既存の oauth2-proxy-* が orphan 扱いになる)
gw_compose() {
  local files=(-f "$GATEWAY_COMPOSE_FILE")
  [[ -f "$GATEWAY_PROXIES_FILE" ]] && files+=(-f "$GATEWAY_PROXIES_FILE")
  docker compose -p "$GATEWAY_PROJECT" --env-file .env "${files[@]}" "$@"
}

# kcadm.sh の呼び出し (Keycloak コンテナ内で実行)。
KC() { $GW exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"; }

# --- 起動前チェック -----------------------------------------------------------
# docker compose exec は未起動時に `service "keycloak" is not running` としか言わず、
# 何をすれば復旧するのか分からない。原因を切り分けて復旧コマンドまで案内する。
gateway_require_up() {
  [[ -f .env ]] || { echo "❌ .env がありません。'make bootstrap' を実行してください"; exit 1; }

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

  local cid
  cid="$($GW ps -q keycloak 2>/dev/null || true)"
  if [[ -z "$cid" ]]; then
    echo "❌ Gateway スタック (compose project '${GATEWAY_PROJECT}') が起動していません。"
    echo "   起動: make gateway-up        # nginx + Keycloak + oauth2-proxy"
    echo "   状態: make gateway-ps        ログ: make gateway-logs"
    exit 1
  fi

  # 起動直後は healthcheck が starting のまま。kc_login 側で待つのでここでは知らせるだけ。
  local health
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
  case "$health" in
    starting)   echo "ℹ Keycloak は起動処理中 (healthcheck=starting) です。応答を待ちます ..." ;;
    unhealthy)  echo "⚠ Keycloak が unhealthy です。失敗する場合は 'make gateway-logs' を確認してください" ;;
  esac
}

# front-nginx は tls.crt/tls.key が無いと起動できずクラッシュループする。
# up の前に気付けるよう警告する (Keycloak だけ使う検証もあるので中断はしない)。
gateway_warn_missing_certs() {
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

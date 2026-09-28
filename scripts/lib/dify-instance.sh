# =============================================================================
# Dify インスタンス共通ライブラリ (source 専用・実行不可)
#
#   インスタンスへの共通ファイル配置 / .env 編集 / 機密値の生成規則 をここ一箇所に
#   集約する (DRY)。bootstrap.sh (テンプレ) / dify-new.sh (作成) /
#   dify-upgrade.sh (更新) / gateway-difyenv.sh / lib/dify-mail.sh が参照する。
#
#   使い方 (リポジトリルートへ cd した後):
#     . scripts/lib/dify-instance.sh
# =============================================================================

# 全インスタンス共通のファイルを <dir> に配置 (冪等)。
#   - docker-compose.override.yaml: host-gateway 経由で LiteLLM に到達するための override
#   - model-egress-guard/: 主要モデルプロバイダへの直接到達を既定で遮断するプロキシ一式
dify_install_shared_files() {
  local dir="$1"
  cp dify/compose.override.yaml "$dir/docker-compose.override.yaml"
  mkdir -p "$dir/model-egress-guard"
  cp -R dify/model-egress-guard/. "$dir/model-egress-guard/"
}

# --- .env 編集 ---------------------------------------------------------------
# 値は awk の ENVIRON 経由で渡す = sed の区切り文字や & \ のエスケープが不要で、
# URL やクォート付きの値もそのまま書ける。書き戻しは cat で行い権限 (chmod 600) を保持する。
dify_env_has() { grep -q "^${2}=" "$1"; }                                 # <env> <key>
dify_env_get() {                                                         # <env> <key>: 重複時は最後の行
  local l                                                                # (bash の source / compose と同じく後勝ち)
  l="$(grep "^${2}=" "$1" | tail -n1)"
  [[ -n "$l" ]] || return 1
  printf '%s\n' "${l#*=}"
}
dify_env_upsert() {                                                      # <env> <key> <val>: 置換 or 追記
  local env="$1" tmp
  tmp="$(mktemp)"
  K="$2" V="$3" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }' "$env" > "$tmp"
  cat "$tmp" > "$env"
  rm -f "$tmp"
}
dify_env_set() {                                                         # <env> <key> <val>: 既存行のみ置換
  if dify_env_has "$1" "$2"; then dify_env_upsert "$@"; fi               # (無い KEY はスキップ = バージョン差異に強い)
}

# --- 機密値 ------------------------------------------------------------------
# 公式 .env.example は既知のデフォルト認証情報 (difyai123456 等) を同梱するため、
# インスタンスごとに再生成する機密キーとその生成規則。
#   dify-new.sh    : 作成時に、.env に存在するものを全て再生成
#   dify-upgrade.sh: 新バージョンで追加されたキーだけ生成 (既存の値は絶対に作り直さない。
#                    DB_PASSWORD や SECRET_KEY を変えると既存データが読めなくなるため)
declare -gA DIFY_SECRET_GEN=(
  [SECRET_KEY]=b64_42
  # INIT_PASSWORD は Dify の /console/api/init が最大30文字を課すため hex 12(=24文字) で生成。
  #   hex24=48文字 だと正しい値でも 422 validation error で入力不能になる。
  [INIT_PASSWORD]=hex12                           # 管理者登録ページのゲート
  [DB_PASSWORD]=hex24                             # Postgres (URL は各パーツから構築される)
  [REDIS_PASSWORD]=hex24                          # 埋め込み URL は dify_env_sync_derived で追従
  # サンドボックス鍵は sandbox 側と api 側 (CODE_EXECUTION_API_KEY) で一致必須 → DIFY_SECRET_PAIRS
  [SANDBOX_API_KEY]=hex24
  [CODE_EXECUTION_API_KEY]=hex24
  # プラグイン基盤の相互認証鍵。
  #   compose は PLUGIN_DIFY_INNER_API_KEY を api(INNER_API_KEY_FOR_PLUGIN) と
  #   plugin_daemon(DIFY_INNER_API_KEY) の双方へ供給する = これがテンプレ側の実キー。
  #   .env に INNER_API_KEY_FOR_PLUGIN は存在しない (再生成しても無音スキップし既定鍵が残る) ため、
  #   PLUGIN_DIFY_INNER_API_KEY を再生成する。
  [PLUGIN_DAEMON_KEY]=hex24
  [PLUGIN_DIFY_INNER_API_KEY]=hex24
  # Dify Agent backend (1.16+) の認証鍵。
  #   DIFY_AGENT_PLUGIN_DAEMON_API_KEY / DIFY_AGENT_INNER_API_KEY は .env で空のままなら
  #   compose 側の ${VAR:-${PLUGIN_DAEMON_KEY:-既定}} 等のフォールバックで上の再生成値を
  #   自動的に引き継ぐため、ここには含めない。一方、以下は .env.example に開発用の
  #   固定値 (公開リポジトリで既知) が直接入っており、フォールバックが効かないため個別に
  #   再生成する。特に sandbox 認証トークンが既定 (空) のままだと、untrusted な
  #   コードを実行する local_sandbox への shellctl API 呼び出しが無認証になる。
  [DIFY_AGENT_API_TOKEN]=hex24
  # DIFY_AGENT_SERVER_SECRET_KEY は JWE 暗号鍵の元で「base64url デコード後ちょうど32バイト」を
  #   起動時に検証される (不一致だと agent_backend が ValidationError で起動しない)。
  [DIFY_AGENT_SERVER_SECRET_KEY]=key32_b64url
  # sandbox 認証トークンは 1.17 で DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN に改名 (旧名はフォールバック)。
  [DIFY_AGENT_SHELLCTL_AUTH_TOKEN]=hex24          # 1.16
  [DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN]=hex24     # 1.17+
  # 既定ベクタDB (weaviate) の共有既定APIキー。client(api) と server(weaviate) で一致必須。
  [WEAVIATE_API_KEY]=hex24
  [WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS]=hex24
)

# 同値必須のペア "正 従"。正と従の両方が .env にあれば、従を正の値に揃える。
#   (.env.example には片方しか無い版もある。無いキーは足さない = バージョン差異に強い)
DIFY_SECRET_PAIRS=(
  "SANDBOX_API_KEY CODE_EXECUTION_API_KEY"
  "DIFY_AGENT_SHELLCTL_AUTH_TOKEN DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN"
  "WEAVIATE_API_KEY WEAVIATE_AUTHENTICATION_APIKEY_ALLOWED_KEYS"
)

dify_is_secret() { [[ -n "${DIFY_SECRET_GEN[$1]:-}" ]]; }                # <key>

dify_secret_gen() {                                                      # <key> → 生成値を出力
  case "${DIFY_SECRET_GEN[$1]:-}" in
    b64_42)       openssl rand -base64 42 | tr -d '\n=' ;;
    hex12)        openssl rand -hex 12 ;;
    hex24)        openssl rand -hex 24 ;;
    # 32バイト鍵の base64url (パディング無し, 43文字)。デコード後の長さまで検証される暗号鍵用。
    #   hex は base64 として読むと36バイト/hexとして読むと24バイトで、どちらも不一致になる。
    key32_b64url) openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' ;;
    *) echo "❌ 機密キーではありません: $1" >&2; return 1 ;;
  esac
}

# 他の値から決まる値を揃える (冪等)。値は hex のみ → sed 区切り # と競合しない。
#   - DIFY_SECRET_PAIRS の従を正の値へ
#   - REDIS_PASSWORD をインライン埋め込みする URL (CELERY_BROKER_URL 等) を同値へ
dify_env_sync_derived() {                                                # <env>
  local env="$1" pair main sub pw
  for pair in "${DIFY_SECRET_PAIRS[@]}"; do
    read -r main sub <<< "$pair"
    if dify_env_has "$env" "$main"; then
      dify_env_set "$env" "$sub" "$(dify_env_get "$env" "$main")"
    fi
  done
  if pw="$(dify_env_get "$env" REDIS_PASSWORD)"; then
    sed -i "s#\(redis://[^:@/]*:\)[^@]*@#\1${pw}@#g" "$env"
  fi
}

# --- ログの保存 (監査・トラブル対応) --------------------------------------------
# 各サービスのログを、コンテナ内ではなくインスタンスの logs/<サービス>/ に保存する
# (コンテナを作り直しても消えず、バックアップ対象になる)。ローテーションはホストの
# logrotate (dify/logrotate/ → /etc/logrotate.d/dify-*) が行う。
#   "サービス名 コンテナ内のログディレクトリ 書き込みuid"
DIFY_LOG_SERVICES=(
  "api /app/logs 1001"                    # Dify 本体 (LOG_FILE)。uid は公式 init_permissions と同じ
  "api_websocket /app/logs 1001"
  "worker /app/logs 1001"
  "worker_beat /app/logs 1001"
  "nginx /var/log/nginx 0"                # 公式イメージは stdout へのリンク → マウントで実ファイルになる
  "ssrf_proxy /var/log/squid 13"          # squid (proxy ユーザー)。所有者が違うと起動に失敗する
  "agent_ssrf_proxy /var/log/squid 13"
  "model_egress_guard /var/log/squid 13"
)
DIFY_LOG_COMPOSE_FILE="docker-compose.logs.yaml"

# <dir> (インスタンス) にログ保存用の compose ファイルを生成し、.env の COMPOSE_FILE で読み込ませる (冪等)。
#   公式の compose / 共通 override には手を入れない (疎結合)。存在するサービスだけを対象にするため、
#   Dify のバージョンでサービスが増減しても追随する (dify-upgrade.sh が更新後に再生成する)。
dify_install_log_config() {
  local dir="$1" entry svc path uid perms="" gid
  # ログのグループ = インスタンスのフォルダのグループ (dify-new.sh を実行した運用ユーザー)。
  # 各サービスのログを運用ユーザーで読める = バックアップ (手順書03の tar) で読み飛ばされない。
  # logs/ のグループを使わないのは、sudo で実行されると logs/ が root で作られるため。
  gid="$(stat -c %g "$dir")"
  mkdir -p "$dir/logs"
  {
    echo "# 自動生成 (scripts/lib/dify-instance.sh の dify_install_log_config)。手で編集しない。"
    echo "# 各サービスのログを ./logs/<サービス>/ に保存する。ローテーションはホストの logrotate。"
    echo "services:"
    for entry in "${DIFY_LOG_SERVICES[@]}"; do
      read -r svc path uid <<< "$entry"
      grep -qE "^  ${svc}:[[:space:]]*$" "$dir/docker-compose.yaml" "$dir/docker-compose.override.yaml" 2>/dev/null || continue
      perms+=" $svc:$uid"
      cat <<YAML
  $svc:
    volumes:
      - ./logs/$svc:$path
    depends_on:
      log_permissions:
        condition: service_completed_successfully
YAML
      if [[ "$path" == "/app/logs" ]]; then
        cat <<YAML
    environment:
      LOG_FILE: /app/logs/server.log
      # Dify 自身のローテーションは 0 (無効) を受け付けない (PositiveInt) ため上限を大きく取り、
      # 日次の logrotate に任せる (1024MB は安全装置)
      LOG_FILE_MAX_SIZE: "1024"
YAML
      fi
    done
    cat <<YAML
  # ログディレクトリの所有者を各サービスの書き込みユーザーに、グループを運用ユーザー (gid $gid)
  # にそろえる。setgid によりサービスが作るファイルも運用ユーザーで読める。
  # -R はリストア (tar 展開で所有者が運用ユーザーになる) 後の修復のため。
  log_permissions:
    image: busybox:latest
    restart: "no"
    volumes:
      - ./logs:/logs
    command:
      - sh
      - -c
      - |
        g=$gid
        for e in${perms}; do
          d=/logs/\$\${e%%:*}; u=\$\${e##*:}
          mkdir -p "\$\$d" && chown -R "\$\$u:\$\$g" "\$\$d" && chmod 2750 "\$\$d"
        done
YAML
  } > "$dir/$DIFY_LOG_COMPOSE_FILE"
  dify_env_upsert "$dir/.env" COMPOSE_FILE "docker-compose.yaml:docker-compose.override.yaml:$DIFY_LOG_COMPOSE_FILE"
}

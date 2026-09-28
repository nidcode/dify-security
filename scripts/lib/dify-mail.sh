# =============================================================================
# Dify メール送信 (SMTP) 設定の共通ライブラリ (source 専用・実行不可)
#
#   メール送信設定は全インスタンス共通の運用者入力値としてルート .env に一度だけ書き、
#   dify-new.sh が作成時に各インスタンス .env へ転記する。対象キーの一覧はここ一箇所に
#   集約する (DRY)。dify-new.sh (転記) と gen-env.sh (--force 時の引き継ぎ) が参照する。
#
#   使い方 (リポジトリルートへ cd した後):
#     . scripts/lib/dify-mail.sh
#     dify_mail_copy .env dify/instances/<name>/.env
# =============================================================================

DIFY_MAIL_KEYS=(
  MAIL_TYPE
  MAIL_DEFAULT_SEND_FROM
  SMTP_SERVER
  SMTP_PORT
  SMTP_USERNAME
  SMTP_PASSWORD
  SMTP_USE_TLS
  SMTP_OPPORTUNISTIC_TLS
)

# src の DIFY_MAIL_KEYS 行を dst へ転記する (dst の同名行は置き換え)。
#   - MAIL_TYPE が空/未定義なら何もしない (= メール送信を使わない構成。戻り値 1)
#   - 値が空のキーは転記しない (空文字を渡すと Dify 側の既定値ではなく空が効くため)
#   - 行はクォートを含めそのまま写す。ルート .env は bash から source され、
#     インスタンス .env は compose が読むが、シングルクォートは両者で同じ意味になるため
#     値の加工 (sed エスケープ等) を一切しない。
dify_mail_copy() {
  local src="$1" dst="$2" key line val tmp
  line="$(grep -m1 '^MAIL_TYPE=' "$src" || true)"
  val="${line#*=}"; val="${val//[\'\"]/}"
  [[ -n "$val" ]] || return 1

  tmp="$(mktemp)"
  for key in "${DIFY_MAIL_KEYS[@]}"; do
    line="$(grep -m1 "^${key}=" "$src" || true)"
    val="${line#*=}"; val="${val//[\'\"]/}"
    [[ -n "$val" ]] || continue
    grep -v "^${key}=" "$dst" > "$tmp" || true
    printf '%s\n' "$line" >> "$tmp"
    cat "$tmp" > "$dst"   # cat で書き戻し = dst の権限 (chmod 600) を保持
  done
  rm -f "$tmp"
}

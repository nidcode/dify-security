# 5. TLS証明書の更新

`*.<GATEWAY_DOMAIN>` ワイルドカード証明書の更新(期限切れ対応)手順。証明書ファイル自体の
発行(認証局への申請等)は別手段で行い、ここでは**発行済みのファイルを反映する**手順のみ扱う。

置き換え: `<GATEWAY_HOST>` `<GATEWAY_DOMAIN>` `<REPO_DIR>`。

## 手順

### ① 新しい証明書ファイルを Gateway VM に転送

```bash
scp fullchain.pem privkey.pem <GATEWAY_HOST>:/tmp/
```

### ② [Gateway VM] 配置

```bash
ssh <GATEWAY_HOST>
cp /tmp/fullchain.pem <REPO_DIR>/gateway/certs/tls.crt
cp /tmp/privkey.pem   <REPO_DIR>/gateway/certs/tls.key
```

### ③ [Gateway VM] front-nginx に反映 (無停止・瞬断なし)

```bash
cd <REPO_DIR>
docker compose -p aiop-gateway --env-file .env \
  -f compose.gateway.yaml -f gateway/oauth2-proxies.gateway.yaml \
  exec front-nginx nginx -s reload
```

> ファイルを差し替えるだけでは反映されない (nginxは起動時に読み込んだ内容を保持し続ける)。
> 必ず上記の `reload` を実行すること。

## 確認

```bash
echo | openssl s_client -connect <GATEWAY_HOST>:443 -servername <GATEWAY_DOMAIN> 2>/dev/null \
  | openssl x509 -noout -enddate
```

`notAfter=` に新しい有効期限が表示されればOK。ブラウザで `https://<GATEWAY_DOMAIN>/` を開き、
鍵アイコンから証明書の有効期限を確認しても良い。

## トラブルシュート

- `nginx: [emerg] cannot load certificate`: `tls.crt`/`tls.key` のペアが一致しているか、
  ファイルが壊れていないか確認。この場合 `reload` は失敗し、**古い証明書のまま動き続ける**
  (front-nginxは落ちない)。

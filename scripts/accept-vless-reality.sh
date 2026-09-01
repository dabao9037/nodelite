#!/usr/bin/env bash
set -euo pipefail

# Real acceptance gate: create through the public API, import the generated
# URI into an independent Xray container, and fetch HTTPS through local SOCKS.
# The node is deleted by the EXIT trap even when the handshake fails.
BASE_URL="${PANEL_BASE_URL:-https://s.165789.xyz/node-panel/}"
ADMIN_USER_VALUE="${PANEL_ADMIN_USER:-admin}"
ADMIN_PASS_VALUE="${PANEL_ADMIN_PASSWORD:-admin}"
XRAY_IMAGE="${XRAY_CLIENT_IMAGE:-ghcr.io/xtls/xray-core:26.6.27}"
HTTPS_URL="${VLESS_TEST_URL:-https://www.cloudflare.com/cdn-cgi/trace}"
ARTIFACT_DIR="${VLESS_ARTIFACT_DIR:-$(mktemp -d)}"
SOCKS_PORT="${VLESS_SOCKS_PORT:-10818}"
CONTAINER="nodelite-vless-accept-$$"
mkdir -p "$ARTIFACT_DIR"
chmod 700 "$ARTIFACT_DIR"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ -s "$ARTIFACT_DIR/node-id" && -s "$ARTIFACT_DIR/cookie.txt" ]]; then
    curl -ksS --max-time 30 -b "$ARTIFACT_DIR/cookie.txt" \
      -X DELETE "${BASE_URL%/}/api/nodes/$(cat "$ARTIFACT_DIR/node-id")" \
      -o "$ARTIFACT_DIR/delete-body.txt" -w '%{http_code}\n' \
      > "$ARTIFACT_DIR/delete-http-code.txt" 2>/dev/null || true
  fi
}
trap cleanup EXIT

login_code=$(curl -ksS --max-time 30 -c "$ARTIFACT_DIR/cookie.txt" \
  -o "$ARTIFACT_DIR/login-body.html" -w '%{http_code}' \
  -X POST "${BASE_URL%/}/login" \
  --data-urlencode "username=$ADMIN_USER_VALUE" \
  --data-urlencode "password=$ADMIN_PASS_VALUE")
[[ "$login_code" == 200 || "$login_code" == 303 ]]

create_code=$(curl -ksS --max-time 45 -b "$ARTIFACT_DIR/cookie.txt" \
  -o "$ARTIFACT_DIR/node.json" -w '%{http_code}' \
  -H 'Content-Type: application/json' -X POST "${BASE_URL%/}/api/nodes" \
  --data "{\"name\":\"real-vless-gate-$(date +%s)\",\"protocol\":\"vless\",\"server_name\":\"www.atlasobscura.com\",\"destination\":\"www.atlasobscura.com:443\"}")
[[ "$create_code" == 201 ]]

python3 - "$ARTIFACT_DIR" "$SOCKS_PORT" <<'PY'
import json, pathlib, sys
from urllib.parse import parse_qs, urlsplit
out = pathlib.Path(sys.argv[1]); socks_port = int(sys.argv[2])
node = json.loads((out / "node.json").read_text())
(out / "node-id").write_text(str(node["id"]))
u = urlsplit(node["link"]); q = parse_qs(u.query)
required = {"type", "security", "flow", "sni", "fp", "pbk", "sid", "spx"}
missing = sorted(required - q.keys())
if missing: raise SystemExit(f"generated VLESS URI is missing: {missing}")
if q["type"] != ["raw"] or q["security"] != ["reality"]:
    raise SystemExit("generated URI does not use canonical raw+reality")
cfg = {
  "log": {"access": "/dev/stdout", "error": "/dev/stderr", "loglevel": "debug"},
  "inbounds": [{"tag": "socks-in", "listen": "0.0.0.0", "port": socks_port,
    "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
  "outbounds": [{"tag": "reality-out", "protocol": "vless", "settings": {"vnext": [{
    "address": u.hostname, "port": u.port, "users": [{"id": u.username,
      "encryption": "none", "flow": q["flow"][0]}]}]}, "streamSettings": {
    "network": q["type"][0], "security": "reality", "realitySettings": {
      "fingerprint": q["fp"][0], "serverName": q["sni"][0],
      # Current Xray calls the server public key a REALITY password.
      "password": q["pbk"][0], "shortId": q["sid"][0], "spiderX": q["spx"][0]
    }}}]
}
(out / "client-config.json").write_text(json.dumps(cfg, indent=2))
PY
chmod 644 "$ARTIFACT_DIR/client-config.json"

docker pull "$XRAY_IMAGE" > "$ARTIFACT_DIR/pull.log"
docker run --rm --user 0:0 -v "$ARTIFACT_DIR/client-config.json:/etc/xray/config.json:ro" \
  "$XRAY_IMAGE" run -test -config /etc/xray/config.json > "$ARTIFACT_DIR/client-config-test.log" 2>&1
docker run -d --name "$CONTAINER" --user 0:0 --network host \
  -v "$ARTIFACT_DIR/client-config.json:/etc/xray/config.json:ro" \
  "$XRAY_IMAGE" run -config /etc/xray/config.json > "$ARTIFACT_DIR/client-container-id.txt"
sleep 2

curl -sS --max-time 45 --socks5-hostname "127.0.0.1:$SOCKS_PORT" \
  -D "$ARTIFACT_DIR/https-headers.txt" -o "$ARTIFACT_DIR/https-body.txt" \
  -w 'http_code=%{http_code}\nproxy_peer=%{remote_ip}\n' "$HTTPS_URL" \
  > "$ARTIFACT_DIR/curl-metrics.txt" 2> "$ARTIFACT_DIR/curl-error.txt"
docker logs --timestamps "$CONTAINER" > "$ARTIFACT_DIR/client.log" 2>&1
grep -Eq '^HTTP/[0-9.]+ 2[0-9][0-9]' "$ARTIFACT_DIR/https-headers.txt"
grep -Eq '^http_code=2[0-9][0-9]$' "$ARTIFACT_DIR/curl-metrics.txt"
grep -q 'accepted tcp:' "$ARTIFACT_DIR/client.log"

echo "VLESS_REALITY_ACCEPT_OK node_id=$(cat "$ARTIFACT_DIR/node-id") artifacts=$ARTIFACT_DIR"

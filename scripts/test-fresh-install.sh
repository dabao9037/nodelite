#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL_PORT="${NODELITE_TEST_PORT:-22060}"

cleanup() {
  cd "$ROOT_DIR"
  docker exec simple-node-netguard python3 /netguard.py rollback >/dev/null 2>&1 || true
  docker compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf data xray-config .env .env.credentials
}
trap cleanup EXIT

if [[ "${NODELITE_FRESH_INSTALL_TEST:-}" != "1" ]]; then
  echo "Refusing to erase local test state without NODELITE_FRESH_INSTALL_TEST=1" >&2
  exit 64
fi

cd "$ROOT_DIR"
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
rm -rf data xray-config .env .env.credentials
mkdir -p data xray-config
chmod 700 data
chmod 755 xray-config
cat >.env <<EOF
PUBLIC_HOST=127.0.0.1
PANEL_PORT=$PANEL_PORT
ACCESS_PATH=panel-fresh-test
EOF
cat >.env.credentials <<'EOF'
ADMIN_USER=admin
ADMIN_PASSWORD=fresh-install-test-password
APP_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
EOF
chmod 600 .env .env.credentials

docker compose up -d --build

for attempt in $(seq 1 60); do
  gateway_health="$(docker inspect simple-node-gateway --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  panel_health="$(docker inspect simple-node-panel --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  xray_health="$(docker inspect simple-node-xray --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  netguard_health="$(docker inspect simple-node-netguard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [[ "$gateway_health" == healthy && "$panel_health" == healthy && "$xray_health" == healthy && "$netguard_health" == healthy ]]; then
    break
  fi
  if [[ "$attempt" == 60 ]]; then
    docker compose ps -a
    docker compose logs --tail=150 gateway panel xray netguard
    exit 1
  fi
  sleep 2
done

test "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$PANEL_PORT/")" = 404
curl -fsS --max-time 5 "http://127.0.0.1:$PANEL_PORT/panel-fresh-test/healthz" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d == {"status":"ok","xray":"running","netguard":"running"}, d'
test "$(docker inspect simple-node-gateway --format '{{.RestartCount}}')" = 0
test "$(docker inspect simple-node-gateway --format '{{.RestartCount}}')" = 0
test "$(docker inspect simple-node-panel --format '{{.RestartCount}}')" = 0
test "$(docker inspect simple-node-netguard --format '{{.RestartCount}}')" = 0
test "$(docker inspect simple-node-xray --format '{{.RestartCount}}')" = 0
docker exec simple-node-netguard python3 /netguard.py reconcile >/dev/null
docker exec simple-node-xray xray run -test -config /etc/xray/config.json >/dev/null

echo "FRESH_INSTALL_OK gateway=$gateway_health panel=$panel_health xray=$xray_health netguard=$netguard_health"

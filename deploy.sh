#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

required=(Dockerfile docker-compose.yml entrypoint.sh requirements.txt app/main.py app/static/login.html app/static/login.js app/static/app.css app/static/index.html app/static/app.js netguard/Dockerfile netguard/netguard.py .env.credentials)
for file in "${required[@]}"; do
  test -s "$file" || { echo "Missing required deployment file: $file" >&2; exit 66; }
done

forbidden_marker=$(printf '\052\052\052')
if grep -RFn --exclude='*.pyc' --exclude-dir=__pycache__ "$forbidden_marker" app netguard Dockerfile docker-compose.yml entrypoint.sh; then
  echo "Forbidden source corruption marker found" >&2
  exit 65
fi

python3 -m py_compile app/main.py netguard/netguard.py
docker compose config -q
docker compose build --pull --no-cache panel netguard

host_hash=$(sha256sum app/main.py | awk '{print $1}')
image_hash=$(docker run --rm --entrypoint sha256sum simple-node-panel-panel:latest /app/app/main.py | awk '{print $1}')
test "$host_hash" = "$image_hash" || { echo "Host/image source hash mismatch" >&2; exit 67; }

docker compose up -d --force-recreate --remove-orphans

for attempt in $(seq 1 30); do
  panel_health=$(docker inspect simple-node-panel --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)
  xray_health=$(docker inspect simple-node-xray --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)
  netguard_health=$(docker inspect simple-node-netguard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)
  if [[ "$panel_health" == healthy && "$xray_health" == healthy && "$netguard_health" == healthy ]]; then
    break
  fi
  if [[ "$attempt" == 30 ]]; then
    docker compose ps -a >&2
    docker compose logs --tail=200 panel xray netguard >&2
    exit 68
  fi
  sleep 5
done

container_hash=$(docker exec simple-node-panel sha256sum /app/app/main.py | awk '{print $1}')
test "$host_hash" = "$container_hash" || { echo "Host/container source hash mismatch" >&2; exit 69; }

curl -fsS --max-time 5 http://127.0.0.1:2060/healthz | grep -q '"netguard":"running"'
docker exec simple-node-netguard python3 /netguard.py reconcile >/dev/null
echo "DEPLOY_OK hash=$host_hash panel=$panel_health xray=$xray_health netguard=$netguard_health"

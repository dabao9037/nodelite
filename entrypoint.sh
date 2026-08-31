#!/usr/bin/env sh
set -eu

forbidden_marker=$(printf '\052\052\052')
if grep -RFn --exclude='*.pyc' --exclude-dir=__pycache__ "$forbidden_marker" /app/app; then
  echo "Refusing to start: forbidden source corruption marker found" >&2
  exit 65
fi
python -m py_compile /app/app/main.py

mkdir -p /xray-config
if [ ! -s /xray-config/config.json ]; then
  cat >/xray-config/config.json <<'JSON'
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "listen": "127.0.0.1:10085", "services": ["StatsService"]},
  "metrics": {"tag": "Metrics", "listen": "127.0.0.1:11111"},
  "stats": {},
  "policy": {"system": {"statsInboundUplink": true, "statsInboundDownlink": true}},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ],
  "routing": {"rules": [{"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]}
}
JSON
fi

exec uvicorn app.main:app \
  --host 0.0.0.0 \
  --port 8080 \
  --proxy-headers \
  --forwarded-allow-ips '*'

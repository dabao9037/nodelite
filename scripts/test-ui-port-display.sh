#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CSS="$ROOT/app/static/app.css"

grep -Fq 'grid-template-columns: minmax(92px, auto)' "$CSS"
grep -Fq '.node-meta .port strong { overflow: visible; text-overflow: clip; white-space: nowrap;' "$CSS"

tmp="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
ln -s "$ROOT/app" "$tmp/app"
cat >"$tmp/port.html" <<'HTML'
<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="app/static/app.css">
<main class="shell"><article class="node-card"><div class="node-head"></div><div class="node-meta"><div class="port"><strong id="portValue">59876</strong><small>PORT</small></div><div><strong>0</strong></div><div><strong>永不过期</strong></div></div><div class="metrics"></div><div class="link"></div><div class="qr"></div><div class="actions"></div></article></main>
<pre id="result"></pre><script>addEventListener('load',()=>{const e=document.querySelector('#portValue');const r=document.createRange();r.selectNodeContents(e);document.querySelector('#result').textContent=JSON.stringify({elementWidth:e.getBoundingClientRect().width,textWidth:r.getBoundingClientRect().width})});</script>
HTML

if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
  browser="$(command -v chromium || command -v chromium-browser)"
  port="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >"$tmp/server.log" 2>&1 &
  server_pid=$!
  for _ in {1..20}; do curl -fsS "http://127.0.0.1:$port/port.html" >/dev/null 2>&1 && break; sleep .1; done
  dom="$($browser --headless --no-sandbox --disable-gpu --window-size=1120,800 --dump-dom "http://127.0.0.1:$port/port.html" 2>/dev/null)"
  payload="$(sed -n 's/.*<pre id="result">\([^<]*\)<\/pre>.*/\1/p' <<<"$dom")"
  python3 - "$payload" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
assert data["elementWidth"] + 0.5 >= data["textWidth"], data
PY
fi

echo "five-digit node port display OK"

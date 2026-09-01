#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT/install.sh" "$TMP/functions.sh" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
names = ("valid_port", "port_available", "random_high_port")
blocks = []
for name in names:
    start = source.index(f"{name}() {{")
    depth = 0
    end = None
    for offset, character in enumerate(source[start:], start):
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                end = offset + 1
                break
    if end is None:
        raise SystemExit(f"unterminated function: {name}")
    blocks.append(source[start:end])
Path(sys.argv[2]).write_text("\n\n".join(blocks) + "\n")
PY

for _ in {1..20}; do
  port="$(bash -c 'die(){ echo "$*" >&2; exit 1; }; source "$1"; random_high_port' bash "$TMP/functions.sh")"
  [[ "$port" =~ ^[0-9]+$ ]]
  (( port >= 40000 && port <= 60000 ))
  [[ "$port" != 2060 ]]
done

grep -Fq 'port="${PANEL_PORT:-$(read_key "$old" LISTEN_PORT)}"; port="${port:-$(random_high_port)}"' "$ROOT/install.sh"
grep -Fq 'port="${port:-$(random_high_port)}"' "$ROOT/install-docker.sh"
! grep -q '^DEFAULT_PORT=2060$' "$ROOT/install.sh"
! grep -q '^DEFAULT_PORT=2060$' "$ROOT/install-docker.sh"
echo "random high-port installer policy OK"

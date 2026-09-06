#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${NODELITE_NFT_PARSE_IMAGE:-debian:12-slim}"
docker run --rm --privileged -i -v "$ROOT/netguard/netguard.py:/netguard.py:ro" "$IMAGE" bash -s <<'CONTAINER'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends nftables python3 >/dev/null
python3 - <<'PY'
import importlib.util
spec=importlib.util.spec_from_file_location('guard','/netguard.py')
guard=importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)
open('/tmp/rules.nft','w').write(guard.render_ruleset([(1,37888,2)], {37888:{'1.1.1.1','2001:db8::1'}}, timeout_seconds=15))
PY
nft --version
nft -c -f /tmp/rules.nft
echo NFT_1_0_PARSE_OK
CONTAINER

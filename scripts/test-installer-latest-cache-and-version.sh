#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -Fq 'releases/latest?nodelite=$(date +%s)-$attempt-$RANDOM' "$ROOT/install.sh"
grep -Fq "Cache-Control: no-cache" "$ROOT/install.sh"
grep -Fq "Pragma: no-cache" "$ROOT/install.sh"
grep -Fq '[[ "$(cat "$INSTALL_DIR/VERSION")" == "$tag" ]]' "$ROOT/install.sh"
grep -Fq 'cmp -s "$INSTALL_DIR/install.sh" "$release_dir/install.sh"' "$ROOT/install.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${NODELITE_TEST_CURL_LOG:?}"
printf '{"tag_name":"v0.3.16-native"}'
EOF
chmod +x "$tmp/bin/curl"

# Source function definitions without executing the installer main dispatch.
sed '$d' "$ROOT/install.sh" >"$tmp/functions.sh"
tag="$(PATH="$tmp/bin:$PATH" NODELITE_TEST_CURL_LOG="$tmp/curl.log" sudo --preserve-env=PATH,NODELITE_TEST_CURL_LOG bash -c 'source "$1"; latest_tag' bash "$tmp/functions.sh")"
[[ "$tag" == v0.3.16-native ]]
grep -q 'releases/latest?nodelite=' "$tmp/curl.log"
grep -q 'Cache-Control: no-cache' "$tmp/curl.log"

echo INSTALLER_LATEST_CACHE_AND_VERSION_GATE_OK

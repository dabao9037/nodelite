#!/usr/bin/env bash
# Regression: when GitHub's release edge returns 504/22 for the direct asset,
# download_native_asset must resolve the asset id through the GitHub API and
# download it with Accept: application/octet-stream.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/work"
printf 'native release payload\n' >"$TMP/payload"
printf '0\n' >"$TMP/direct"
printf '0\n' >"$TMP/api"

cat >"$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -Eeuo pipefail
out=""; prev=""; url=""
for arg in "$@"; do
  if [[ "$prev" == -o ]]; then out="$arg"; prev=""; continue; fi
  case "$arg" in http://*|https://*) url="$arg" ;; esac
  prev="$arg"
done
case "$url" in
  */releases/tags/*)
    printf '1\n' >>"$NODELITE_TEST_API"
    cat "$NODELITE_TEST_JSON"
    ;;
  */releases/assets/*)
    printf '1\n' >>"$NODELITE_TEST_API"
    cp "$NODELITE_TEST_PAYLOAD" "$out"
    ;;
  *)
    printf '1\n' >>"$NODELITE_TEST_DIRECT"
    echo 'curl: (22) The requested URL returned error: 504' >&2
    exit 22
    ;;
esac
CURL
chmod +x "$TMP/bin/curl"

cat >"$TMP/release.json" <<'JSON'
{
  "tag_name": "v0.0.0-test",
  "assets": [
    {
      "url": "https://api.github.com/repos/dabao9037/nodelite/releases/assets/704104711",
      "id": 704104711,
      "name": "nodelite-linux-amd64.tar.gz",
      "browser_download_url": "https://github.com/dabao9037/nodelite/releases/download/v0.0.0-test/nodelite-linux-amd64.tar.gz"
    }
  ]
}
JSON

sed '$d' "$ROOT/install.sh" >"$TMP/functions.sh"
PATH="$TMP/bin:$PATH" \
NODELITE_TEST_DIRECT="$TMP/direct" \
NODELITE_TEST_API="$TMP/api" \
NODELITE_TEST_JSON="$TMP/release.json" \
NODELITE_TEST_PAYLOAD="$TMP/payload" \
sudo --preserve-env=PATH,NODELITE_TEST_DIRECT,NODELITE_TEST_API,NODELITE_TEST_JSON,NODELITE_TEST_PAYLOAD \
bash -c '
  set -Eeuo pipefail
  source "$1"
  sleep() { :; }
  REPO=dabao9037/nodelite
  download_native_asset v0.0.0-test amd64 "$2"
' bash "$TMP/functions.sh" "$TMP/work/release.tar.gz"

cmp "$TMP/payload" "$TMP/work/release.tar.gz"
[[ "$(grep -c '^1$' "$TMP/direct")" == 3 ]]
[[ "$(grep -c '^1$' "$TMP/api")" == 2 ]]
echo INSTALLER_API_FALLBACK_OK

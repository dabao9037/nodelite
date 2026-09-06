#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/work"
printf 'native release payload\n' >"$tmp/payload"
printf '0\n' >"$tmp/calls"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
calls="${NODELITE_TEST_CALLS:?}"
count=$(( $(cat "$calls") + 1 ))
printf '%s\n' "$count" >"$calls"

destination=""
while (($#)); do
  case "$1" in
    -o) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if ((count < 3)); then
  echo 'curl: (22) The requested URL returned error: 404' >&2
  exit 22
fi
cp "${NODELITE_TEST_PAYLOAD:?}" "$destination"
EOF
chmod +x "$tmp/bin/curl"

# Source only function definitions; remove main's final call.
sed '$d' "$ROOT/install.sh" >"$tmp/installer-functions.sh"

PATH="$tmp/bin:$PATH" \
NODELITE_TEST_CALLS="$tmp/calls" \
NODELITE_TEST_PAYLOAD="$tmp/payload" \
bash -c '
  set -Eeuo pipefail
  source "$1"
  sleep() { :; }
  REPO=dabao9037/nodelite
  download_native_asset v0.0.0-test amd64 "$2"
' bash "$tmp/installer-functions.sh" "$tmp/work/release.tar.gz"

cmp "$tmp/payload" "$tmp/work/release.tar.gz"
[[ "$(cat "$tmp/calls")" == 3 ]]

grep -q -- '--retry-all-errors' "$ROOT/install.sh"
grep -q 'Cache-Control: no-cache' "$ROOT/install.sh"
grep -Fq 'nodelite=$(date +%s)-$attempt-$RANDOM' "$ROOT/install.sh"

echo INSTALLER_RELEASE_404_RETRY_OK

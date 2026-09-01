#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/release/bin" "$TMP/fakebin"
printf 'amd64\n' >"$TMP/release/ARCH"
for binary in nodelite-panel nodelite-gateway nodelite-netguard xray; do
  printf '#!/bin/sh\nexit 0\n' >"$TMP/release/bin/$binary"
  chmod +x "$TMP/release/bin/$binary"
done
cat >"$TMP/fakebin/getconf" <<'EOF'
#!/bin/sh
printf 'glibc 2.31\n'
EOF
chmod +x "$TMP/fakebin/getconf"

sed -n '/^validate_release_compatibility() {/,/^}/p' "$ROOT/install.sh" >"$TMP/function.sh"

echo 2.38 >"$TMP/release/GLIBC_MAX"
set +e
output="$(PATH="$TMP/fakebin:$PATH" bash -c '
  set -Eeuo pipefail
  info() { :; }
  die() { echo "$*" >&2; exit 1; }
  source "$1"
  validate_release_compatibility "$2" amd64
' bash "$TMP/function.sh" "$TMP/release" 2>&1)"
status=$?
set -e
[[ $status -ne 0 ]]
[[ "$output" == *'系统 glibc 2.31 低于发行包要求 2.38'* ]]

echo 2.31 >"$TMP/release/GLIBC_MAX"
PATH="$TMP/fakebin:$PATH" bash -c '
  set -Eeuo pipefail
  info() { :; }
  die() { echo "$*" >&2; exit 1; }
  source "$1"
  validate_release_compatibility "$2" amd64
' bash "$TMP/function.sh" "$TMP/release"

validate_line="$(grep -n 'validate_release_compatibility "$release_dir" "$arch"' "$ROOT/install.sh" | cut -d: -f1)"
backup_line="$(grep -n 'backup_runtime_state "$backup_dir"' "$ROOT/install.sh" | cut -d: -f1)"
stop_line="$(grep -n 'stop_native_for_upgrade' "$ROOT/install.sh" | tail -1 | cut -d: -f1)"
[[ -n "$validate_line" && -n "$backup_line" && -n "$stop_line" ]]
(( validate_line < backup_line && validate_line < stop_line ))

echo "installer GLIBC preflight passes and runs before service stop"

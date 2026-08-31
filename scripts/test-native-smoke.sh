#!/usr/bin/env bash
set -Eeuo pipefail

PREFIX="${NODELITE_SMOKE_PREFIX:-$(mktemp -d /tmp/nodelite-native-smoke.XXXXXX)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/opt/nodelite" "$PREFIX/etc/systemd/system" "$PREFIX/usr/local/bin"
cp -a "$ROOT/packaging/systemd/." "$PREFIX/etc/systemd/system/"

# Verify unit and installer paths can be relocated for an unprivileged smoke
# test. No systemctl, iptables, package manager, TCPFit, or host path is touched.
for unit in "$PREFIX"/etc/systemd/system/*.service; do
  sed -i "s#/opt/nodelite#$PREFIX/opt/nodelite#g" "$unit"
done
grep -q '127.0.0.1' "$ROOT/native/panel_entry.py"
grep -q 'nodelite-xray.service' "$ROOT/app/main.py"
grep -q 'nodelite-netguard.service' "$ROOT/app/main.py"
grep -q 'ExecStopPost=.*rollback' "$PREFIX/etc/systemd/system/nodelite-netguard.service"
! grep -q 'docker' "$ROOT/requirements-native.txt"
echo "native smoke prefix verified: $PREFIX"

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="$ROOT/packaging/systemd/nodelite-panel.service"
GUARD="$ROOT/packaging/systemd/nodelite-netguard.service"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture"/bin "$fixture"/config "$fixture"/data "$fixture"/xray-config
for binary in nodelite-panel nodelite-netguard nodelite-gateway xray; do
  printf '#!/bin/sh\nexit 0\n' >"$fixture/bin/$binary"
  chmod 0755 "$fixture/bin/$binary"
done
printf '%s\n' 'RUNTIME_BACKEND=native' >"$fixture/config/nodelite.env"
printf '%s\n' '{}' >"$fixture/xray-config/config.json"
touch "$fixture/data/panel.db"

# systemd-analyze checks ExecStart and EnvironmentFile paths. Verify a copy
# against a disposable native-install fixture so this test is independent of
# whether /opt/nodelite is installed on the test host.
for unit in "$ROOT"/packaging/systemd/*.service; do
  sed "s#/opt/nodelite#$fixture#g" "$unit" >"$fixture/$(basename "$unit")"
done
systemd-analyze verify "$fixture"/*.service

PANEL="$fixture/nodelite-panel.service"
GUARD="$fixture/nodelite-netguard.service"

# Both processes use the exact same flock inode in a shared writable runtime
# directory. Netguard is the sole owner: if the panel also declared the same
# RuntimeDirectory, restarting the panel would detach netguard onto the old
# read-only mount and every later reconcile would fail with EROFS. Preserve
# the owner directory across netguard restarts for the same reason.
! grep -q '^RuntimeDirectory=' "$PANEL"
grep -qx 'RuntimeDirectory=nodelite' "$GUARD"
grep -qx 'RuntimeDirectoryMode=0770' "$GUARD"
grep -qx 'RuntimeDirectoryPreserve=yes' "$GUARD"
grep -qx 'ReadWritePaths=/run/nodelite' "$PANEL"
grep -qx 'ReadWritePaths=/run/nodelite' "$GUARD"
! grep -Eq '^ReadWritePaths=.*(/opt/nodelite($|[[:space:]])|/opt/nodelite/data)' "$GUARD"

# Netguard is denied the live DB and only sees an immutable, atomically
# published snapshot. This catches the v0.3.6 WAL/SHM read-only failure.
grep -qx 'StateDirectory=nodelite' "$PANEL"
grep -qx 'StateDirectory=nodelite' "$GUARD"
grep -qx 'ReadWritePaths=/var/lib/nodelite' "$PANEL"
grep -qx 'ReadOnlyPaths=/var/lib/nodelite' "$GUARD"
grep -qx "InaccessiblePaths=$fixture/data" "$GUARD"
grep -q 'NETGUARD_DB_PATH' "$ROOT/app/main.py"
grep -q 'publish_netguard_snapshot' "$ROOT/app/main.py"
for installer in "$ROOT/install.sh" "$ROOT/build/native-amd64/package/install.sh"; do
  grep -q '^NETGUARD_DB_PATH=/var/lib/nodelite/netguard.db$' "$installer"
  grep -q '^NETGUARD_DB_IMMUTABLE=1$' "$installer"
  grep -q 'set_key .* NETGUARD_DB_PATH /var/lib/nodelite/netguard.db' "$installer"
  grep -q 'set_key .* NETGUARD_DB_IMMUTABLE 1' "$installer"
  grep -q 'netguard.db' "$installer"
done

echo NATIVE_SYSTEMD_SANDBOX_OK

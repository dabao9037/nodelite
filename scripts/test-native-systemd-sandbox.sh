#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL="$ROOT/packaging/systemd/nodelite-panel.service"
GUARD="$ROOT/packaging/systemd/nodelite-netguard.service"

systemd-analyze verify "$ROOT"/packaging/systemd/*.service

# Both processes use the exact same flock inode in a shared writable runtime
# directory. The panel receives no broader write access outside its data,
# xray config, runtime lock, and snapshot state directories.
grep -qx 'RuntimeDirectory=nodelite' "$PANEL"
grep -qx 'RuntimeDirectory=nodelite' "$GUARD"
grep -qx 'RuntimeDirectoryMode=0770' "$PANEL"
grep -qx 'RuntimeDirectoryMode=0770' "$GUARD"
grep -qx 'ReadWritePaths=/run/nodelite' "$PANEL"
grep -qx 'ReadWritePaths=/run/nodelite' "$GUARD"
! grep -Eq '^ReadWritePaths=.*(/opt/nodelite($|[[:space:]])|/opt/nodelite/data)' "$GUARD"

# Netguard is denied the live DB and only sees an immutable, atomically
# published snapshot. This catches the v0.3.6 WAL/SHM read-only failure.
grep -qx 'StateDirectory=nodelite' "$PANEL"
grep -qx 'ReadWritePaths=/var/lib/nodelite' "$PANEL"
grep -qx 'ReadOnlyPaths=/var/lib/nodelite' "$GUARD"
grep -qx 'InaccessiblePaths=/opt/nodelite/data' "$GUARD"
grep -q '^NETGUARD_DB_PATH=/var/lib/nodelite/netguard.db$' <(
  awk '/^RUNTIME_BACKEND=native/{inside=1} inside{print} /^EOF$/{exit}' "$ROOT/install.sh"
)
grep -q '^NETGUARD_DB_IMMUTABLE=1$' "$ROOT/install.sh"
grep -q 'set_key .* NETGUARD_DB_PATH /var/lib/nodelite/netguard.db' "$ROOT/install.sh"
grep -q 'set_key .* NETGUARD_DB_IMMUTABLE 1' "$ROOT/install.sh"

echo NATIVE_SYSTEMD_SANDBOX_OK

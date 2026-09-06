#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANEL_SOURCE="$ROOT/packaging/systemd/nodelite-panel.service"
GUARD_SOURCE="$ROOT/packaging/systemd/nodelite-netguard.service"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "test-native-runtime-directory.sh must run as root" >&2
  exit 1
fi
command -v systemctl >/dev/null
[[ "$(systemctl is-system-running 2>/dev/null || true)" != offline ]]

suffix="$$-$RANDOM"
runtime="nodelite-runtime-test-$suffix"
guard_unit="$runtime-guard.service"
panel_unit="$runtime-panel.service"
helper="/run/$runtime-helper.sh"
guard_path="/run/systemd/system/$guard_unit"
panel_path="/run/systemd/system/$panel_unit"

cleanup() {
  systemctl stop "$panel_unit" "$guard_unit" >/dev/null 2>&1 || true
  rm -f "$guard_path" "$panel_path" "$helper"
  rm -rf "/run/$runtime"
  systemctl daemon-reload >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat >"$helper" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
while true; do
  date +%s%N >"/run/$runtime/heartbeat"
  sleep 0.1
done
EOF
chmod 0755 "$helper"

# Build disposable services from the ownership directives in the production
# units. This made the previous two-owner configuration fail deterministically:
# restarting panel removed/recreated the shared RuntimeDirectory while guard
# retained a read-only view of the old mount.
{
  cat <<EOF
[Unit]
Description=NodeLite runtime-directory regression guard
[Service]
Type=simple
ExecStart=/usr/bin/bash $helper
Restart=no
ProtectSystem=strict
ReadWritePaths=/run/$runtime
EOF
  if grep -q '^RuntimeDirectory=nodelite$' "$GUARD_SOURCE"; then
    echo "RuntimeDirectory=$runtime"
  fi
  if grep -q '^RuntimeDirectoryMode=' "$GUARD_SOURCE"; then
    grep '^RuntimeDirectoryMode=' "$GUARD_SOURCE"
  fi
  if grep -q '^RuntimeDirectoryPreserve=' "$GUARD_SOURCE"; then
    grep '^RuntimeDirectoryPreserve=' "$GUARD_SOURCE"
  fi
} >"$guard_path"

{
  cat <<EOF
[Unit]
Description=NodeLite runtime-directory regression panel
After=$guard_unit
[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=no
ProtectSystem=strict
ReadWritePaths=/run/$runtime
EOF
  if grep -q '^RuntimeDirectory=nodelite$' "$PANEL_SOURCE"; then
    echo "RuntimeDirectory=$runtime"
  fi
  if grep -q '^RuntimeDirectoryMode=' "$PANEL_SOURCE"; then
    grep '^RuntimeDirectoryMode=' "$PANEL_SOURCE"
  fi
  if grep -q '^RuntimeDirectoryPreserve=' "$PANEL_SOURCE"; then
    grep '^RuntimeDirectoryPreserve=' "$PANEL_SOURCE"
  fi
} >"$panel_path"

systemctl daemon-reload
systemctl start "$guard_unit" "$panel_unit"

for _ in {1..50}; do
  [[ -s "/run/$runtime/heartbeat" ]] && break
  sleep 0.1
done
[[ -s "/run/$runtime/heartbeat" ]]
before="$(cat "/run/$runtime/heartbeat")"

systemctl restart "$panel_unit"
sleep 0.5

after="$(cat "/run/$runtime/heartbeat")"
[[ "$after" != "$before" ]]
systemctl is-active --quiet "$guard_unit"
! journalctl -u "$guard_unit" --since '-10 seconds' --no-pager | grep -q 'Read-only file system'

echo NATIVE_RUNTIME_DIRECTORY_RESTART_OK

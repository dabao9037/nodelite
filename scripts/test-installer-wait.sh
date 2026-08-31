#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Load installer functions without running its command dispatcher.
source <(sed '/^command="${1:-}"/,$d' "$ROOT/install.sh")
INSTALL_DIR="$TMP/install"
mkdir -p "$INSTALL_DIR/config"
printf 'LISTEN_PORT=2060\n' >"$INSTALL_DIR/config/nodelite.env"
printf '0\n' >"$TMP/calls"

curl() {
  local calls
  calls="$(cat "$TMP/calls")"
  calls=$((calls + 1))
  printf '%s\n' "$calls" >"$TMP/calls"
  if (( calls < 3 )); then
    echo "curl: (7) Failed to connect to 127.0.0.1 port 2060" >&2
    return 7
  fi
  printf '%s\n' '{"status":"ok","xray":"running","netguard":"running"}'
}
sleep() { :; }
service_ctl() {
  case "${1:-}" in
    show)
      case "$3" in
        --property=ActiveState) printf 'activating\n' ;;
        --property=SubState) printf 'start\n' ;;
        --property=NRestarts) printf '0\n' ;;
        --property=Result) printf 'success\n' ;;
      esac
      ;;
    *) return 0 ;;
  esac
}
die() { echo "unexpected die: $*" >&2; return 1; }

stderr="$TMP/stderr"
wait_healthy 2>"$stderr"
test "$(cat "$TMP/calls")" = 3
test ! -s "$stderr"
printf 'INSTALLER_TRANSIENT_HEALTH_RETRY_OK\n'

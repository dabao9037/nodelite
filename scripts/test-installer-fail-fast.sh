#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source <(sed '/^command="${1:-}"/,$d' "$ROOT/install.sh")
INSTALL_DIR="$TMP/install"
mkdir -p "$INSTALL_DIR/config"
printf 'LISTEN_PORT=2060\n' >"$INSTALL_DIR/config/nodelite.env"
printf '0\n' >"$TMP/checks"

curl() { return 7; }
sleep() { :; }
journalctl() { printf 'simulated gateway bind failure\n' >&2; }
service_ctl() {
  local action="$1" unit="${2:-}" property="${3:-}"
  case "$action" in
    show)
      case "$property" in
        --property=ActiveState) printf 'activating\n' ;;
        --property=SubState) printf 'auto-restart\n' ;;
        --property=NRestarts)
          if [[ "$unit" == nodelite-gateway.service ]]; then printf '2\n'; else printf '0\n'; fi
          ;;
        --property=Result)
          if [[ "$unit" == nodelite-gateway.service ]]; then printf 'exit-code\n'; else printf 'success\n'; fi
          ;;
      esac
      ;;
    *) return 0 ;;
  esac
}
die() { echo "$*" >&2; exit 1; }

if ( wait_healthy ) >"$TMP/stdout" 2>"$TMP/stderr"; then
  echo "wait_healthy unexpectedly succeeded" >&2
  exit 1
fi
test "$(cat "$TMP/checks")" -lt 20
grep -q 'nodelite-gateway.service 启动后发生崩溃/重启' "$TMP/stderr"
printf 'INSTALLER_FAILED_SERVICE_FAST_DIAGNOSIS_OK\n'

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/install"
export NODELITE_DIR="$TMP/install"

# A process-substitution source is a pipe-like /dev/fd path. Saving it after
# Bash has already read part of the script used to produce a truncated file.
source <(sed '/^command="${1:-}"/,$d' "$ROOT/install.sh")
INSTALL_DIR="$TMP/install"
BIN_DIR="$TMP/bin"
PATH="$BIN_DIR:/usr/sbin:/usr/bin:/sbin:/bin"

curl() {
  local output=""
  while (($#)); do
    if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
  done
  install -m 0755 "$ROOT/install.sh" "$output"
}

BASH_SOURCE[0]="/dev/fd/63"
save_installer "$INSTALL_DIR/install.sh"
bash -n "$INSTALL_DIR/install.sh"
grep -q '^menu()' "$INSTALL_DIR/install.sh"

install_shortcuts
first_hash="$(sha256sum "$BIN_DIR/nodelite" | awk '{print $1}')"
first_mtime="$(stat -c %Y "$BIN_DIR/nodelite")"
sleep 1
install_shortcuts
test "$first_hash" = "$(sha256sum "$BIN_DIR/nodelite" | awk '{print $1}')"
test "$first_mtime" = "$(stat -c %Y "$BIN_DIR/nodelite")"
printf 'PROCESS_SUBSTITUTION_AND_IDEMPOTENT_SHORTCUT_OK\n'

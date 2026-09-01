#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sed -n '/^ensure_git() {/,/^}/p' "$ROOT/install.sh" >"$TMP/function.sh"

grep -Fq 'command -v git >/dev/null 2>&1 && return 0' "$TMP/function.sh"
grep -Fq 'apt-get update && apt-get install -y ca-certificates git' "$TMP/function.sh"
grep -Fq 'dnf install -y ca-certificates git' "$TMP/function.sh"
grep -Fq 'yum install -y ca-certificates git' "$TMP/function.sh"
grep -Fq 'apk add --no-cache ca-certificates git' "$TMP/function.sh"
grep -Fq 'zypper --non-interactive install ca-certificates git' "$TMP/function.sh"
grep -Fq 'pacman -Sy --noconfirm ca-certificates git' "$TMP/function.sh"
grep -Fq 'command -v git >/dev/null 2>&1 || die' "$TMP/function.sh"

test_bin="$TMP/existing"
mkdir -p "$test_bin"
cat >"$test_bin/git" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$test_bin/git"
PATH="$test_bin:/usr/bin:/bin" bash -c '
  set -Eeuo pipefail
  warn() { :; }
  die() { exit 1; }
  source "$1"
  ensure_git
' bash "$TMP/function.sh"

grep -Fq 'ensure_tools; ensure_git' "$ROOT/install.sh"
ensure_line="$(grep -n 'ensure_tools; ensure_git' "$ROOT/install.sh" | cut -d: -f1)"
git_line="$(grep -n 'commit="$(git ls-remote' "$ROOT/install.sh" | cut -d: -f1)"
[[ -n "$ensure_line" && -n "$git_line" ]]
(( ensure_line < git_line ))

echo "TCPFit git dependency handling OK"

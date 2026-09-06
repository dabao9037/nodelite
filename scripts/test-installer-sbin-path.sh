#!/usr/bin/env bash
# Regression: a root shell without sbin on PATH must still find nft/ip/sysctl.
# Previously ensure_tools aborted with "依赖安装后仍找不到命令：nft" even when
# nftables was installed, because /usr/sbin was missing from PATH.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stand in for sbin-only administrative tools.
FAKE_SBIN="$TMP/usr/sbin"
mkdir -p "$FAKE_SBIN" "$TMP/bin"
for tool in nft ip sysctl; do
  printf '#!/bin/sh\nexit 0\n' >"$FAKE_SBIN/$tool"
  chmod 0755 "$FAKE_SBIN/$tool"
done

prelude="$(sed -n '1,/^export PATH$/p' "$ROOT/install.sh")"
printf '%s\n' "$prelude" >"$TMP/prelude.sh"
grep -q 'export PATH' "$TMP/prelude.sh" || { echo "installer prelude no longer exports PATH" >&2; exit 1; }

# The installer must append the real sbin directories, so point the fake tools
# at a location it will search: verify via a PATH that omits sbin entirely.
result="$(env -i "HOME=$TMP" "PATH=/usr/bin:/bin" bash -c "
  set -Eeuo pipefail
  . '$TMP/prelude.sh'
  for dir in /usr/local/sbin /usr/sbin /sbin; do
    case \":\$PATH:\" in *\":\$dir:\"*) printf 'has %s\n' \"\$dir\";; esac
  done
")"

for dir in /usr/local/sbin /usr/sbin /sbin; do
  [[ -d "$dir" ]] || continue
  printf '%s' "$result" | grep -q "has $dir" || {
    echo "installer PATH prelude did not add $dir" >&2
    exit 1
  }
done

# An already-present sbin entry must not be duplicated.
duplicates="$(env -i "HOME=$TMP" "PATH=/usr/bin:/bin:/usr/sbin" bash -c "
  set -Eeuo pipefail
  . '$TMP/prelude.sh'
  printf '%s' \"\$PATH\" | tr ':' '\n' | grep -c '^/usr/sbin$'
")"
[[ "$duplicates" == "1" ]] || { echo "installer PATH prelude duplicated /usr/sbin ($duplicates)" >&2; exit 1; }

echo "INSTALLER_SBIN_PATH_OK"

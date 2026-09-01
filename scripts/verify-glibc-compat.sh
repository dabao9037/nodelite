#!/usr/bin/env bash
set -Eeuo pipefail

TARGET="${1:-}"
MAX_ALLOWED="${2:-${NODELITE_GLIBC_MAX:-2.31}}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <release-directory|release.tar.gz> [max-glibc]" >&2; exit 64; }
command -v readelf >/dev/null 2>&1 || { echo "readelf is required" >&2; exit 1; }
command -v sort >/dev/null 2>&1 || { echo "sort is required" >&2; exit 1; }

TMP=""
cleanup() { [[ -z "$TMP" ]] || rm -rf "$TMP"; }
trap cleanup EXIT

if [[ -f "$TARGET" ]]; then
  TMP="$(mktemp -d)"
  tar -xzf "$TARGET" -C "$TMP"
  TARGET="$TMP"
fi
[[ -d "$TARGET" ]] || { echo "target is not a directory or tar.gz: $TARGET" >&2; exit 64; }

failed=0
elf_count=0
while IFS= read -r -d '' candidate; do
  readelf -h "$candidate" >/dev/null 2>&1 || continue
  ((elf_count += 1))
  while IFS= read -r required; do
    [[ -n "$required" ]] || continue
    highest="$(printf '%s\n%s\n' "$MAX_ALLOWED" "$required" | sort -V | tail -n1)"
    if [[ "$highest" != "$MAX_ALLOWED" ]]; then
      printf 'incompatible GLIBC_%s (maximum GLIBC_%s): %s\n' \
        "$required" "$MAX_ALLOWED" "${candidate#$TARGET/}" >&2
      failed=1
    fi
  done < <(readelf --version-info "$candidate" 2>/dev/null | sed -n 's/.*Name: GLIBC_\([0-9][0-9.]*\).*/\1/p' | sort -Vu)
done < <(find "$TARGET" -type f -print0)

(( elf_count > 0 )) || { echo "no ELF files found under $TARGET" >&2; exit 1; }
(( failed == 0 )) || exit 1
printf 'GLIBC compatibility OK: %s ELF files require at most GLIBC_%s\n' "$elf_count" "$MAX_ALLOWED"
